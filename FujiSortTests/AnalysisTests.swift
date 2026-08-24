//
//  AnalysisTests.swift
//  FujiSortTests — Milestone 05 (analysis / comparison)
//
//  The pure surface of milestone 05: the zoom transforms and 1:1 detent, the
//  at-fit-vs-zoomed gesture routing, filmstrip index movement, and HUD parsing.
//  All of it is deterministic and library-free — the Simulator can't seed a real
//  PhotoKit deck, so the correctness that matters lives here (verification notes).
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import FujiSort

// MARK: - Zoom geometry & the 1:1 detent

struct ZoomGeometryTests {

    // A 4000×3000 image in a 400×800 portrait container fits to the WIDTH.
    private let pixel = CGSize(width: 4000, height: 3000)
    private let container = CGSize(width: 400, height: 800)

    @Test func fittedSizePreservesAspectAndFitsInside() {
        let fitted = ZoomGeometry.fittedSize(imagePixel: pixel, container: container)
        #expect(fitted.width == 400)                 // width-bound
        #expect(abs(fitted.height - 300) < 0.001)    // 4:3 preserved
        #expect(fitted.width <= container.width + 0.001)
        #expect(fitted.height <= container.height + 0.001)
    }

    @Test func oneToOneScaleIsPixelsOverFittedDevicePixels() {
        // fitted width 400 pt; at displayScale 2 that's 800 device px for the whole
        // image, which holds 4000 px ⇒ 1:1 needs 5× fit.
        let one = ZoomGeometry.oneToOneScale(imagePixel: pixel, container: container, displayScale: 2)
        #expect(abs(one - 5) < 0.001)
    }

    @Test func oneToOneNeverBelowFit() {
        // A tiny image is already larger than 1:1 at fit; the scale floors at 1.
        let one = ZoomGeometry.oneToOneScale(imagePixel: CGSize(width: 100, height: 100),
                                             container: container, displayScale: 3)
        #expect(one == 1)
    }

    @Test func clampScaleBoundsToFitAndMax() {
        let one: CGFloat = 5
        #expect(ZoomGeometry.clampScale(0.2, oneToOne: one) == 1)        // never below fit
        let max = ZoomGeometry.maxScale(oneToOne: one)
        #expect(ZoomGeometry.clampScale(999, oneToOne: one) == max)
    }

    @Test func centerPinsToMiddleWhenImageNotLargerThanContainer() {
        // At fit the image never overflows, so any center clamps back to (0.5, 0.5).
        let fitted = ZoomGeometry.fittedSize(imagePixel: pixel, container: container)
        let c = ZoomGeometry.clampedCenter(CGPoint(x: 0.1, y: 0.9), scale: 1, fitted: fitted, container: container)
        #expect(c == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func centerClampsToKeepEdgesCoveredWhenZoomed() {
        let fitted = ZoomGeometry.fittedSize(imagePixel: pixel, container: container)
        // Zoom 4× on the width axis: scaledContent 1600 pt, container 400 ⇒ half-window
        // = (400/1600)/2 = 0.125, so x ∈ [0.125, 0.875].
        let c = ZoomGeometry.clampedCenter(CGPoint(x: 0, y: 0.5), scale: 4, fitted: fitted, container: container)
        #expect(abs(c.x - 0.125) < 0.001)
    }

    @Test func offsetIsZeroWhenCentered() {
        let fitted = ZoomGeometry.fittedSize(imagePixel: pixel, container: container)
        let off = ZoomGeometry.offset(center: CGPoint(x: 0.5, y: 0.5), scale: 3, fitted: fitted, container: container)
        #expect(off == .zero)
    }

    @Test func normalizedPointAndCenterAreInverses() {
        let fitted = ZoomGeometry.fittedSize(imagePixel: pixel, container: container)
        let scale: CGFloat = 4
        let center = CGPoint(x: 0.4, y: 0.6)
        let p = CGPoint(x: 120, y: 500)
        let n = ZoomGeometry.normalizedPoint(atContainerPoint: p, center: center,
                                             scale: scale, fitted: fitted, container: container)
        let back = ZoomGeometry.center(keepingNormalized: n, atContainerPoint: p,
                                       scale: scale, fitted: fitted, container: container)
        #expect(abs(back.x - center.x) < 0.0001)
        #expect(abs(back.y - center.y) < 0.0001)
    }

    @Test func detentEngagesWithinToleranceAndSnapsToExactlyOneToOne() {
        let one: CGFloat = 5
        #expect(Detent.isEngaged(scale: 5.2, oneToOne: one))
        #expect(!Detent.isEngaged(scale: 6.5, oneToOne: one))
        let snapped = Detent.snap(scale: 5.3, oneToOne: one)
        #expect(snapped.snapped)
        #expect(snapped.scale == 5)
        let free = Detent.snap(scale: 3, oneToOne: one)
        #expect(!free.snapped)
        #expect(free.scale == 3)
    }

    // Zoom carrying across a photo switch: the SAME (scale, center) applied to a
    // differently-dimensioned frame stays a valid, edge-covering viewport — the
    // design's "same relative spot, same magnification" rather than raw pixels.
    @Test func carriedZoomStaysValidAcrossDifferentDimensions() {
        let landscape = ZoomGeometry.fittedSize(imagePixel: CGSize(width: 4000, height: 3000), container: container)
        let portrait  = ZoomGeometry.fittedSize(imagePixel: CGSize(width: 3000, height: 4000), container: container)
        let carried = CGPoint(x: 0.3, y: 0.7)
        let scale: CGFloat = 3
        let a = ZoomGeometry.clampedCenter(carried, scale: scale, fitted: landscape, container: container)
        let b = ZoomGeometry.clampedCenter(carried, scale: scale, fitted: portrait, container: container)
        // Both remain inside the legal window for their own frame.
        #expect(a.x >= 0 && a.x <= 1 && a.y >= 0 && a.y <= 1)
        #expect(b.x >= 0 && b.x <= 1 && b.y >= 0 && b.y <= 1)
    }
}

// MARK: - Gesture routing (the "will bite" decision)

struct GestureRouteTests {

    @Test func zoomedDragAlwaysPans() {
        #expect(AnalysisGesture.route(atFit: false, isCompare: true,
                                      translation: CGSize(width: 200, height: 0)) == .pan)
        #expect(AnalysisGesture.route(atFit: false, isCompare: false,
                                      translation: CGSize(width: 5, height: 5)) == .pan)
    }

    @Test func atFitCompareSwipeMovesTheStrip() {
        #expect(AnalysisGesture.route(atFit: true, isCompare: true,
                                      translation: CGSize(width: -60, height: 2)) == .stripNext)
        #expect(AnalysisGesture.route(atFit: true, isCompare: true,
                                      translation: CGSize(width: 60, height: 2)) == .stripPrevious)
    }

    @Test func atFitSingleAnalysisIgnoresSwipe() {
        // Analysis never navigates the queue.
        #expect(AnalysisGesture.route(atFit: true, isCompare: false,
                                      translation: CGSize(width: -200, height: 0)) == .ignore)
    }

    @Test func atFitBelowThresholdOrVerticalIsIgnored() {
        #expect(AnalysisGesture.route(atFit: true, isCompare: true,
                                      translation: CGSize(width: -20, height: 0)) == .ignore)
        #expect(AnalysisGesture.route(atFit: true, isCompare: true,
                                      translation: CGSize(width: -60, height: 200)) == .ignore)
    }
}

// MARK: - Filmstrip movement (bounded, non-wrapping)

struct FilmstripNavigationTests {

    @Test func nextAndPreviousClampAtEnds() {
        #expect(FilmstripNavigation.next(index: 0, count: 5) == 1)
        #expect(FilmstripNavigation.next(index: 4, count: 5) == 4)   // no wrap
        #expect(FilmstripNavigation.previous(index: 0, count: 5) == 0)
        #expect(FilmstripNavigation.previous(index: 3, count: 5) == 2)
    }

    @Test func selectClampsIntoBounds() {
        #expect(FilmstripNavigation.select(-3, count: 5) == 0)
        #expect(FilmstripNavigation.select(99, count: 5) == 4)
        #expect(FilmstripNavigation.select(2, count: 5) == 2)
    }

    @Test func emptySetIsSafe() {
        #expect(FilmstripNavigation.next(index: 0, count: 0) == 0)
        #expect(FilmstripNavigation.select(4, count: 0) == 0)
    }
}

// MARK: - HUD parsing (facets that survive a Fuji transfer)

struct PhotoMetadataTests {

    @Test func parsesShutterIsoApertureAndCamera() {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004,      // 1/250 s
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFNumber: 2.8
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "X-T4"
            ] as [CFString: Any]
        ]
        let m = PhotoMetadata.parse(props)
        #expect(m.shutter == "1/250 s")
        #expect(m.iso == "ISO 400")
        #expect(m.aperture == "f/2.8")
        #expect(m.camera == "X-T4")
    }

    @Test func absentFieldsStayNilAndDoNotInventFocusOrFilmSim() {
        let m = PhotoMetadata.parse([kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFModel: "iPhone 15 Pro"] as [CFString: Any]])
        #expect(m.camera == "iPhone 15 Pro")
        #expect(m.shutter == nil)
        #expect(m.iso == nil)
        #expect(m.aperture == nil)
        // There is deliberately no focus-point or film-simulation field to be nil.
    }

    @Test func nilPropertiesGiveEmptyMetadata() {
        #expect(PhotoMetadata.parse(nil).isEmpty)
    }
}

// MARK: - AnalysisModel exits (single vs compare)

@MainActor
struct AnalysisModelTests {

    private func item(_ i: Int) -> DeckItem {
        DeckItem(id: "a\(i)", asset: nil, sessionID: "s", sessionLabel: "L", syntheticIndex: i)
    }

    @Test func singleVerdictCommitsAndExits() {
        var committed: Verdict?
        var exited = false
        let m = AnalysisModel(kind: .single, items: [item(0)], pipeline: nil,
                              onVerdict: { v, _ in committed = v },
                              onPin: { _ in },
                              onExit: { exited = true })
        m.commit(.keep)
        #expect(committed == .keep)
        #expect(exited)
    }

    @Test func compareVerdictAdvancesTheStripAndStays() {
        var exits = 0
        let m = AnalysisModel(kind: .compare, items: [item(0), item(1), item(2)], pipeline: nil,
                              onVerdict: { _, _ in }, onPin: { _ in }, onExit: { exits += 1 })
        m.commit(.reject)
        #expect(m.index == 1)     // advanced along the strip
        #expect(exits == 0)       // did not leave
        m.stripNext()
        #expect(m.index == 2)
        m.commit(.keep)
        #expect(m.index == 2)     // last frame stays put
    }

    @Test func zoomIsPreservedAcrossFilmstripSwitches() {
        let m = AnalysisModel(kind: .compare, items: [item(0), item(1)], pipeline: nil,
                              onVerdict: { _, _ in }, onPin: { _ in }, onExit: { })
        m.zoom = ZoomState(scale: 3, center: CGPoint(x: 0.4, y: 0.6))
        m.stripNext()
        #expect(m.zoom.scale == 3)
        #expect(m.zoom.center == CGPoint(x: 0.4, y: 0.6))
    }

    @Test func pinAnnotatesWithoutExiting() {
        var pinned: DeckItem?
        var exited = false
        let m = AnalysisModel(kind: .single, items: [item(0)], pipeline: nil,
                              onVerdict: { _, _ in }, onPin: { pinned = $0 }, onExit: { exited = true })
        m.pin()
        #expect(pinned?.id == "a0")
        #expect(!exited)          // an annotation stays in analysis
    }
}

// MARK: - DeckModel compare/in-place recording

@MainActor
struct DeckAnalysisWiringTests {

    @Test func recordInPlaceDoesNotAdvanceButUndoesCleanly() {
        let m = DeckModel.synthetic(count: 4)
        let first = m.current!
        m.recordInPlace(.reject, for: first, pin: false)
        #expect(m.current?.id == first.id)       // cursor unmoved
        #expect(m.currentVerdict(for: first) == .reject)
        #expect(m.canUndo)
        m.undo()
        #expect(m.currentVerdict(for: first) == nil)
    }

    @Test func syntheticCompareLandsOnPinnedOfferWithTheFullSet() {
        let m = DeckModel.syntheticCompare(count: 5)
        #expect(m.phase == .pinnedOffer(5))
        #expect(m.compareItems.count == 5)
        #expect(!m.canUndo)                       // seed left no undo history
    }
}
