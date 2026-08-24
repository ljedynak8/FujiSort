//
//  AnalysisNavigation.swift
//  FujiSort — Milestone 05 (analysis / comparison)
//
//  Two PURE decisions that would otherwise hide inside the UIKit gesture handler:
//  where a one-finger drag goes (pan vs the filmstrip), and how the filmstrip index
//  moves. Both are unit-tested directly.
//
//  The routing is the gesture detail the milestone flags as "will bite": a swipe
//  moves along the strip, but the SAME one-finger drag pans when zoomed. Tapping a
//  thumbnail must always switch; a swipe only navigates when the photo is at fit.
//

import CoreGraphics

/// What a one-finger drag in analysis/compare should do.
enum GestureRoute: Equatable {
    case pan            // move the zoomed image
    case stripPrevious  // move to the previous frame in the compare set
    case stripNext      // move to the next frame
    case ignore         // at fit, single-photo analysis: analysis never navigates the queue
}

enum AnalysisGesture {
    /// Minimum horizontal travel (points) before an at-fit drag counts as a strip move.
    static let stripThreshold: CGFloat = 40

    /// Route a one-finger drag. When zoomed (`atFit == false`) it always pans — this
    /// is why a compare swipe is "reserved for when the photo is at fit". At fit, only
    /// a compare set navigates; single-photo analysis ignores it, because analysis is
    /// a per-photo detour and cannot walk the deck.
    static func route(atFit: Bool, isCompare: Bool, translation: CGSize,
                      threshold: CGFloat = stripThreshold) -> GestureRoute {
        guard atFit else { return .pan }
        guard isCompare else { return .ignore }
        // Predominantly horizontal, past the threshold — otherwise ignore.
        guard abs(translation.width) >= abs(translation.height),
              abs(translation.width) >= threshold else { return .ignore }
        return translation.width < 0 ? .stripNext : .stripPrevious   // swipe left ⇒ next
    }
}

/// Index movement over a bounded, hand-assembled set. Non-wrapping by design: the
/// set has ends, and running off one is a no-op rather than a loop.
enum FilmstripNavigation {
    static func next(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(index + 1, count - 1)
    }

    static func previous(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(index - 1, 0)
    }

    /// Tapping a thumbnail always switches; clamp to the set's bounds.
    static func select(_ target: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, target), count - 1)
    }
}
