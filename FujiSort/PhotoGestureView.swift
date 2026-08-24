//
//  PhotoGestureView.swift
//  FujiSort — Milestone 05 (the gesture surface)
//
//  A TRANSPARENT UIKit multitouch layer. SwiftUI can't separate a two-finger pan
//  from a one-finger swipe-to-decide, can't keep a pinch focal point under the
//  fingers, and can't tell an at-fit swipe from a zoomed pan — so this milestone
//  owns the gesture surface in UIKit. The view renders nothing: it discriminates
//  touches, runs the pure `ZoomGeometry`/`AnalysisGesture` math, and reports the
//  result. SwiftUI applies the transform, so synthetic (imageless) cards and the
//  real image path stay one rendering path.
//
//  Two modes:
//    • .springy (sort) — 2-finger pinch + 2-finger PAN that snaps back on release
//      (the pan is the piece deferred from milestone 04), a 1-finger drag streamed
//      out for swipe-to-decide, and a tap that enters analysis. Finger counts keep
//      the 1-finger swipe from ever being contested by the 2-finger zoom.
//    • .sticky (analysis / compare) — zoom that sticks, 1-finger pan when zoomed,
//      the 1:1 detent with its `.selection` haptic, retreat-while-touched, and the
//      at-fit-vs-zoomed routing that sends a swipe to the filmstrip.
//

import SwiftUI
import UIKit

enum PhotoGestureMode { case springy, sticky }

struct PhotoGestureView: UIViewRepresentable {
    let mode: PhotoGestureMode
    let isCompare: Bool
    /// The ORIGINAL asset's pixel dimensions, for the 1:1 detent. Zero disables the
    /// detent (synthetic cards) — zoom still works, there's just no 1:1 notch.
    let imagePixelSize: CGSize

    /// Sticky source of truth, carried across compare switches by `AnalysisModel`.
    /// Springy passes `.constant(.fit)` and drives its transient zoom via callbacks.
    @Binding var zoom: ZoomState

    // Sticky
    var onReachedOneToOne: (() -> Void)? = nil
    var onStripNext: (() -> Void)? = nil
    var onStripPrevious: (() -> Void)? = nil

    // Springy (sort)
    var onSpringyZoom: ((_ scale: CGFloat, _ anchor: UnitPoint, _ translation: CGSize) -> Void)? = nil
    var onSpringyEnded: (() -> Void)? = nil
    var onDragChanged: ((_ translation: CGSize, _ velocity: CGSize) -> Void)? = nil
    var onDragEnded: ((_ translation: CGSize, _ velocity: CGSize) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    // Both
    var onInteractingChanged: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> GestureContainer {
        let v = GestureContainer()
        v.backgroundColor = .clear
        v.configure(mode: mode, isCompare: isCompare, coordinator: context.coordinator)
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ v: GestureContainer, context: Context) {
        context.coordinator.parent = self
        v.isCompare = isCompare
        v.imagePixelSize = imagePixelSize
        // Sticky: adopt the model's zoom when it changed externally (a compare switch,
        // a reset) and we aren't mid-gesture — this is how zoom carries across frames.
        if mode == .sticky, !v.isGesturing, v.zoom != zoom {
            v.setZoom(zoom)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator {
        var parent: PhotoGestureView
        weak var view: GestureContainer?
        init(_ parent: PhotoGestureView) { self.parent = parent }

        // Sticky writes back into the binding as the user zooms/pans.
        func stickyZoomChanged(_ z: ZoomState) { parent.zoom = z }
        func reachedOneToOne() { parent.onReachedOneToOne?() }
        func stripNext() { parent.onStripNext?() }
        func stripPrevious() { parent.onStripPrevious?() }

        func springyZoom(scale: CGFloat, anchor: UnitPoint, translation: CGSize) {
            parent.onSpringyZoom?(scale, anchor, translation)
        }
        func springyEnded() { parent.onSpringyEnded?() }
        func dragChanged(_ t: CGSize, _ v: CGSize) { parent.onDragChanged?(t, v) }
        func dragEnded(_ t: CGSize, _ v: CGSize) { parent.onDragEnded?(t, v) }
        func tap() { parent.onTap?() }
        func interacting(_ on: Bool) { parent.onInteractingChanged?(on) }
    }
}

// MARK: - The container

/// Owns the recognizers and all touch bookkeeping. Reports through the coordinator;
/// renders nothing.
final class GestureContainer: UIView, UIGestureRecognizerDelegate {

    private var mode: PhotoGestureMode = .sticky
    var isCompare = false
    var imagePixelSize: CGSize = .zero
    private weak var coordinator: PhotoGestureView.Coordinator?

    /// Sticky zoom state (mirror of the SwiftUI binding). `rawScale` tracks the
    /// unsnapped pinch so the 1:1 detent can be escaped by pinching past its zone
    /// rather than sticking there.
    private(set) var zoom = ZoomState.fit
    private var rawScale: CGFloat = 1
    private var detentEngaged = false

    /// Springy transient scale (multiple of fit); reset to 1 on release.
    private var springyScale: CGFloat = 1

    private(set) var isGesturing = false
    private var lastPan: CGPoint = .zero
    private var navigatedThisPan = false

    private var displayScale: CGFloat { max(1, traitCollection.displayScale) }

    func configure(mode: PhotoGestureMode, isCompare: Bool, coordinator: PhotoGestureView.Coordinator) {
        self.mode = mode
        self.isCompare = isCompare
        self.coordinator = coordinator
        installRecognizers()
    }

    func setZoom(_ z: ZoomState) {
        zoom = z
        rawScale = z.scale
    }

    // MARK: Recognizer install

    private func installRecognizers() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        switch mode {
        case .sticky:
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleStickyPan))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)

        case .springy:
            let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleSpringyPan))
            twoFinger.minimumNumberOfTouches = 2
            twoFinger.maximumNumberOfTouches = 2
            twoFinger.delegate = self
            addGestureRecognizer(twoFinger)

            let decide = UIPanGestureRecognizer(target: self, action: #selector(handleDecidePan))
            decide.minimumNumberOfTouches = 1
            decide.maximumNumberOfTouches = 1
            decide.delegate = self
            addGestureRecognizer(decide)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            addGestureRecognizer(tap)
        }
    }

    // Pinch and the two-finger pan must run together in sort mode so a pinch pans as
    // its centroid moves. Everything else is separated by finger count.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    // MARK: Geometry helpers (bound to this view's current size)

    private var container: CGSize { bounds.size }
    private var fitted: CGSize { ZoomGeometry.fittedSize(imagePixel: pixelOrContainer, container: container) }
    private var pixelOrContainer: CGSize { imagePixelSize == .zero ? container : imagePixelSize }
    private var oneToOne: CGFloat {
        imagePixelSize == .zero ? .greatestFiniteMagnitude
            : ZoomGeometry.oneToOneScale(imagePixel: imagePixelSize, container: container, displayScale: displayScale)
    }

    // MARK: Sticky pinch

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch mode {
        case .sticky:  handleStickyPinch(g)
        case .springy: handleSpringyPinch(g)
        }
    }

    private func handleStickyPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            setInteracting(true)
        case .changed:
            let p = g.location(in: self)
            let nBefore = ZoomGeometry.normalizedPoint(atContainerPoint: p, center: zoom.center,
                                                       scale: zoom.scale, fitted: fitted, container: container)
            rawScale = ZoomGeometry.clampScale(rawScale * g.scale, oneToOne: oneToOne)
            g.scale = 1

            let snap = Detent.snap(scale: rawScale, oneToOne: oneToOne)
            if snap.snapped {
                if !detentEngaged { coordinator?.reachedOneToOne(); detentEngaged = true }
            } else {
                detentEngaged = false
            }
            let newScale = snap.scale

            var newCenter = ZoomGeometry.center(keepingNormalized: nBefore, atContainerPoint: p,
                                                scale: newScale, fitted: fitted, container: container)
            newCenter = ZoomGeometry.clampedCenter(newCenter, scale: newScale, fitted: fitted, container: container)
            zoom = ZoomState(scale: newScale, center: newCenter)
            coordinator?.stickyZoomChanged(zoom)
        case .ended, .cancelled, .failed:
            setInteracting(false)
        default:
            break
        }
    }

    // MARK: Sticky one-finger pan / strip swipe

    @objc private func handleStickyPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            setInteracting(true)
            lastPan = .zero
            navigatedThisPan = false
        case .changed:
            guard !navigatedThisPan else { break }
            let t = g.translation(in: self)
            let route = AnalysisGesture.route(atFit: zoom.isAtFit, isCompare: isCompare,
                                              translation: CGSize(width: t.x, height: t.y))
            switch route {
            case .pan:
                let delta = CGSize(width: t.x - lastPan.x, height: t.y - lastPan.y)
                applyPanDelta(delta)
                lastPan = t
            case .stripNext:
                coordinator?.stripNext(); navigatedThisPan = true
            case .stripPrevious:
                coordinator?.stripPrevious(); navigatedThisPan = true
            case .ignore:
                break
            }
        case .ended, .cancelled, .failed:
            setInteracting(false)
        default:
            break
        }
    }

    private func applyPanDelta(_ delta: CGSize) {
        guard fitted.width > 0, fitted.height > 0 else { return }
        var c = zoom.center
        c.x -= delta.width / (fitted.width * zoom.scale)
        c.y -= delta.height / (fitted.height * zoom.scale)
        c = ZoomGeometry.clampedCenter(c, scale: zoom.scale, fitted: fitted, container: container)
        zoom = ZoomState(scale: zoom.scale, center: c)
        coordinator?.stickyZoomChanged(zoom)
    }

    // MARK: Springy pinch + two-finger pan (sort mode; snaps back)

    private func handleSpringyPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            setInteracting(true)
        case .changed:
            springyScale = max(1, springyScale * g.scale)
            g.scale = 1
            reportSpringy(g.location(in: self))
        case .ended, .cancelled, .failed:
            endSpringy()
        default:
            break
        }
    }

    @objc private func handleSpringyPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            setInteracting(true)
        case .changed:
            reportSpringy(g.location(in: self))
        case .ended, .cancelled, .failed:
            endSpringy()
        default:
            break
        }
    }

    /// Report the springy transform for SwiftUI to apply: scale about the pinch
    /// centroid (as a unit anchor) plus the two-finger pan translation. Both are
    /// transient — SwiftUI springs them back when `endSpringy` fires.
    private var springyTranslation: CGSize = .zero
    private func reportSpringy(_ centroid: CGPoint) {
        // Accumulate the two-finger pan from whichever recognizer moved.
        if let pan = gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer })
            .first(where: { $0.minimumNumberOfTouches == 2 && $0.state == .changed }) {
            let t = pan.translation(in: self)
            springyTranslation = CGSize(width: t.x, height: t.y)
        }
        let anchor = UnitPoint(x: container.width > 0 ? centroid.x / container.width : 0.5,
                               y: container.height > 0 ? centroid.y / container.height : 0.5)
        coordinator?.springyZoom(scale: springyScale, anchor: anchor, translation: springyTranslation)
    }

    private func endSpringy() {
        // Only spring back once both fingers are off — a pinch and a pan can end
        // independently. If either is still active, keep the transform live.
        let stillActive = (gestureRecognizers ?? []).contains {
            ($0 is UIPinchGestureRecognizer || ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2)
                && ($0.state == .began || $0.state == .changed)
        }
        guard !stillActive else { return }
        springyScale = 1
        springyTranslation = .zero
        coordinator?.springyEnded()
        setInteracting(false)
    }

    // MARK: Decide pan / tap (sort mode)

    @objc private func handleDecidePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        let v = g.velocity(in: self)
        let ts = CGSize(width: t.x, height: t.y)
        let vs = CGSize(width: v.x, height: v.y)
        switch g.state {
        case .changed:
            coordinator?.dragChanged(ts, vs)
        case .ended, .cancelled, .failed:
            coordinator?.dragEnded(ts, vs)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        coordinator?.tap()
    }

    // MARK: Interacting

    private func setInteracting(_ on: Bool) {
        guard on != isGesturing else { return }
        isGesturing = on
        coordinator?.interacting(on)
    }
}
