//
//  DeckView.swift
//  FujiSort — Milestone 04 (pass-1 deck)
//
//  The sort surface: a full-bleed card that tracks the thumb 1:1, four swipe
//  verdicts, the count pill, the undo / pin strip, and the end-of-deck lap. The
//  view only reports gestures; DeckModel owns all state and the verdict decision
//  lives in the pure SwipeDecision. Motion values come straight from the design
//  skill (commit 0.22 s ease-out, cancel spring 0.35/0.75, rotation ≤8°).
//
//  Zoom note: sort-mode zoom is a springy, two-finger, held sharpness check that
//  snaps back on release (MagnifyGesture, anchored at the pinch). Sticky zoom and
//  two-finger PAN are analysis (milestone 05); a one-finger drag is always the
//  swipe-to-decide and is never contested by the two-finger pinch.
//

import SwiftUI
import SwiftData
import Photos

// MARK: - Verdict visual styling (transient only — never persists next to a photo)

private extension Verdict {
    /// The directional edge-glow tint shown during a swipe. Keep — the common case
    /// — stays achromatic. (design skill: Reject #D9483F, Candidate #E0A33C,
    /// Skip white@20%, Keep none.)
    var tintColor: Color? {
        switch self {
        case .reject:    return Color(red: 0xD9 / 255, green: 0x48 / 255, blue: 0x3F / 255)
        case .candidate: return Color(red: 0xE0 / 255, green: 0xA3 / 255, blue: 0x3C / 255)
        case .skip:      return .white
        case .keep:      return nil
        }
    }
    var tintCap: Double { self == .skip ? 0.20 : 0.45 }
    var spoken: String {
        switch self {
        case .reject: return "Reject"; case .keep: return "Keep"
        case .candidate: return "Candidate"; case .skip: return "Skip"
        }
    }
}

// MARK: - Deck

struct DeckView: View {
    let model: DeckModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drag: CGSize = .zero
    @State private var didTick = false
    @State private var cardOpacity: Double = 1
    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var selectedAsset: PHAsset?

    private let maxRotation: Double = 8
    private let commit = Animation.easeOut(duration: 0.22)
    private var cancelSpring: Animation { .spring(response: 0.35, dampingFraction: 0.75) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.deck.ignoresSafeArea()

                // The next card sits beneath the current one so a commit never
                // leaves a gap — it is already there when the top card flies off.
                if let next = model.next {
                    DeckCardContent(item: next, pipeline: model.pipeline)
                        .allowsHitTesting(false)
                }

                if let current = model.current {
                    topCard(current, size: geo.size)
                }

                overlays(size: geo.size)
            }
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            // Placeholder for the analysis state (milestone 05). For now the tap —
            // the deck's harmless accident sink — opens the milestone-03 viewer.
            FullImageView(asset: asset, pipeline: model.pipeline ?? ImagePipeline())
        }
        .onDisappear { model.stopPrefetch() }
    }

    // MARK: Top card

    private func topCard(_ item: DeckItem, size: CGSize) -> some View {
        let verdict = currentVerdict(for: drag)
        let progress = commitProgress(drag)
        return DeckCardContent(item: item, pipeline: model.pipeline)
            .scaleEffect(zoomScale, anchor: zoomAnchor)
            .overlay { edgeGlow(verdict: verdict, progress: progress) }
            .rotationEffect(rotation(for: drag, width: size.width))
            .offset(drag)
            .opacity(cardOpacity)
            .id(item.id)
            .gesture(swipe(size: size))
            .simultaneousGesture(zoom)
            .onTapGesture { if let asset = item.asset { selectedAsset = asset } }
            .accessibilityElement()
            .accessibilityLabel(Text(item.sessionLabel))
            .accessibilityActions {
                ForEach(Verdict.allCases, id: \.self) { v in
                    Button(v.spoken) { model.commit(v) }
                }
                Button("Pin for compare") { model.pin() }
                if model.canUndo { Button("Undo") { model.undo() } }
            }
    }

    // MARK: Gestures

    private func swipe(size: CGSize) -> some Gesture {
        // minimumDistance keeps a stationary tap from starting a drag, so tap →
        // analysis stays reachable; past it the card tracks the thumb.
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                drag = value.translation
                let crosses = SwipeDecision.crossesCommit(
                    translation: value.translation, velocity: value.velocity,
                    thresholds: model.thresholds)
                if crosses && !didTick { Haptics.shared.thresholdCrossed(); didTick = true }
                if !crosses { didTick = false }
            }
            .onEnded { value in
                didTick = false
                let outcome = SwipeDecision.outcome(
                    translation: value.translation, velocity: value.velocity,
                    thresholds: model.thresholds)
                switch outcome {
                case .cancel:
                    withAnimation(cancelSpring) { drag = .zero }
                case .verdict(let verdict):
                    flyOff(verdict, size: size)
                }
            }
    }

    /// Springy, two-finger, snaps back to fit on release — held by the fingers, not
    /// by state, so there is no way to get stranded zoomed in sort mode.
    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomAnchor = value.startAnchor
                zoomScale = max(1, value.magnification)
            }
            .onEnded { _ in
                withAnimation(cancelSpring) { zoomScale = 1 }
            }
    }

    private func flyOff(_ verdict: Verdict, size: CGSize) {
        Haptics.shared.prepareForDrag()
        if reduceMotion {
            // Reduce Motion: cross-fade of the same duration, never remove feedback.
            withAnimation(commit) { cardOpacity = 0 } completion: {
                model.commit(verdict)
                drag = .zero; cardOpacity = 1
            }
        } else {
            withAnimation(commit) { drag = offscreen(for: verdict, size: size, from: drag) } completion: {
                model.commit(verdict)
                drag = .zero
            }
        }
    }

    // MARK: Overlays (pill, strip, end-of-deck)

    @ViewBuilder
    private func overlays(size: CGSize) -> some View {
        VStack {
            if model.current != nil {
                CountPill(label: model.pillLabel, count: model.pillCount)
                    .padding(.top, 8)
            }
            Spacer()
            if model.current != nil {
                ButtonStrip(canUndo: model.canUndo,
                            onUndo: { model.undo() },
                            onPin: { model.pin() })
                    .padding(.bottom, 8)
            }
        }

        if model.isSynthetic { debugReadout.allowsHitTesting(false) }

        switch model.phase {
        case .sorting:
            EmptyView()
        case .skipLap(let n):
            EndOfDeckSheet(message: "\(n) skipped — another lap?",
                           primary: "Yes", secondary: "Leave them",
                           onPrimary: { model.beginSkipLap() },
                           onSecondary: { model.leaveSkipped() })
        case .pinnedOffer(let n):
            // Compare is milestone 05 — acknowledge the count, don't offer a dead button.
            EndOfDeckSheet(message: "\(n) pinned — compare arrives in a later version.",
                           primary: "Done", secondary: nil,
                           onPrimary: { model.acknowledgePinned() },
                           onSecondary: {})
        case .done:
            DoneView()
        }
    }

    private var debugReadout: some View {
        VStack {
            Spacer()
            Text("verdict=\(model.lastCommitted?.rawValue ?? "—") · i=\(model.index) · pill=\(model.pillCount) · undo=\(model.canUndo ? "y" : "n")")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.ink.opacity(0.60))
                .padding(6)
                .background(Palette.chrome.opacity(0.8), in: .rect(cornerRadius: 6))
                .padding(.bottom, 64)
                .accessibilityIdentifier("deck-debug-readout")
        }
    }

    // MARK: Geometry helpers

    private func rotation(for drag: CGSize, width: CGFloat) -> Angle {
        guard width > 0 else { return .zero }
        let raw = Double(drag.width / width) * maxRotation
        return .degrees(max(-maxRotation, min(maxRotation, raw)))
    }

    /// The verdict a live drag currently points at — for rotation direction and the
    /// pre-commit edge glow. Mirrors SwipeDecision's axis/direction mapping.
    private func currentVerdict(for drag: CGSize) -> Verdict {
        if abs(drag.width) >= abs(drag.height) {
            return drag.width >= 0 ? .keep : .reject
        } else {
            return drag.height < 0 ? .candidate : .skip
        }
    }

    private func commitProgress(_ drag: CGSize) -> Double {
        let dominant = abs(drag.width) >= abs(drag.height) ? abs(drag.width) : abs(drag.height)
        return min(1, Double(dominant) / Double(model.thresholds.displacement))
    }

    private func offscreen(for verdict: Verdict, size: CGSize, from drag: CGSize) -> CGSize {
        let w = size.width * 1.5, h = size.height * 1.5
        switch verdict {
        case .keep:      return CGSize(width: w, height: drag.height)
        case .reject:    return CGSize(width: -w, height: drag.height)
        case .candidate: return CGSize(width: drag.width, height: -h)
        case .skip:      return CGSize(width: drag.width, height: h)
        }
    }

    @ViewBuilder
    private func edgeGlow(verdict: Verdict, progress: Double) -> some View {
        // Ramp in only as the swipe approaches the commit — a directional edge, not
        // a full-card wash that would misrepresent the photo's colour.
        if let color = verdict.tintColor {
            let intensity = max(0, (progress - 0.4) / 0.6) * verdict.tintCap
            let (start, end) = glowPoints(verdict)
            LinearGradient(colors: [color.opacity(intensity), .clear],
                           startPoint: start, endPoint: end)
                .allowsHitTesting(false)
        }
    }

    private func glowPoints(_ verdict: Verdict) -> (UnitPoint, UnitPoint) {
        switch verdict {
        case .reject:    return (.leading, .trailing)
        case .keep:      return (.trailing, .leading)
        case .candidate: return (.top, .bottom)
        case .skip:      return (.bottom, .top)
        }
    }
}

// MARK: - Card content (image or synthetic)

private struct DeckCardContent: View {
    let item: DeckItem
    let pipeline: ImagePipeline?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Palette.deck
            if let asset = item.asset {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                synthetic
            }
        }
        .ignoresSafeArea()
        .task(id: item.id) {
            guard let asset = item.asset, let pipeline else { return }
            image = nil
            for await update in pipeline.fullResolutionStream(for: asset) {
                image = update.image
            }
        }
    }

    // Debug-only card: a plain surface with a big monospaced index, so each swipe
    // is visibly distinct in the Simulator without any PhotoKit backing.
    private var synthetic: some View {
        ZStack {
            Palette.grid
            VStack(spacing: 8) {
                Text("\(item.syntheticIndex ?? 0)")
                    .font(.system(size: 120, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.ink.opacity(0.92))
                Text(item.sessionLabel)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink.opacity(0.60))
            }
        }
    }
}

// MARK: - Chrome

private struct CountPill: View {
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(Palette.ink.opacity(0.92))
            Text("·").foregroundStyle(Palette.ink.opacity(0.38))
            Text("\(count)")
                .monospacedDigit()             // load-bearing: no horizontal jitter
                .foregroundStyle(Palette.ink.opacity(0.60))
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.chrome, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(count) remaining")
    }
}

private struct ButtonStrip: View {
    let canUndo: Bool
    let onUndo: () -> Void
    let onPin: () -> Void

    var body: some View {
        HStack(spacing: 40) {
            stripButton(system: "arrow.uturn.backward", label: "Undo", enabled: canUndo, action: onUndo)
            stripButton(system: "pin", label: "Pin", enabled: true, action: onPin)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Palette.chrome.opacity(0.9), in: .capsule)
    }

    private func stripButton(system: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.body)
                Text(label).font(.caption.weight(.medium))
            }
            .foregroundStyle(Palette.ink.opacity(enabled ? 0.92 : 0.38))
            .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct EndOfDeckSheet: View {
    let message: String
    let primary: String
    let secondary: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                HStack(spacing: 12) {
                    if let secondary {
                        Button(secondary, action: onSecondary)
                            .buttonStyle(.bordered)
                    }
                    Button(primary, action: onPrimary)
                        .buttonStyle(.borderedProminent)
                }
                .tint(Palette.ink.opacity(0.38))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Palette.chrome, in: .rect(cornerRadius: 20))
            .padding(16)
        }
        .background { Color.black.opacity(0.35).ignoresSafeArea() }
    }
}

private struct DoneView: View {
    var body: some View {
        Text("Nothing left to sort")
            .font(.body)
            .foregroundStyle(Palette.ink.opacity(0.60))
    }
}

// MARK: - Host (real vs synthetic, gated)

struct DeckHostView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model: DeckModel?

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            if let model {
                DeckView(model: model)
            } else {
                ProgressView().tint(Palette.ink.opacity(0.60))
            }
        }
        .task { if model == nil { model = makeModel() } }
    }

    @MainActor
    private func makeModel() -> DeckModel {
        #if DEBUG
        // Debug-only gesture surface for the Simulator, where PhotoKit can't be
        // seeded. Enable by launching with the `-synthetic-deck` argument (scheme
        // arguments, or the device-interaction session). Never in a normal run.
        if ProcessInfo.processInfo.arguments.contains("-synthetic-deck") {
            return .synthetic()
        }
        #endif
        let store = JudgmentStore(context: modelContext)
        return .live(store: store, pipeline: ImagePipeline())
    }
}
