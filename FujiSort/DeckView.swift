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

// MARK: - Card geometry (decision 0011 — sort deck only)

/// The sort-mode photograph reads as a card: inset from the safe area on all four
/// sides, rounded, with a hairline edge (fujisort-design `hairline`). Analysis and
/// compare stay full-bleed — the inset means "this is a card in a stack", and there
/// is no stack there. Both values are empirical and expected to move; tunable in the
/// same manner as `FirstRun.minimumTake`.
enum DeckCard {
    static let inset: CGFloat  = 12
    static let radius: CGFloat = 14
}

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
    @Environment(FinishCoordinator.self) private var coordinator
    // First-run coaching + backlog (milestone 08). All of it gates on firstRun.isActive,
    // so in normal mode every branch below is inert.
    @Environment(FirstRunState.self) private var firstRun
    @Environment(\.modelContext) private var modelContext
    @Environment(AppPreferences.self) private var preferences

    @State private var drag: CGSize = .zero
    @State private var didTick = false
    @State private var cardOpacity: Double = 1
    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var zoomTranslation: CGSize = .zero      // two-finger pan (springy)
    @State private var analysis: AnalysisModel?
    @State private var showReview = false
    @State private var showFinish = false
    @State private var showSettings = false
    // First-run only:
    @State private var swipeCount = 0
    @State private var showBacklog = false
    @State private var pendingBacklog = false               // deferred until the consent sheet closes
    @State private var backlogRemaining = 0

    private let maxRotation: Double = 8
    private let commit = Animation.easeOut(duration: 0.22)
    private var cancelSpring: Animation { .spring(response: 0.35, dampingFraction: 0.75) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.deck.ignoresSafeArea()

                // Nothing is drawn behind the card (decision 0011): a photo-shaped
                // inset card would let the next frame peek through the surround, and
                // a glimpse of an unjudged photo previews a decision not yet made.
                // Prefetch keeps the incoming card warm at the pipeline level.
                if let current = model.current {
                    topCard(current, size: geo.size)
                }

                overlays(size: geo.size)

                // Coach marks: chrome over the photograph, gone as soon as they've done
                // their work. Non-interactive so they never contest the gesture surface.
                firstRunCoaching()
            }
        }
        .fullScreenCover(item: $analysis) { analysisModel in
            // The per-photo detour. Tap is the deck's accident sink — instantly
            // reversible, nothing recorded — and now opens the real analysis state.
            AnalysisView(model: analysisModel,
                         verdictOf: { model.currentVerdict(for: $0) })
                .transition(.opacity)
        }
        .fullScreenCover(isPresented: $showReview) {
            // Pass 2, scoped to this run: the candidates marked this sitting (the deck's
            // runCandidateIDs). Album sync still fires when the user leaves, at
            // ReviewHostView's onLeave → coordinator seam.
            ReviewHostView(synthetic: false, scopeIDs: model.runCandidateIDs())
        }
        .fullScreenCover(isPresented: $showFinish) {
            // The finish screen carries deletion and nothing else (decision 0005).
            FinishView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(coordinator: coordinator)
        }
        // First-finish opt-in: raised by the coordinator when the review is left the first
        // time with candidates. Sync still fires on leave once opted in — this only gathers
        // consent to the mechanism, and never fires per sync.
        .sheet(isPresented: Binding(
            get: { coordinator.needsConsent },
            set: { if !$0 { coordinator.needsConsent = false } })) {
            AlbumSyncConsentSheet(
                onSync:  { coordinator.resolveConsent(enable: true) },
                onNotNow: { coordinator.resolveConsent(enable: false) })
        }
        // The backlog offer — raised once, only after the first session completes: deck
        // finished, review offered, albums written. Not now leaves a working full-deck app.
        .sheet(isPresented: $showBacklog) {
            BacklogSheet(remaining: backlogRemaining) { outcome in
                showBacklog = false
                firstRun.pendingScope = outcome     // nil = Not now / full deck next
                firstRun.hasCompletedFirstRun = true
            }
        }
        // Review dismissed during first run → offer the backlog. If the first-finish consent
        // sheet is about to show, wait for it to close first so two sheets never collide.
        .onChange(of: showReview) { was, now in
            guard was, !now, firstRun.isActive else { return }
            if coordinator.needsConsent { pendingBacklog = true } else { presentBacklog() }
        }
        .onChange(of: coordinator.needsConsent) { _, showing in
            if !showing, pendingBacklog { presentBacklog() }
        }
        .onDisappear { model.stopPrefetch() }
    }

    // MARK: Top card

    private func topCard(_ item: DeckItem, size: CGSize) -> some View {
        let verdict = currentVerdict(for: drag)
        let progress = commitProgress(drag)
        // The verdict tint travels with the card and is clipped to its rounded edge
        // (inside DeckCardContent) — never a full-screen wash.
        return DeckCardContent(item: item, pipeline: model.pipeline,
                               glowVerdict: verdict, glowProgress: progress)
            .scaleEffect(zoomScale, anchor: zoomAnchor)
            .offset(zoomTranslation)                       // two-finger pan (springs back)
            .overlay { gestureSurface(size: size, item: item) }
            .rotationEffect(rotation(for: drag, width: size.width))
            .offset(drag)
            .opacity(cardOpacity)
            .id(item.id)
            .accessibilityElement()
            .accessibilityLabel(Text(item.sessionLabel))
            .accessibilityActions {
                ForEach(Verdict.allCases, id: \.self) { v in
                    Button(v.spoken) { model.commit(v); noteFirstRunSwipe() }
                }
                Button("Pin for compare") { model.pin() }
                Button("Analyse") { enterAnalysis() }
                if model.canUndo { Button("Undo") { model.undo() } }
            }
    }

    // MARK: Gestures — the UIKit surface owns all touch (milestone 05)

    /// Transparent multitouch layer. A one-finger drag is swipe-to-decide (streamed
    /// back into the exact milestone-04 path — `SwipeDecision`, the threshold tick,
    /// fly-off). Two-finger pinch+pan is the springy sharpness check that snaps back;
    /// its pan is the piece deferred from milestone 04, given back here. Finger counts
    /// keep the one-finger swipe from ever being contested by the two-finger zoom.
    private func gestureSurface(size: CGSize, item: DeckItem) -> some View {
        PhotoGestureView(
            mode: .springy,
            isCompare: false,
            imagePixelSize: .zero,
            zoom: .constant(.fit),
            onSpringyZoom: { scale, anchor, translation in
                zoomAnchor = anchor
                zoomScale = max(1, scale)
                zoomTranslation = translation
            },
            onSpringyEnded: {
                withAnimation(cancelSpring) {
                    zoomScale = 1; zoomTranslation = .zero
                }
            },
            onDragChanged: { translation, velocity in
                drag = translation
                let crosses = SwipeDecision.crossesCommit(
                    translation: translation, velocity: velocity, thresholds: model.thresholds)
                if crosses && !didTick { Haptics.shared.thresholdCrossed(); didTick = true }
                if !crosses { didTick = false }
            },
            onDragEnded: { translation, velocity in
                didTick = false
                switch SwipeDecision.outcome(translation: translation, velocity: velocity,
                                             thresholds: model.thresholds) {
                case .cancel:
                    withAnimation(cancelSpring) { drag = .zero }
                case .verdict(let verdict):
                    flyOff(verdict, size: size)
                }
            },
            onTap: { enterAnalysis() }
        )
    }

    // MARK: Analysis / compare entry

    private func enterAnalysis() {
        guard let item = model.current else { return }
        // Tap is the accident sink, but it's also the moment the tap coach has taught its
        // lesson — retire it (only relevant during first run).
        if firstRun.isActive { firstRun.hasSeenTapCoach = true }
        analysis = AnalysisModel(
            kind: .single, items: [item], pipeline: model.pipeline,
            onVerdict: { verdict, _ in model.commit(verdict) },          // commits + advances the deck
            onPin: { item in model.recordInPlace(.candidate, for: item, pin: true) }, // annotation, stays
            onExit: { analysis = nil })
    }

    private func enterCompare() {
        let items = model.compareItems
        guard !items.isEmpty else { model.acknowledgePinned(); return }
        analysis = AnalysisModel(
            kind: .compare, items: items, pipeline: model.pipeline,
            onVerdict: { verdict, item in model.recordInPlace(verdict, for: item) },
            onPin: { item in model.recordInPlace(.candidate, for: item, pin: true) },
            onExit: { analysis = nil; model.acknowledgePinned() })
    }

    private func flyOff(_ verdict: Verdict, size: CGSize) {
        Haptics.shared.prepareForDrag()
        if reduceMotion {
            // Reduce Motion: cross-fade of the same duration, never remove feedback.
            withAnimation(commit) { cardOpacity = 0 } completion: {
                model.commit(verdict)
                noteFirstRunSwipe()
                drag = .zero; cardOpacity = 1
            }
        } else {
            withAnimation(commit) { drag = offscreen(for: verdict, size: size, from: drag) } completion: {
                model.commit(verdict)
                noteFirstRunSwipe()
                drag = .zero
            }
        }
    }

    /// First successful swipe retires the swipe coach (persisted — never re-shown, incl. the
    /// second launch); a few swipes in, the tap coach is offered. No-op outside first run.
    private func noteFirstRunSwipe() {
        guard firstRun.isActive else { return }
        swipeCount += 1
        if !firstRun.hasSwiped {
            withAnimation(.easeOut(duration: 0.2)) { firstRun.hasSwiped = true }
        }
        // If they never tap, don't nag forever — retire the tap coach after a while.
        if swipeCount >= 8, !firstRun.hasSeenTapCoach { firstRun.hasSeenTapCoach = true }
    }

    // MARK: First-run coaching (chrome over the photo, gone when done)

    @ViewBuilder
    private func firstRunCoaching() -> some View {
        // Only over a live card mid-pass, and never during a drag (it would fight the swipe
        // it's teaching). Achromatic — coaching is not verdict feedback.
        if firstRun.isActive, model.current != nil, model.phase == .sorting, drag == .zero {
            if !firstRun.hasSwiped {
                swipeCoach()
            } else if !firstRun.hasSeenTapCoach, swipeCount >= 3 {
                tapCoach()
            }
        }
    }

    /// The four directions, on the first card only, retiring after the first swipe.
    private func swipeCoach() -> some View {
        ZStack {
            VStack {
                coachChip("Candidate", "chevron.up")
                Spacer()
                coachChip("Skip", "chevron.down")
            }
            HStack {
                coachChip("Reject", "chevron.left")
                Spacer()
                coachChip("Keep", "chevron.right")
            }
        }
        // Clear the count pill (top-centre) and the button strip (bottom) so the
        // "Candidate"/"Skip" chips don't collide with them.
        .padding(.horizontal, 28)
        .padding(.top, 76)
        .padding(.bottom, 100)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Introduced in context — after a few swipes, not before the first.
    private func tapCoach() -> some View {
        VStack {
            Spacer()
            coachChip("Tap for a closer look", "hand.tap")
                .padding(.bottom, 128)          // clear of the button strip
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func coachChip(_ text: String, _ system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Palette.ink.opacity(0.92))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.chrome.opacity(0.9), in: .capsule)
    }

    // MARK: Backlog offer

    private func presentBacklog() {
        pendingBacklog = false
        backlogRemaining = remainingUnjudgedCount()
        showBacklog = true
    }

    /// How many unjudged photos remain across the whole library — the "N more to sort" count.
    private func remainingUnjudgedCount() -> Int {
        let store = JudgmentStore(context: modelContext)
        let scoped = DeckScope.scopedIdentifiers(includeScreenshots: preferences.includeScreenshots)
        return store.unjudged(scoped: scoped).count
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
                            reviewCount: model.runCandidateIDs().count,
                            onUndo: { model.undo() },
                            onPin: { model.pin() },
                            onReview: { showReview = true })
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
            EndOfDeckSheet(message: "\(n) pinned — compare them?",
                           primary: "Yes", secondary: "Later",
                           onPrimary: { enterCompare() },
                           onSecondary: { model.acknowledgePinned() })
        case .done:
            DoneView(isFirstRun: firstRun.isActive,
                     onReview: { showReview = true },
                     onFinish: { showFinish = true },
                     onSettings: { showSettings = true })
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

}

// MARK: - Card content (image or synthetic)

/// The sort-mode card (decision 0011). The photograph's own bounds are the card:
/// fit to the photo's aspect ratio, inset from the safe area, rounded, with a
/// hairline edge and no shadow. Landscape frames make a wide short card, portrait a
/// tall one — the shape follows the photo, by design. The surround is transparent so
/// only the card is visible; the transforms and gesture surface in DeckView stay
/// full-screen. The verdict tint rides along, clipped to the rounded edge.
private struct DeckCardContent: View {
    let item: DeckItem
    let pipeline: ImagePipeline?
    var glowVerdict: Verdict? = nil
    var glowProgress: Double = 0
    @State private var image: UIImage?

    /// The card's aspect. The loaded image is exact; the asset's pixel dimensions
    /// stand in until it arrives so the card doesn't pop shape. nil (synthetic) fills
    /// the inset area.
    private var aspect: CGFloat? {
        if let image, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        if let asset = item.asset, asset.pixelWidth > 0, asset.pixelHeight > 0 {
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.clear                 // transparent surround — never a second image
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            guard let asset = item.asset, let pipeline else { return }
            image = nil
            for await update in pipeline.fullResolutionStream(for: asset) {
                image = update.image
            }
        }
    }

    private var card: some View {
        content
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { edgeGlow }       // over the photo, clipped by the rounding below
            .clipShape(RoundedRectangle(cornerRadius: DeckCard.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DeckCard.radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)   // hairline, never a shadow
            }
            .padding(DeckCard.inset)
    }

    @ViewBuilder
    private var content: some View {
        if item.asset != nil {
            ZStack {
                Palette.deck            // holds the card's bounds until the pixels arrive
                if let image {
                    // The container already matches the photo's aspect, so fill leaves
                    // no internal mat and the hairline traces the photo's true edge.
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
        } else {
            synthetic
        }
    }

    /// The directional verdict tint, ramping in only near the commit — a directional
    /// edge on the card, not a full-card wash that would misrepresent the photo.
    @ViewBuilder
    private var edgeGlow: some View {
        if let verdict = glowVerdict, let color = verdict.tintColor {
            let intensity = max(0, (glowProgress - 0.4) / 0.6) * verdict.tintCap
            let (start, end) = Self.glowPoints(verdict)
            LinearGradient(colors: [color.opacity(intensity), .clear],
                           startPoint: start, endPoint: end)
                .allowsHitTesting(false)
        }
    }

    private static func glowPoints(_ verdict: Verdict) -> (UnitPoint, UnitPoint) {
        switch verdict {
        case .reject:    return (.leading, .trailing)
        case .keep:      return (.trailing, .leading)
        case .candidate: return (.top, .bottom)
        case .skip:      return (.bottom, .top)
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
    /// Candidates marked this run. The Review affordance appears only when > 0 — mid-pass
    /// access to the scoped pass-2 review, without waiting for the end of the deck.
    let reviewCount: Int
    let onUndo: () -> Void
    let onPin: () -> Void
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 40) {
            stripButton(system: "arrow.uturn.backward", label: "Undo", enabled: canUndo, action: onUndo)
            stripButton(system: "pin", label: "Pin", enabled: true, action: onPin)
            if reviewCount > 0 {
                stripButton(system: "square.grid.2x2", label: "Review", enabled: true, action: onReview)
            }
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

/// The session-end home. Reviewing candidates and deleting rejects are deliberately
/// separate actions (decision 0005) — album sync is not here at all; it fires on leaving
/// the review. Settings sits here because album sync must be revocable.
private struct DoneView: View {
    /// First run introduces pass 2 here, where it's about to be used (interaction skill).
    var isFirstRun: Bool = false
    let onReview: () -> Void
    let onFinish: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Settings")
            .padding(.trailing, 8)

            VStack(spacing: 20) {
                if isFirstRun {
                    VStack(spacing: 8) {
                        Text("You've sorted your first take")
                            .font(.headline)
                            .foregroundStyle(Palette.ink.opacity(0.92))
                        Text("Photos you flicked up are candidates. Take a second pass to pick the best.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Palette.ink.opacity(0.60))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)
                } else {
                    Text("Nothing left to sort")
                        .font(.body)
                        .foregroundStyle(Palette.ink.opacity(0.60))
                }
                Button("Review candidates", action: onReview)
                    .font(.headline)
                    .foregroundStyle(Palette.ink.opacity(0.92))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Palette.chrome, in: .capsule)
                Button("Delete rejected photos", action: onFinish)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink.opacity(0.60))
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The one-time album-sync opt-in, shown on the first finish. Consent is to the mechanism,
/// not to each firing (fujisort-photokit). Declining is free and revocable in settings.
private struct AlbumSyncConsentSheet: View {
    let onSync: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Sync your picks to Photos?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink.opacity(0.92))
            Text("FujiSort can keep a FujiSort · Portfolio and FujiSort · Strong album in Photos, updated whenever you leave the review. It's one-way — your judgments stay the source — and you can turn it off in Settings.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink.opacity(0.60))
            HStack(spacing: 12) {
                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
                Button("Sync", action: onSync)
                    .buttonStyle(.borderedProminent)
            }
            .tint(Palette.ink.opacity(0.38))
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationBackground(Palette.chrome)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Host (real vs synthetic, gated)

struct DeckHostView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppPreferences.self) private var preferences
    @State private var model: DeckModel?

    /// Bounds the deck to a capture window, set by the backlog offer's "Choose a range"
    /// for the first normal deck only (milestone 08). nil is the full newest-first deck.
    var scope: ScopeChoice? = nil

    var body: some View {
        ZStack {
            Palette.deck.ignoresSafeArea()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-synthetic-review") {
                // Boot straight into a synthetic pass-2 review so the grid, swipe,
                // multi-select, toast, undo and filters are driveable in the Simulator,
                // which can't seed a real PhotoKit candidate pool.
                ReviewHostView(synthetic: true)
            } else {
                deckOrLoading
            }
            #else
            deckOrLoading
            #endif
        }
        .task { if model == nil { model = makeModel() } }
    }

    @ViewBuilder
    private var deckOrLoading: some View {
        if let model {
            DeckView(model: model)
        } else {
            ProgressView().tint(Palette.ink.opacity(0.60))
        }
    }

    @MainActor
    private func makeModel() -> DeckModel {
        #if DEBUG
        // Debug-only gesture surface for the Simulator, where PhotoKit can't be
        // seeded. Enable by launching with the `-synthetic-deck` argument (scheme
        // arguments, or the device-interaction session). Never in a normal run.
        if ProcessInfo.processInfo.arguments.contains("-synthetic-compare") {
            return .syntheticCompare()
        }
        if ProcessInfo.processInfo.arguments.contains("-synthetic-deck") {
            return .synthetic()
        }
        #endif
        let store = JudgmentStore(context: modelContext)
        return .live(store: store, pipeline: ImagePipeline(),
                     includeScreenshots: preferences.includeScreenshots,
                     since: scope?.since())
    }
}
