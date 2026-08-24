//
//  AnalysisView.swift
//  FujiSort — Milestone 05 (analysis / comparison)
//
//  The per-photo detour: same full-bleed frame as the deck, but zoom now STICKS.
//  Comparison is this same view with a filmstrip — not a separate mode. The gesture
//  surface (PhotoGestureView) owns touch; SwiftUI here applies the resulting zoom,
//  loads the image progressively, and lays out the chrome that RETREATS while the
//  fingers are down so it never covers what is being studied.
//
//  Design values come from the fujisort-design skill: surfaces #0B0B0C/#1C1C1E,
//  white-at-opacity ink, no persistent colour next to the photograph, SF Pro,
//  monospaced digits on the HUD numerics, full-bleed image with no radius or border.
//

import SwiftUI
import Photos

struct AnalysisView: View {
    @Bindable var model: AnalysisModel
    /// Lets the strip show which mark is already applied, without the model reaching
    /// into the store. Nil where identity isn't tracked (synthetic harness).
    var verdictOf: (DeckItem) -> Verdict? = { _ in nil }
    /// The pass-2 equivalent: which tier the current photo already sits in, for the
    /// tier strip's applied state. Nil when not in the review.
    var tierOf: (DeckItem) -> TierPosition? = { _ in nil }

    @Environment(\.displayScale) private var displayScale
    @State private var interacting = false
    @State private var metadata: [String: PhotoMetadata] = [:]

    private var chromeOpacity: Double { interacting ? 0 : 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.deck.ignoresSafeArea()

                if let item = model.current {
                    AnalysisStage(item: item,
                                  container: geo.size,
                                  displayScale: displayScale,
                                  pipeline: model.pipeline,
                                  isCompare: model.isCompare,
                                  clippingOn: model.clippingOn,
                                  zoom: $model.zoom,
                                  interacting: $interacting,
                                  onReachedOneToOne: { Haptics.shared.reachedOneToOne() },
                                  onStripNext: { model.stripNext() },
                                  onStripPrevious: { model.stripPrevious() })
                        .id(model.isCompare ? "compare" : item.id)   // keep one stage across compare switches so zoom carries
                }

                chrome(geo: geo)
                    .opacity(chromeOpacity)
                    .animation(.easeOut(duration: 0.15), value: interacting)
            }
        }
        .task(id: hudKey) { await loadMetadataIfNeeded() }
    }

    // MARK: - Chrome (retreats on touch)

    @ViewBuilder
    private func chrome(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if model.hudOn, let item = model.current, let m = metadata[item.id], !m.isEmpty {
                HUDPanel(metadata: m).padding(.bottom, 8)
            }
            if model.isCompare {
                Filmstrip(model: model).padding(.bottom, 8)
            }
            switch model.stripKind {
            case .verdicts:
                VerdictStrip(applied: model.current.flatMap(verdictOf),
                             isCompare: model.isCompare,
                             onVerdict: { model.commit($0) },
                             onPin: { model.pin() },
                             onExit: { model.cancel() })
                    .padding(.bottom, 8)
            case .tiers:
                TierStrip(applied: model.current.flatMap(tierOf),
                          isCompare: model.isCompare,
                          onTier: { model.commitTier($0) },
                          onExit: { model.cancel() })
                    .padding(.bottom, 8)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 20) {
            iconButton("xmark", label: "Cancel", active: true) { model.cancel() }
            Spacer()
            iconButton("camera.aperture", label: "Info", active: model.hudOn) { model.hudOn.toggle() }
            iconButton("sun.max", label: "Clipping", active: model.clippingOn) { model.clippingOn.toggle() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func iconButton(_ system: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.ink.opacity(active ? 0.92 : 0.60))
                .frame(minWidth: 44, minHeight: 44)
                .background(Palette.chrome.opacity(0.6), in: .circle)
        }
        .accessibilityLabel(label)
    }

    // MARK: - HUD metadata loading (only when the HUD is on)

    private var hudKey: String { "\(model.hudOn)-\(model.current?.id ?? "")" }

    private func loadMetadataIfNeeded() async {
        guard model.hudOn, let item = model.current, let asset = item.asset,
              metadata[item.id] == nil else { return }
        metadata[item.id] = await PhotoMetadata.load(for: asset)
    }
}

// MARK: - The image + gesture surface + loading state

private struct AnalysisStage: View {
    let item: DeckItem
    let container: CGSize
    let displayScale: CGFloat
    let pipeline: ImagePipeline?
    let isCompare: Bool
    let clippingOn: Bool
    @Binding var zoom: ZoomState
    @Binding var interacting: Bool
    let onReachedOneToOne: () -> Void
    let onStripNext: () -> Void
    let onStripPrevious: () -> Void

    @State private var image: UIImage?
    @State private var isSharp = false
    @State private var clipping: UIImage?

    private var pixelSize: CGSize {
        if let a = item.asset { return CGSize(width: a.pixelWidth, height: a.pixelHeight) }
        if let image { return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }
        return container
    }
    private var fitted: CGSize { ZoomGeometry.fittedSize(imagePixel: pixelSize, container: container) }
    private var offset: CGSize {
        ZoomGeometry.offset(center: zoom.center, scale: zoom.scale, fitted: fitted, container: container)
    }
    /// At/above ~1:1 while the sharp original hasn't landed — say so rather than
    /// letting an upscaled preview pass for actual pixels.
    private var showingUpscaledAt1to1: Bool {
        guard item.asset != nil, !isSharp else { return false }
        let one = ZoomGeometry.oneToOneScale(imagePixel: pixelSize, container: container, displayScale: displayScale)
        return zoom.scale >= one * 0.95
    }

    var body: some View {
        ZStack {
            imageLayer
            PhotoGestureView(mode: .sticky,
                             isCompare: isCompare,
                             imagePixelSize: item.asset != nil ? pixelSize : .zero,
                             zoom: $zoom,
                             onReachedOneToOne: onReachedOneToOne,
                             onStripNext: onStripNext,
                             onStripPrevious: onStripPrevious,
                             onInteractingChanged: { interacting = $0 })

            if item.asset != nil && !isSharp { loadingBadge }
            if showingUpscaledAt1to1 { upscaleBadge }
        }
        .ignoresSafeArea()
        .task(id: item.id) { await load() }
        .task(id: clippingTaskKey) { refreshClipping() }
    }

    @ViewBuilder
    private var imageLayer: some View {
        Group {
            if let image {
                ZStack {
                    Image(uiImage: image).resizable().scaledToFit()
                    if clippingOn, let clipping {
                        Image(uiImage: clipping).resizable().scaledToFit()
                    }
                }
            } else if item.asset == nil {
                synthetic            // debug card: a big number, so the Simulator can see zoom/pan/switch
            } else {
                Palette.deck         // real asset not yet delivered — the deck surface, shown immediately
            }
        }
        // The zoom transform applies to whatever is on screen — real, loading, or
        // synthetic — so a gesture never blocks on the download.
        .scaleEffect(zoom.scale, anchor: .center)
        .offset(x: offset.width, y: offset.height)
    }

    private var synthetic: some View {
        ZStack {
            Palette.grid
            Text("\(item.syntheticIndex ?? 0)")
                .font(.system(size: 160, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.ink.opacity(0.92))
        }
    }

    private var loadingBadge: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.ink.opacity(0.92))
                Text("Loading full resolution")
                    .font(.caption2)
                    .foregroundStyle(Palette.ink.opacity(0.60))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.chrome.opacity(0.8), in: .capsule)
            .padding(.bottom, 120)
        }
        .allowsHitTesting(false)
    }

    private var upscaleBadge: some View {
        VStack {
            Text("Preview — not full resolution")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.ink.opacity(0.92))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.chrome.opacity(0.85), in: .capsule)
                .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var clippingTaskKey: String { "\(item.id)-\(clippingOn)-\(isSharp)" }

    private func refreshClipping() {
        guard clippingOn, isSharp, let image, clipping == nil else {
            if !clippingOn { clipping = nil }
            return
        }
        clipping = ClippingOverlay.make(for: image)
    }

    private func load() async {
        image = nil; clipping = nil
        // Synthetic cards have nothing to fetch — treat them as already sharp so the
        // loading badge and 1:1 warning stay off.
        guard let asset = item.asset, let pipeline else { isSharp = true; return }
        isSharp = false
        for await update in pipeline.fullResolutionStream(for: asset) {
            image = update.image
            isSharp = !update.isDegraded
        }
    }
}

// MARK: - HUD panel

private struct HUDPanel: View {
    let metadata: PhotoMetadata

    var body: some View {
        HStack(spacing: 14) {
            ForEach(fields, id: \.self) { field in
                Text(field).monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.ink.opacity(0.60))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Palette.chrome.opacity(0.85), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fields.joined(separator: ", "))
    }

    private var fields: [String] {
        [metadata.shutter, metadata.aperture, metadata.iso, metadata.camera].compactMap { $0 }
    }
}

// MARK: - Filmstrip (compare only)

private struct Filmstrip: View {
    let model: AnalysisModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        Thumb(item: item, pipeline: model.pipeline, selected: i == model.index)
                            .id(i)
                            .onTapGesture { model.select(i) }   // tapping a thumbnail always switches
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 64)
            .onChange(of: model.index) { _, i in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private struct Thumb: View {
        let item: DeckItem
        let pipeline: ImagePipeline?
        let selected: Bool
        @State private var image: UIImage?

        var body: some View {
            ZStack {
                Palette.grid
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if item.asset == nil {
                    Text("\(item.syntheticIndex ?? 0)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Palette.ink.opacity(0.60))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Palette.ink.opacity(selected ? 0.92 : 0.08),
                                  lineWidth: selected ? 2 : 1)
            }
            .task(id: item.id) {
                guard let asset = item.asset, let pipeline else { return }
                for await update in pipeline.thumbnailStream(for: asset) { image = update.image }
            }
        }
    }
}

// MARK: - Verdict button strip

private extension Verdict {
    var icon: String {
        switch self {
        case .reject: return "xmark"
        case .keep: return "checkmark"
        case .candidate: return "star"
        case .skip: return "arrow.uturn.right"
        }
    }
    var title: String {
        switch self {
        case .reject: return "Reject"; case .keep: return "Keep"
        case .candidate: return "Candidate"; case .skip: return "Skip"
        }
    }
}

private struct VerdictStrip: View {
    let applied: Verdict?
    let isCompare: Bool
    let onVerdict: (Verdict) -> Void
    let onPin: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Same order as the deck's frequency mapping, so muscle memory transfers.
            ForEach(Verdict.allCases, id: \.self) { v in
                verdictButton(v)
            }
            annotationButton(system: "pin", label: "Pin", action: onPin)
            if isCompare {
                annotationButton(system: "checkmark.circle", label: "Done", action: onExit)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.chrome.opacity(0.92), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
    }

    private func verdictButton(_ v: Verdict) -> some View {
        let isApplied = applied == v
        return Button { onVerdict(v) } label: {
            VStack(spacing: 3) {
                Image(systemName: v.icon).font(.body)
                Text(v.title).font(.caption.weight(.medium))
            }
            // Applied state is shown by ink weight, never by a persistent colour next
            // to the photograph (design skill).
            .foregroundStyle(Palette.ink.opacity(isApplied ? 0.92 : 0.60))
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if isApplied {
                    Capsule().fill(Palette.ink.opacity(0.92)).frame(width: 16, height: 2)
                }
            }
        }
        .accessibilityLabel(v.title)
        .accessibilityAddTraits(isApplied ? [.isSelected] : [])
    }

    private func annotationButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.body)
                Text(label).font(.caption.weight(.medium))
            }
            .foregroundStyle(Palette.ink.opacity(0.60))
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Tier button strip (pass 2)

/// The analysis strip when reached from the review: Portfolio · Strong · Out — the
/// same strip, same positions as the verdict strip, different vocabulary
/// (fujisort-interaction). Portfolio carries the one accent (fujisort-design: the
/// accent marks "the Portfolio button in the analysis strip"); Strong is ink only.
private struct TierStrip: View {
    let applied: TierPosition?
    let isCompare: Bool
    let onTier: (TierAction) -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tierButton(.portfolio, system: "star.fill", title: "Portfolio",
                       isApplied: applied == .portfolio, accent: true)
            tierButton(.strong, system: "checkmark", title: "Strong",
                       isApplied: applied == .strong, accent: false)
            tierButton(.out, system: "arrow.uturn.left", title: "Out",
                       isApplied: false, accent: false)
            if isCompare {
                Button(action: onExit) {
                    VStack(spacing: 3) {
                        Image(systemName: "checkmark.circle").font(.body)
                        Text("Done").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Done")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.chrome.opacity(0.92), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
    }

    private func tierButton(_ action: TierAction, system: String, title: String,
                            isApplied: Bool, accent: Bool) -> some View {
        // Portfolio's accent is allowed here (it is not adjacent to the photograph in
        // the way a persistent tile tint would be); Strong/Out stay achromatic. Applied
        // state is carried by the underline, so the strip reads without colour too.
        let tint = accent ? Palette.portfolio : Palette.ink.opacity(isApplied ? 0.92 : 0.60)
        return Button { onTier(action) } label: {
            VStack(spacing: 3) {
                Image(systemName: system).font(.body)
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if isApplied {
                    Capsule().fill(accent ? Palette.portfolio : Palette.ink.opacity(0.92))
                        .frame(width: 16, height: 2)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isApplied ? [.isSelected] : [])
    }
}
