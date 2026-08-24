//
//  ReviewView.swift
//  FujiSort — Milestone 06 (pass-2 review)
//
//  The operating table: a square-cropped tile grid with tier filters, three ways to
//  move a photo between tiers (swipe · tap→analysis · long-press→multi-select), and
//  multi-select compare. Utilitarian by intent — square crops are the deliberate
//  exception to the deck's full-bleed rule, because this surface is for acting, not
//  looking. The view only reports gestures; ReviewModel owns all state and the tier
//  logic is the pure TierTransition.
//
//  Design values come from fujisort-design: surface.grid #141416 lifts the tiles off
//  the field, the one accent #E0A33C marks Portfolio and nothing else, ink is white at
//  opacity, and the confirmation toast rides on surface.raised #1C1C1E.
//

import SwiftUI
import SwiftData
import Photos

struct ReviewView: View {
    @Bindable var model: ReviewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Palette.grid.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                FilterBar(model: model)
                grid
            }

            // Bottom-anchored chrome: the multi-select bar, otherwise the toast.
            VStack {
                Spacer()
                if model.isSelecting {
                    SelectionBar(model: model)
                } else if let toast = model.toast {
                    ToastBanner(toast: toast,
                                onUndo: { model.undo() },
                                onDismiss: { model.dismissToast(id: toast.id) })
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.isSelecting)
            .animation(.easeOut(duration: 0.2), value: model.toast)
        }
        .fullScreenCover(item: $model.analysis) { analysisModel in
            AnalysisView(model: analysisModel, tierOf: { model.tierOf($0) })
                .transition(.opacity)
        }
        // Leaving the review is a single event; onDisappear is an idempotent backstop.
        .onDisappear { model.leave() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                model.leave()          // the milestone-07 seam — fires once
                dismiss()
            } label: {
                Label("Done", systemImage: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink.opacity(0.92))
            }
            .accessibilityLabel("Leave review")

            Spacer()

            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(ReviewSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Sort order")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.visibleItems) { item in
                    ReviewTile(item: item,
                               pipeline: model.pipeline,
                               position: model.position(for: item.id),
                               selecting: model.isSelecting,
                               selected: model.isSelected(item.id),
                               onTap: {
                                   if model.isSelecting { model.toggleSelection(id: item.id) }
                                   else { model.analyze(id: item.id) }
                               },
                               onLongPress: { model.beginSelection(id: item.id) },
                               onSwipe: { move in model.swipe(move, id: item.id) })
                        .id(item.id)
                }
            }
            .padding(2)
        }
    }
}

// MARK: - Filter chips (live counts carry the shape of the take)

private struct FilterBar: View {
    @Bindable var model: ReviewModel

    var body: some View {
        let c = model.counts
        HStack(spacing: 8) {
            chip(.all, "All", c.all)
            chip(.portfolio, "Portfolio", c.portfolio)
            chip(.strong, "Strong", c.strong)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func chip(_ filter: ReviewFilter, _ title: String, _ count: Int) -> some View {
        let active = model.filter == filter
        // Portfolio's chip carries the accent when active; the others use ink weight.
        let accent = active && filter == .portfolio
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").monospacedDigit()      // live; monospaced so it doesn't jitter
                    .foregroundStyle((accent ? Palette.deck : Palette.ink).opacity(0.60))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(accent ? Palette.deck : Palette.ink.opacity(active ? 0.92 : 0.60))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(accent ? Palette.portfolio
                                      : Palette.chrome.opacity(active ? 1 : 0.6))
            }
        }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - One tile

private struct ReviewTile: View {
    let item: ReviewItem
    let pipeline: ImagePipeline?
    let position: TierPosition?
    let selecting: Bool
    let selected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onSwipe: (TierMove) -> Void

    @State private var image: UIImage?
    @State private var dragX: CGFloat = 0
    @State private var horizontal = false

    /// Commit distance for a tile swipe. A firm, deliberate drag — the grid scrolls
    /// vertically, so only a clearly horizontal move should retier.
    private let commitDistance: CGFloat = 64

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)          // square: the working-surface exception
            .overlay { thumbnail }
            .overlay(alignment: .topTrailing) { badge }
            .overlay { swipeHint }
            .overlay { selectionOverlay }
            .clipped()
            .contentShape(Rectangle())
            .offset(x: dragX)
            // Simultaneous, not exclusive: the vertical ScrollView keeps its drags, and
            // this only reacts once a drag is clearly horizontal — so scrolling is never
            // swallowed and a horizontal flick still retiers.
            .simultaneousGesture(swipe)
            .onTapGesture { onTap() }
            .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
            .task(id: item.id) {
                guard let asset = item.asset, let pipeline else { return }
                image = nil
                for await update in pipeline.thumbnailStream(for: asset) { image = update.image }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityActions {
                Button("Promote") { onSwipe(.promote) }
                Button("Demote") { onSwipe(.demote) }
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if item.asset == nil {
            ZStack {
                Palette.grid
                Text("\(item.syntheticIndex ?? 0)")
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(Palette.ink.opacity(0.60))
            }
        } else {
            Palette.chrome                              // raised placeholder until the frame lands
        }
    }

    /// Portfolio is the only tile that carries colour — the accent star. Strong is a
    /// quiet achromatic dot; nothing shouts on this surface.
    @ViewBuilder
    private var badge: some View {
        switch position {
        case .portfolio:
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(Palette.portfolio)
                .padding(4)
                .background(Palette.deck.opacity(0.55), in: .circle)
                .padding(4)
        case .strong:
            Circle()
                .fill(Palette.ink.opacity(0.60))
                .frame(width: 6, height: 6)
                .padding(7)
        case nil:
            EmptyView()
        }
    }

    /// A faint directional chevron while a horizontal drag is live — a transient hint,
    /// never persistent colour next to the photo.
    @ViewBuilder
    private var swipeHint: some View {
        if horizontal, abs(dragX) > 8 {
            HStack {
                if dragX > 0 { Spacer() }
                Image(systemName: dragX > 0 ? "arrow.right" : "arrow.left")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Palette.ink.opacity(0.92))
                    .padding(8)
                if dragX < 0 { Spacer() }
            }
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if selecting {
            ZStack {
                Rectangle().fill(Palette.deck.opacity(selected ? 0.0 : 0.35))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(Palette.ink.opacity(selected ? 0.92 : 0.60))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Palette.ink.opacity(0.92), lineWidth: 2)
                }
            }
        }
    }

    // MARK: Swipe (horizontal only, so vertical scroll is never contested)

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !selecting else { return }
                // Claim the drag only when it is predominantly horizontal; a vertical
                // drag leaves dragX at 0 and falls through to the scroll view.
                if !horizontal {
                    horizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                if horizontal { dragX = value.translation.width }
            }
            .onEnded { value in
                defer { horizontal = false }
                guard !selecting, horizontal else { return }
                let dx = value.translation.width
                // Commit on displacement OR a flick — a quick horizontal swipe shouldn't
                // need to travel the full distance (mirrors the deck's velocity trigger).
                let flick = abs(value.predictedEndTranslation.width)
                if abs(dx) >= commitDistance || flick >= 140 {
                    onSwipe(dx > 0 ? .promote : .demote)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
            }
    }

    private var accessibilityLabel: String {
        let tier: String
        switch position {
        case .portfolio: tier = "Portfolio"
        case .strong:    tier = "Strong"
        case nil:        tier = ""
        }
        return "\(item.sessionLabel), \(tier)"
    }
}

// MARK: - Multi-select bottom bar

private struct SelectionBar: View {
    @Bindable var model: ReviewModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.cancelSelection() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Cancel selection")

            Text("\(model.selectionCount)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Palette.ink.opacity(0.92))

            Spacer()

            barButton("Portfolio", system: "star.fill", accent: true) { model.assign(.portfolio) }
            barButton("Strong", system: "checkmark", accent: false) { model.assign(.strong) }
            barButton("Compare", system: "rectangle.on.rectangle", accent: false) { model.compareSelection() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.chrome, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func barButton(_ title: String, system: String, accent: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.body)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(accent ? Palette.portfolio : Palette.ink.opacity(0.92))
            .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(model.selectionCount == 0)
        .accessibilityLabel(title)
    }
}

// MARK: - Confirmation toast

private struct ToastBanner: View {
    let toast: ReviewModel.Toast
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(Palette.ink.opacity(0.92))
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink.opacity(0.92))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.chrome, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Brief, non-nagging: auto-dismisses; a newer move replaces it and this token
        // no longer matches, so the older timer can't clear the newer toast.
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(3.5))
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toast.message). Undo available.")
    }
}

// MARK: - Host (real entry + synthetic gate)

/// Presents the review over the store, or a synthetic one for the Simulator. Leaving is
/// wired here to the milestone-07 seam — currently a no-op marker, never an album write.
struct ReviewHostView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let synthetic: Bool
    @State private var model: ReviewModel?

    var body: some View {
        ZStack {
            Palette.grid.ignoresSafeArea()
            if let model {
                ReviewView(model: model)
            } else {
                ProgressView().tint(Palette.ink.opacity(0.60))
            }
        }
        .task { if model == nil { model = makeModel() } }
    }

    @MainActor
    private func makeModel() -> ReviewModel {
        if synthetic { return .synthetic() }
        let store = JudgmentStore(context: modelContext)
        return .live(store: store, pipeline: ImagePipeline()) {
            // Milestone 07: album sync runs here, when the user leaves the review.
            // One place, observable, idempotent. No album writes in this milestone.
        }
    }
}
