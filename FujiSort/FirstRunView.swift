//
//  FirstRunView.swift
//  FujiSort — Milestone 08 (first-run experience)
//
//  The guided first session (decision 0003). Six steps: prime → prompt → straight into
//  a named recent take → swipe/tap coached in context → pass 2 introduces itself when the
//  deck ends (in DeckView/ReviewView) → the backlog raised only afterwards. The coach
//  marks and the backlog offer live in DeckView/ReviewView, gated on FirstRunState.isActive;
//  this file carries the framing screens and the flow that chooses the take.
//
//  Every screen here that is not a photograph justifies itself: only the permission primer
//  and the access-fallbacks do, and only because a limited/denied grant is expensive to undo.
//  All follow the design skill — Palette.deck, ink at opacity, SF Pro, no illustration.
//

import SwiftUI
import SwiftData
import Photos
import UIKit
import os

// MARK: - Step 1: priming, then the system prompt

struct PrimingView: View {
    /// Triggers the system authorization prompt. Async so the caller can await the grant.
    let onContinue: () async -> Void
    @State private var asking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 14) {
                Text("Sort what you shot")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.ink.opacity(0.92))
                Text("FujiSort works through the photos already in your library, one at a time — keep, reject, or set aside for a closer look. It needs access to all of them so nothing is left out of the pass.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            Button {
                guard !asking else { return }
                asking = true
                Task { await onContinue() }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.chrome, in: .capsule)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .disabled(asking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Access fallbacks (limited / denied) — no half-working mode

/// Limited access is not a supported mode (CLAUDE.md). Say plainly what is missing and
/// route to Settings — the only route that reaches full access. We deliberately do NOT
/// offer the limited-library picker: it stays limited, which is the half-working state
/// the design forbids.
struct LimitedAccessView: View {
    var body: some View {
        AccessMessage(
            title: "FujiSort needs your whole library",
            message: "You've shared only some photos, so FujiSort can't sort the rest. Give it access to all photos in Settings — it only ever reads them.")
    }
}

/// Access denied or restricted: the app has nothing to work on. One screen, a route out.
struct DeniedAccessView: View {
    var body: some View {
        AccessMessage(
            title: "No photos to sort",
            message: "FujiSort needs access to your photo library to sort it. You can grant access in Settings — it only ever reads your photos.")
    }
}

/// Shared framing for the access screens: dark, achromatic, one Settings button.
private struct AccessMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 14) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            Button(action: openSettings) {
                Text("Open Settings")
                    .font(.headline)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.chrome, in: .capsule)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - The flow: choose the take, capture the token, open the deck

/// Resolves what first run opens with, captures the change token at step 2 (so every
/// subsequent launch can be incremental, regardless of the backlog decision later), and
/// hands off to the coached DeckView. On no substantial take, asks the honest scope question.
struct FirstRunFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppPreferences.self) private var preferences
    @Environment(FirstRunState.self) private var firstRun

    private enum Stage: Equatable { case loading, deck, scopeQuestion, nothing }
    @State private var stage: Stage = .loading
    @State private var model: DeckModel?

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            switch stage {
            case .loading:
                ProgressView().tint(Palette.ink.opacity(0.60))
            case .deck:
                if let model { DeckView(model: model) }
            case .scopeQuestion:
                ScopeQuestionView(
                    title: "Where should we start?",
                    subtitle: "There's no recent batch to open with. Pick a range to sort — you can always widen it later.",
                    onChoose: buildScoped)
            case .nothing:
                NothingToSortView()
            }
        }
        .task { if stage == .loading { resolve() } }
    }

    private func resolve() {
        #if DEBUG
        // Debug-only: drive the coached first-run deck in the Simulator, where PhotoKit
        // can't be seeded. Coach marks show because first run is still active. Gate: the
        // same launch arguments the normal deck honours (see DeckHostView).
        if ProcessInfo.processInfo.arguments.contains("-synthetic-deck") {
            model = .synthetic(); stage = .deck; return
        }
        if ProcessInfo.processInfo.arguments.contains("-synthetic-compare") {
            model = .syntheticCompare(); stage = .deck; return
        }
        #endif

        let store = JudgmentStore(context: modelContext)
        // Capture the change token now (step 2), before anything the user decides later.
        ChangeTokenStore.save(PHPhotoLibrary.shared().currentChangeToken)

        switch FirstRun.start(store: store, includeScreenshots: preferences.includeScreenshots) {
        case .take(let take):
            let sliced = take.count >= FirstRun.maximumTake
            Self.log.notice("first-run take selected: \"\(take.label, privacy: .public)\" — \(take.count, privacy: .public) photos (floor \(FirstRun.minimumTake, privacy: .public), cap \(FirstRun.maximumTake, privacy: .public)\(sliced ? ", SLICED" : "", privacy: .public))")
            model = DeckModel.firstRun(store: store, pipeline: ImagePipeline(), take: take)
            stage = .deck
        case .scopeQuestion:
            Self.log.notice("first-run: no take at or above floor \(FirstRun.minimumTake, privacy: .public) — showing scope question")
            stage = .scopeQuestion
        case .nothingToSort:
            Self.log.notice("first-run: nothing to sort (empty or fully judged)")
            stage = .nothing
        }
    }

    // Milestone-08 writeback diagnostic: the floor's real selection is recorded here.
    private static let log = Logger(subsystem: "com.fianchetto.FujiSort", category: "first-run")

    private func buildScoped(_ choice: ScopeChoice) {
        let store = JudgmentStore(context: modelContext)
        model = DeckModel.live(store: store, pipeline: ImagePipeline(),
                               includeScreenshots: preferences.includeScreenshots, since: choice.since())
        stage = .deck
    }
}

/// Genuinely empty library (or everything already judged). Not an error, just nothing to do.
private struct NothingToSortView: View {
    var body: some View {
        Text("Nothing to sort")
            .font(.body)
            .foregroundStyle(Palette.ink.opacity(0.60))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The scope question (fallback + backlog "Choose a range")

/// The honest scope question. Only appropriate once the user has sorted something and can
/// judge what sorting costs — never as a first screen. Reused by the no-take fallback and
/// the backlog offer.
struct ScopeQuestionView: View {
    let title: String
    let subtitle: String
    let onChoose: (ScopeChoice) -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                Text(subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 10) {
                ForEach(ScopeChoice.allCases) { choice in
                    Button { onChoose(choice) } label: {
                        Text(choice.label)
                            .font(.headline)
                            .foregroundStyle(Palette.ink.opacity(0.92))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Palette.chrome, in: .capsule)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The backlog offer (once, after the first session completes)

/// Raised once, only after the first loop finishes. "Not now" is genuinely free — the app
/// already works session-to-session on new arrivals, so the backlog is optional forever.
struct BacklogOfferView: View {
    let remaining: Int
    let onChooseRange: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("\(remaining)")
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink.opacity(0.92))
                Text(remaining == 1 ? "more photo to sort" : "more photos to sort")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink.opacity(0.60))
            }
            HStack(spacing: 12) {
                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
                Button("Choose a range", action: onChooseRange)
                    .buttonStyle(.borderedProminent)
            }
            .tint(Palette.ink.opacity(0.38))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

/// One sheet for the whole backlog decision: the offer, and — if the user chooses to act —
/// the scope question, without stacking two sheets. `onResolve(nil)` is "Not now"; a choice
/// is the range to open the next deck on.
struct BacklogSheet: View {
    let remaining: Int
    let onResolve: (ScopeChoice?) -> Void
    @State private var showRange = false

    var body: some View {
        Group {
            if showRange {
                ScopeQuestionView(
                    title: "How much?",
                    subtitle: "Pick how far back to sort now — you can always do more later.",
                    onChoose: { onResolve($0) })
            } else {
                BacklogOfferView(remaining: remaining,
                                 onChooseRange: { showRange = true },
                                 onNotNow: { onResolve(nil) })
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Palette.chrome)
        .preferredColorScheme(.dark)
    }
}
