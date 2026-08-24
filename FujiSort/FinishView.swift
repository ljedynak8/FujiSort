//
//  FinishView.swift
//  FujiSort — Milestone 07 (finish)
//
//  The finish screen carries deletion and NOTHING else (decision 0005). Deletion is the
//  only irreversible thing the app does, and the only decision that belongs here. Plain
//  and achromatic: the count shown plainly, the 30-day recovery window stated, no
//  celebration and no gamification. Declining is free — leaving rejects marked is a
//  legitimate outcome, not an incomplete one.
//

import SwiftUI
import SwiftData
import Photos

struct FinishView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var store: JudgmentStore?
    @State private var assets: [PHAsset] = []
    @State private var loaded = false
    @State private var working = false
    @State private var resultMessage: String?

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            content
        }
        .task { load() }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().tint(Palette.ink.opacity(0.60))
        } else if let resultMessage {
            done(resultMessage)
        } else if assets.isEmpty {
            done("No rejected photos to delete.")
        } else {
            prompt
        }
    }

    // MARK: The decision

    private var prompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("\(assets.count)")
                .font(.system(size: 64, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink.opacity(0.92))
            Text(assets.count == 1 ? "rejected photo" : "rejected photos")
                .font(.headline)
                .foregroundStyle(Palette.ink.opacity(0.92))
            Text("Deleting moves them to Recently Deleted, where they can be restored for 30 days.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink.opacity(0.60))
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await runDeletion() }
                } label: {
                    Text(working ? "Deleting…" : "Delete \(assets.count)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Palette.chrome, in: .capsule)
                        .foregroundStyle(Palette.ink.opacity(working ? 0.38 : 0.92))
                }
                .disabled(working)
                Button("Not now") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minHeight: 44)
                    .disabled(working)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
    }

    private func done(_ message: String) -> some View {
        VStack(spacing: 20) {
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink.opacity(0.60))
                .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .font(.headline)
                .foregroundStyle(Palette.ink.opacity(0.92))
                .frame(minHeight: 44)
        }
        .padding(32)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        let store = JudgmentStore(context: modelContext)
        self.store = store
        assets = RejectDeletion.rejectAssets(store: store)
        loaded = true
    }

    private func runDeletion() async {
        guard let store else { return }
        working = true
        let outcome = await RejectDeletion.run(assets: assets, store: store)
        working = false
        if outcome.deletedCount > 0 {
            resultMessage = outcome.deletedCount == 1
                ? "1 photo moved to Recently Deleted."
                : "\(outcome.deletedCount) photos moved to Recently Deleted."
        } else {
            // Cancelled, or nothing was deleted — a free outcome. Just leave; rejects
            // stay marked and can be deleted later.
            dismiss()
        }
    }
}
