//
//  AppPreferences.swift
//  FujiSort — Milestone 07 (finish)
//
//  The minimal, revocable preferences surface. It exists because album sync must be
//  turn-off-able (CLAUDE.md); it is NOT a general preferences pane. Three flags, each
//  persisted to UserDefaults, exposed @Observable so the settings toggles and the deck
//  react. Every flag defaults to OFF — nothing writes to the library, and no screenshots
//  enter the deck, until the user opts in.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {

    private enum Key {
        static let albumSyncDecided   = "m07.albumSyncDecided"
        static let albumSyncEnabled   = "m07.albumSyncEnabled"
        static let writeFavorites     = "m07.writeFavorites"
        static let includeScreenshots = "m07.includeScreenshots"
    }

    private let defaults: UserDefaults

    /// Whether the first-finish opt-in has been answered at all. Until it has, leaving the
    /// review raises the one-time consent prompt rather than syncing.
    var albumSyncDecided: Bool { didSet { defaults.set(albumSyncDecided, forKey: Key.albumSyncDecided) } }

    /// Consent to the album-sync MECHANISM, not to each firing. Once on, sync runs quietly
    /// on every leave; revoked by turning this off in settings.
    var albumSyncEnabled: Bool { didSet { defaults.set(albumSyncEnabled, forKey: Key.albumSyncEnabled) } }

    /// A separate, explicit opt-in. When on, sync additively marks Portfolio photos as
    /// Favorite in Photos — never clears a heart the user set (fujisort-photokit).
    var writeFavorites: Bool { didSet { defaults.set(writeFavorites, forKey: Key.writeFavorites) } }

    /// Screenshots are excluded from the deck by default; this includes them. The data
    /// layer (DeckScope) reads it at deck-build time.
    var includeScreenshots: Bool { didSet { defaults.set(includeScreenshots, forKey: Key.includeScreenshots) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` returns false for an absent key — exactly the intended default.
        self.albumSyncDecided   = defaults.bool(forKey: Key.albumSyncDecided)
        self.albumSyncEnabled   = defaults.bool(forKey: Key.albumSyncEnabled)
        self.writeFavorites     = defaults.bool(forKey: Key.writeFavorites)
        self.includeScreenshots = defaults.bool(forKey: Key.includeScreenshots)
    }
}
