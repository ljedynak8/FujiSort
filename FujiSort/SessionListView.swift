//
//  SessionListView.swift
//  FujiSort — Milestone 03 (proof surface)
//
//  A scrollable grid of the current session's photos over the thumbnail path,
//  plus one tap target into a progressive full-screen view. This is a pipeline
//  test surface — no gestures, no verdicts (milestone 04), no zoom (milestone 05).
//  Styling is limited to CLAUDE.md's surfaces and ink; the design system lands
//  with the deck.
//

import SwiftUI
import SwiftData
import Photos

/// CLAUDE.md surfaces and ink. Never pure black; ink is white at opacity so it
/// composites over photographs.
enum Palette {
    static let deck   = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255)
    static let grid   = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
    static let chrome = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let ink    = Color.white
}

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var pipeline = ImagePipeline()
    @State private var session: SessionScope.Session?
    @State private var loaded = false
    @State private var visibleIndices: Set<Int> = []
    @State private var selected: PHAsset?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            if let session {
                content(session)
            } else if loaded {
                Text("Nothing left to sort")
                    .font(.body)
                    .foregroundStyle(Palette.ink.opacity(0.60))
            } else {
                ProgressView().tint(Palette.ink.opacity(0.60))
            }
        }
        .task { await loadSession() }
        .fullScreenCover(item: $selected) { asset in
            FullImageView(asset: asset, pipeline: pipeline)
        }
    }

    private func content(_ session: SessionScope.Session) -> some View {
        VStack(spacing: 0) {
            header(session)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(session.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        ThumbnailCell(asset: asset, pipeline: pipeline)
                            .onTapGesture { selected = asset }
                            .onAppear { visibleIndices.insert(index) }
                            .onDisappear { visibleIndices.remove(index) }
                    }
                }
            }
        }
        .onChange(of: visibleIndices) { _, indices in
            guard let lo = indices.min(), let hi = indices.max() else { return }
            pipeline.updateCache(allAssets: session.assets, visibleRange: lo ..< (hi + 1))
        }
        .onDisappear { pipeline.stopCachingAll() }
    }

    private func header(_ session: SessionScope.Session) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(session.label)
                .font(.headline)
                .foregroundStyle(Palette.ink.opacity(0.92))
            Spacer()
            Text("\(session.count)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.opacity(0.60))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadSession() async {
        guard !loaded else { return }
        let store = JudgmentStore(context: modelContext)
        session = SessionScope.current(store: store)
        loaded = true
    }
}

/// One grid tile. Owns its own request; `.task(id:)` cancels it when the tile
/// leaves the deck or is reused, which terminates the stream and cancels the
/// PhotoKit request. Shows the raised surface until the first frame arrives —
/// never blocks on a download.
struct ThumbnailCell: View {
    let asset: PHAsset
    let pipeline: ImagePipeline
    @State private var image: UIImage?

    var body: some View {
        // A flexible, square cell (aspectRatio derives height from the grid's
        // column width). The image fills and is clipped to the square — no
        // GeometryReader, which fought aspectRatio and overflowed the column.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Palette.grid
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                image = nil
                for await update in pipeline.thumbnailStream(for: asset) {
                    image = update.image
                }
            }
    }
}
