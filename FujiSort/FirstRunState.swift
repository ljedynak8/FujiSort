//
//  FirstRunState.swift
//  FujiSort — Milestone 08 (first-run experience)
//
//  Internal first-run bookkeeping — the master gate plus the "shown once" flags that
//  retire each coach mark. Persisted to UserDefaults so a coach never returns on the
//  second launch (a first run that has already run is not a first run). This is NOT a
//  settings surface: none of it appears in SettingsView, which stays the three toggles
//  from milestone 07. Mirrors AppPreferences' shape so it injects the same way.
//

import Foundation
import Observation

@MainActor
@Observable
final class FirstRunState {

    private enum Key {
        static let completed      = "m08.hasCompletedFirstRun"
        static let swiped         = "m08.hasSwiped"
        static let tapCoach       = "m08.hasSeenTapCoach"
        static let reviewIntro    = "m08.hasSeenReviewIntro"
    }

    private let defaults: UserDefaults

    /// The master gate. While false, RootView runs the guided first-run flow; once true,
    /// it drops into the normal full deck. Set only after the first session completes —
    /// deck finished, review offered, albums written, backlog raised.
    var hasCompletedFirstRun: Bool { didSet { defaults.set(hasCompletedFirstRun, forKey: Key.completed) } }

    /// Retires the swipe coach after the first successful swipe. Persisted so it does not
    /// return on the second launch.
    var hasSwiped: Bool { didSet { defaults.set(hasSwiped, forKey: Key.swiped) } }

    /// Retires the tap-to-analyse coach, shown in context after a few swipes.
    var hasSeenTapCoach: Bool { didSet { defaults.set(hasSeenTapCoach, forKey: Key.tapCoach) } }

    /// Retires the pass-2 tier introduction, shown where the tiers are used (the review).
    var hasSeenReviewIntro: Bool { didSet { defaults.set(hasSeenReviewIntro, forKey: Key.reviewIntro) } }

    /// Scope chosen from the backlog offer's "Choose a range", applied to the FIRST normal
    /// deck build only. Deliberately IN-MEMORY, not persisted: a relaunch is always the full
    /// deck, so the backlog stays optional forever and nothing is scoped behind the user's back.
    var pendingScope: ScopeChoice?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` returns false for an absent key — the intended fresh-install default.
        self.hasCompletedFirstRun = defaults.bool(forKey: Key.completed)
        self.hasSwiped            = defaults.bool(forKey: Key.swiped)
        self.hasSeenTapCoach      = defaults.bool(forKey: Key.tapCoach)
        self.hasSeenReviewIntro   = defaults.bool(forKey: Key.reviewIntro)
    }

    /// True during the guided first session — the single signal every coach mark and the
    /// backlog offer gate on, so no explicit flag needs threading through the views.
    var isActive: Bool { !hasCompletedFirstRun }
}
