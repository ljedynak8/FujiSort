//
//  RootView.swift
//  FujiSort — Milestone 03 (authorization gate)
//
//  Full photo-library authorization is required — limited access is not a
//  supported mode (CLAUDE.md). We only ever read; `isFavorite` is never written.
//

import SwiftUI
import Photos

struct RootView: View {
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            switch status {
            case .authorized:
                DeckHostView()
            case .notDetermined:
                ProgressView()
                    .tint(Palette.ink.opacity(0.60))
                    .task { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            default:
                // .limited and .denied both land here: limited is unsupported.
                VStack(spacing: 12) {
                    Text("Full photo access required")
                        .font(.headline)
                        .foregroundStyle(Palette.ink.opacity(0.92))
                    Text("FujiSort sorts your whole library and needs full access. Enable it in Settings.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.ink.opacity(0.60))
                }
                .padding(32)
            }
        }
    }
}
