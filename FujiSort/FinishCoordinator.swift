//
//  FinishCoordinator.swift
//  FujiSort — Milestone 07 (finish)
//
//  Owns the album-sync trigger and the first-finish consent, so both stay in one place
//  and out of the views. Injected via the environment from FujiSortApp, over a store
//  built on the shared main context.
//
//  The structural rule (decision 0005): album sync fires on LEAVING THE REVIEW — the
//  ReviewModel.leave() seam — not on a Finish button. Deletion is separate and lives on
//  the finish screen. This type carries only the sync half.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class FinishCoordinator {

    let preferences: AppPreferences
    private let store: JudgmentStore

    /// Raised when the user leaves the review for the first time with candidates to sync,
    /// so the deck can present the one-time opt-in on return. (The review is dismissing as
    /// leave() fires, so the prompt can't live there.) After the first decision, sync just
    /// runs on leave and this is never set again.
    var needsConsent = false

    init(preferences: AppPreferences, context: ModelContext) {
        self.preferences = preferences
        self.store = JudgmentStore(context: context)
    }

    /// Anchors library observation on the app-lifetime store this coordinator holds.
    /// The observer reconciles records over the shared `ModelContext` regardless of
    /// which transient store created them, so one is enough. Idempotent; called once
    /// from `RootView` after authorization. (Milestone 08 — the observer was dead code
    /// since milestone 02; this is what finally starts it.)
    func startObservingLibrary() {
        store.startObservingLibrary()
    }

    /// The ReviewModel.leave() seam. Album sync is the ONLY thing that fires here.
    func reviewDidLeave() {
        if preferences.albumSyncDecided {
            if preferences.albumSyncEnabled {
                Task { await AlbumSync.run(store: store, preferences: preferences) }
            }
        } else if AlbumSync.hasSyncableCandidates(store: store) {
            needsConsent = true
        }
    }

    /// Resolve the first-finish opt-in. Consent is to the mechanism; the first sync runs
    /// here (only the first time), subsequent ones on leave.
    func resolveConsent(enable: Bool) {
        preferences.albumSyncEnabled = enable
        preferences.albumSyncDecided = true
        needsConsent = false
        if enable { Task { await AlbumSync.run(store: store, preferences: preferences) } }
    }

    /// Sync immediately when the user turns album sync on in settings. Revocation is just
    /// turning it off — nothing to undo, the album is left as it stands.
    func syncNow() {
        guard preferences.albumSyncEnabled else { return }
        Task { await AlbumSync.run(store: store, preferences: preferences) }
    }
}
