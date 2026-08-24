//
//  SwipeDecision.swift
//  FujiSort — Milestone 04 (pass-1 deck)
//
//  The verdict decision as a PURE function — given a drag's translation, its
//  release velocity, and the thresholds, it returns a verdict or a cancel. Kept
//  free of SwiftUI and PhotoKit so the whole decision surface unit-tests directly
//  (the Simulator can't seed a real deck — see the milestone verification notes).
//
//  Direction → verdict is fixed by FREQUENCY, not importance (interaction skill):
//  the two commonest verdicts get the easy horizontal thumb motions.
//
//    left  → reject     (~28%)
//    right → keep       (~53%)
//    up    → candidate  (~8%)   — up is negative height in screen coordinates
//    down  → skip       (~4%)
//

import CoreGraphics

enum SwipeOutcome: Equatable {
    case verdict(Verdict)
    case cancel
}

/// A flick, not a drag across the screen: a swipe commits when EITHER the
/// displacement OR the release velocity along the dominant axis clears its
/// threshold. Both values live here so they can be tuned in one place.
struct SwipeThresholds: Equatable {
    /// Points. 90 ≈ ¼ of a 390-pt screen — decisively past incidental motion,
    /// well short of "drag the card across the screen".
    var displacement: CGFloat
    /// Points per second. 800 is a brisk, deliberate flick, above the drift a
    /// finger leaves when it lifts off a near-stationary card.
    var velocity: CGFloat

    static let standard = SwipeThresholds(displacement: 90, velocity: 800)
}

enum SwipeDecision {

    /// Translation below this (in points, per axis) is treated as "no movement",
    /// so a pure velocity flick still resolves its axis from the velocity vector.
    private static let translationEpsilon: CGFloat = 0.5

    /// The load-bearing pure function. Deterministic, side-effect free.
    static func outcome(translation: CGSize,
                        velocity: CGSize,
                        thresholds: SwipeThresholds = .standard) -> SwipeOutcome {
        // Dominant axis: the one the finger actually moved along; if it barely
        // moved (a flick from rest), fall back to the velocity vector's axis.
        let movedHorizontally = abs(translation.width) >= translationEpsilon
            || abs(translation.height) >= translationEpsilon
        let horizontal: Bool
        if movedHorizontally {
            horizontal = abs(translation.width) >= abs(translation.height)
        } else {
            horizontal = abs(velocity.width) >= abs(velocity.height)
        }

        let axisTranslation = horizontal ? translation.width : translation.height
        let axisVelocity = horizontal ? velocity.width : velocity.height

        let commits = abs(axisTranslation) >= thresholds.displacement
            || abs(axisVelocity) >= thresholds.velocity
        guard commits else { return .cancel }

        // Direction from the translation if there is one, else from the velocity,
        // so a velocity-only flick still points the right way.
        let signed = abs(axisTranslation) >= translationEpsilon ? axisTranslation : axisVelocity
        if horizontal {
            return .verdict(signed > 0 ? .keep : .reject)
        } else {
            return .verdict(signed < 0 ? .candidate : .skip)   // up (negative) = candidate
        }
    }

    /// True the moment a live drag would commit if released now — drives the
    /// mid-drag `.selection` tick that lets the hand commit or cancel a swipe
    /// without watching the card.
    static func crossesCommit(translation: CGSize,
                              velocity: CGSize,
                              thresholds: SwipeThresholds = .standard) -> Bool {
        outcome(translation: translation, velocity: velocity, thresholds: thresholds) != .cancel
    }
}
