//
//  FullImageView.swift
//  FujiSort — Milestone 03 (progressive-load test surface)
//
//  Demonstrates the full-resolution path: placeholder → low-quality → sharp. This
//  is NOT the analysis state (milestone 05): no zoom, no gestures, no verdicts —
//  one Close button. It exists to prove progressive loading and to measure the
//  three stages against the spike's 402 ms median.
//

import SwiftUI
import Photos
import os

struct FullImageView: View {
    let asset: PHAsset
    let pipeline: ImagePipeline

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    private let log = Logger(subsystem: "com.fianchetto.FujiSort", category: "fullscreen")

    var body: some View {
        ZStack {
            // Stage 0: placeholder — the deck surface, shown immediately.
            Palette.deck.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.ink.opacity(0.92))
                            .padding(12)
                            .background(Palette.chrome.opacity(0.6), in: .circle)
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .task(id: asset.localIdentifier) {
            image = nil
            let start = DispatchTime.now()
            log.debug("fullscreen placeholder \(asset.localIdentifier, privacy: .public)")
            var sawDegraded = false
            for await update in pipeline.fullResolutionStream(for: asset) {
                image = update.image
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                if update.isDegraded && !sawDegraded {
                    sawDegraded = true
                    log.debug("fullscreen low-quality at \(ms, format: .fixed(precision: 1)) ms")
                } else if !update.isDegraded {
                    log.debug("fullscreen sharp at \(ms, format: .fixed(precision: 1)) ms")
                }
            }
        }
    }
}

/// Lets a `PHAsset` drive `fullScreenCover(item:)`. Its `localIdentifier` is a
/// stable per-run key.
extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}
