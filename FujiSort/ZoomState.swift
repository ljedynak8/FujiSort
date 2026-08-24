//
//  ZoomState.swift
//  FujiSort — Milestone 05 (analysis / sticky zoom)
//
//  The PURE zoom model for analysis, kept free of SwiftUI, UIKit, and PhotoKit so
//  every transform, clamp, and the 1:1 detent unit-test directly (the Simulator
//  can't seed a real PhotoKit deck — see the milestone verification notes).
//
//  Canonical state is (scale, center):
//    • scale  — a MULTIPLE OF FIT. 1.0 == aspect-fit; larger zooms in.
//    • center — the normalised image point (unit coords, 0…1) sitting at the
//               container centre. This is resolution-independent, which is exactly
//               what lets zoom carry across a photo switch: the same scale and the
//               same relative spot re-apply to a differently-sized frame.
//
//  1:1 is defined against the ORIGINAL asset's pixel dimensions, never against the
//  bitmap currently in hand — the pipeline may still be serving a downscaled frame,
//  and the detent must not move when the sharp original lands.
//

import CoreGraphics

/// Where the viewport is sitting over the fitted image. Carried across compare
/// switches verbatim (see `AnalysisModel`).
struct ZoomState: Equatable {
    /// Multiple of fit. 1.0 == fit.
    var scale: CGFloat = 1
    /// Normalised image point (0…1 each axis) at the container centre.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    static let fit = ZoomState()

    var isAtFit: Bool { scale <= 1.0001 }
}

/// The geometry, all pure. Everything the UIKit gesture surface needs to place,
/// scale, and clamp the image is here so it can be checked without a screen.
enum ZoomGeometry {

    /// The image's size in POINTS when aspect-fitted into `container`.
    static func fittedSize(imagePixel: CGSize, container: CGSize) -> CGSize {
        guard imagePixel.width > 0, imagePixel.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / imagePixel.width, container.height / imagePixel.height)
        return CGSize(width: imagePixel.width * scale, height: imagePixel.height * scale)
    }

    /// The `scale` (multiple of fit) at which the ORIGINAL renders 1:1 with device
    /// pixels. Depends only on the asset's pixel size, the container, and the display
    /// scale — deliberately independent of whatever resolution is currently loaded.
    static func oneToOneScale(imagePixel: CGSize, container: CGSize, displayScale: CGFloat) -> CGFloat {
        let fitted = fittedSize(imagePixel: imagePixel, container: container)
        guard fitted.width > 0, displayScale > 0 else { return 1 }
        // Points shown for the full image at scale s = fitted.width * s; device pixels
        // = that × displayScale. 1:1 ⇒ device pixels == asset pixels.
        let s = imagePixel.width / (fitted.width * displayScale)
        return max(1, s)
    }

    /// Upper bound on scale: a little past 1:1 so pixel-peeping is possible, but
    /// bounded so a pinch can't run away. Never below a usable 4× fit.
    static func maxScale(oneToOne: CGFloat) -> CGFloat { max(4, oneToOne * 1.25) }

    /// Clamp scale into `[1, maxScale]`.
    static func clampScale(_ scale: CGFloat, oneToOne: CGFloat) -> CGFloat {
        min(max(1, scale), maxScale(oneToOne: oneToOne))
    }

    /// Clamp a normalised centre so the scaled image never reveals a gap at an edge.
    /// When the scaled image is no larger than the container on an axis, that axis is
    /// pinned to 0.5 (centred).
    static func clampedCenter(_ center: CGPoint, scale: CGFloat, fitted: CGSize, container: CGSize) -> CGPoint {
        CGPoint(x: clampAxis(center.x, scaledContent: fitted.width * scale, container: container.width),
                y: clampAxis(center.y, scaledContent: fitted.height * scale, container: container.height))
    }

    private static func clampAxis(_ c: CGFloat, scaledContent: CGFloat, container: CGFloat) -> CGFloat {
        guard scaledContent > container, scaledContent > 0 else { return 0.5 }
        let halfWindow = (container / scaledContent) / 2   // normalised half-viewport
        return min(max(c, halfWindow), 1 - halfWindow)
    }

    /// The content translation (points, parent space) that puts `center` at the
    /// container centre. (0,0) when centred.
    static func offset(center: CGPoint, scale: CGFloat, fitted: CGSize, container: CGSize) -> CGSize {
        CGSize(width: (0.5 - center.x) * fitted.width * scale,
               height: (0.5 - center.y) * fitted.height * scale)
    }

    /// The normalised image point currently under a container point — the inverse of
    /// `offset`. Used to keep the pinch focus (or a pan) pinned under the fingers.
    static func normalizedPoint(atContainerPoint p: CGPoint, center: CGPoint,
                                scale: CGFloat, fitted: CGSize, container: CGSize) -> CGPoint {
        CGPoint(x: axisNormalized(p.x, center: center.x, scaledContent: fitted.width * scale, container: container.width),
                y: axisNormalized(p.y, center: center.y, scaledContent: fitted.height * scale, container: container.height))
    }

    /// The centre that keeps normalised point `n` under container point `p` — the
    /// value a focal-point pinch or a pan solves for.
    static func center(keepingNormalized n: CGPoint, atContainerPoint p: CGPoint,
                       scale: CGFloat, fitted: CGSize, container: CGSize) -> CGPoint {
        CGPoint(x: axisCenter(keeping: n.x, at: p.x, scaledContent: fitted.width * scale, container: container.width),
                y: axisCenter(keeping: n.y, at: p.y, scaledContent: fitted.height * scale, container: container.height))
    }

    private static func axisNormalized(_ p: CGFloat, center: CGFloat, scaledContent: CGFloat, container: CGFloat) -> CGFloat {
        guard scaledContent > 0 else { return center }
        return center + (p - container / 2) / scaledContent
    }

    private static func axisCenter(keeping n: CGFloat, at p: CGFloat, scaledContent: CGFloat, container: CGFloat) -> CGFloat {
        guard scaledContent > 0 else { return n }
        return n - (p - container / 2) / scaledContent
    }
}

/// The 1:1 detent — a convenience *within* free zoom, not a replacement for it.
enum Detent {
    /// Fraction of the 1:1 scale within which a pinch snaps to exactly 1:1.
    static let tolerance: CGFloat = 0.12

    /// True when `scale` is inside the detent zone around 1:1.
    static func isEngaged(scale: CGFloat, oneToOne: CGFloat) -> Bool {
        guard oneToOne > 0 else { return false }
        return abs(scale / oneToOne - 1) <= tolerance
    }

    /// Snap `scale` to exactly 1:1 when inside the zone; otherwise leave it. The
    /// `snapped` flag drives the one-shot `.selection` haptic in the gesture surface.
    static func snap(scale: CGFloat, oneToOne: CGFloat) -> (scale: CGFloat, snapped: Bool) {
        isEngaged(scale: scale, oneToOne: oneToOne) ? (oneToOne, true) : (scale, false)
    }
}
