//
//  RootView.swift
//  FujiSort — Milestone 03 (authorization gate) · Milestone 08 (first run)
//
//  Full photo-library authorization is required — limited access is not a supported
//  mode (CLAUDE.md). We only ever read; `isFavorite` is never written.
//
//  Routing (milestone 08):
//    .notDetermined → the priming screen (the ONE non-photo screen first run justifies),
//                     then the system prompt.
//    .authorized    → the guided first-run flow until it completes, then the normal deck.
//    .limited       → say plainly what's missing, route to Settings (no half-working mode).
//    .denied        → the app has nothing to work on, route to Settings.
//
//  The library observer — dead since milestone 02 — is started here, once, after
//  authorization (it baselines its fetch at construction, so earlier is too early).
//

import SwiftUI
import Photos

struct RootView: View {
    @Environment(FinishCoordinator.self) private var coordinator
    @Environment(FirstRunState.self) private var firstRun
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            switch status {
            case .authorized:
                authorized
            case .notDetermined:
                // Step 1: prime, THEN prompt. The primer justifies itself because a limited
                // grant is expensive to undo; nothing else non-photographic does.
                PrimingView { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            case .limited:
                LimitedAccessView()
            default:
                // .denied and .restricted: nothing to work on, no partial mode.
                DeniedAccessView()
            }
        }
        // Start observing external library changes once authorized (idempotent). This is
        // the seam that finally runs CLAUDE.md's dormant-record path.
        .task(id: status) {
            if status == .authorized { coordinator.startObservingLibrary() }
        }
    }

    @ViewBuilder
    private var authorized: some View {
        if firstRun.hasCompletedFirstRun {
            // Normal mode. `pendingScope` bounds only this first post-first-run deck, if the
            // user picked a range from the backlog offer; nil is the full newest-first deck.
            DeckHostView(scope: firstRun.pendingScope)
        } else {
            FirstRunFlowView()
        }
    }
}
