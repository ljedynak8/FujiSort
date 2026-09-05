//
//  ReviewModel.swift
//  FujiSort — Milestone 06 (pass-2 review)
//
//  The review controller: the ordered candidate pool, the live filter/sort, the
//  multi-select set, the confirmation toast, and grouped one-action undo. It is the
//  single place tier moves commit and undo — the view only reports gestures. Kept
//  @Observable and library-optional so it drives the synthetic Simulator grid and the
//  unit tests unchanged, exactly like DeckModel.
//
//  The pool is scoped to the current app run: the candidates you marked this sitting,
//  passed in as ids by the deck (CLAUDE.md). The builder still accepts nil to pool every
//  live candidate library-wide — used by the tests and left open for a future entry point.
//
//  Leaving the review is exposed as a SINGLE event (`leave()` → `onLeave`), the one
//  place milestone 07 hooks album sync. Nothing here writes to albums.
//

import Foundation
import Observation
import Photos

@MainActor
@Observable
final class ReviewModel: Identifiable {

    /// A confirmation, shown briefly with an Undo affordance. Every move raises one —
    /// it is what makes a correct disappearance (a demote while filtered) legible.
    struct Toast: Equatable { let id: Int; let message: String }

    /// One user action's worth of undo, however many photos it touched. A multi-select
    /// assign of N is ONE mark that pops N store ops — undo stays one-action-granular.
    private struct Mark { let ops: Int; let ids: [String] }

    /// The full pool, never losing members: a removed photo stays so undo can restore
    /// it to view. Membership in a lane is read live from the recorder.
    private let pool: [ReviewItem]
    private let recorder: ReviewRecorder
    private let onLeave: () -> Void
    let pipeline: ImagePipeline?

    private(set) var items: [ReviewItem]           // pool in current sort order
    var filter: ReviewFilter = .all
    var sort: ReviewSort = .captureDate { didSet { items = sort.order(pool) } }

    private(set) var selection: Set<String> = []
    private(set) var toast: Toast?
    /// Not `private(set)`: the host binds `$model.analysis` to a `fullScreenCover`, which
    /// must write nil on dismissal. The model still owns every non-nil set.
    var analysis: AnalysisModel?

    private var marks: [Mark] = []
    private var toastSeq = 0
    private var didLeave = false

    /// Bumped on every state change. `counts`/`visibleItems`/`position(for:)` read the
    /// live position from the (non-observable) recorder, so without a tracked property
    /// to depend on, a child view like the filter bar would never re-evaluate. Touching
    /// `revision` in those getters is what makes the chip counts update live.
    private(set) var revision = 0
    private func bumpRevision() { revision &+= 1 }

    init(items pool: [ReviewItem], recorder: ReviewRecorder,
         pipeline: ImagePipeline?, onLeave: @escaping () -> Void) {
        self.pool = pool
        self.recorder = recorder
        self.pipeline = pipeline
        self.onLeave = onLeave
        self.items = ReviewSort.captureDate.order(pool)
    }

    // MARK: - Derived view state (live from the recorder)

    func position(for id: String) -> TierPosition? {
        _ = revision                                    // track, so tiles refresh on a move
        return recorder.position(for: id)
    }

    /// The tiles the current filter shows, in sort order. A photo out of the review
    /// (demoted to Keep) matches no lane and simply isn't here.
    var visibleItems: [ReviewItem] {
        _ = revision
        return items.filter { filter.matches(position: recorder.position(for: $0.id)) }
    }

    var counts: ReviewCounts {
        _ = revision                                    // makes the chip counts live
        return ReviewCounting.counts(items: pool) { recorder.position(for: $0) }
    }

    var canUndo: Bool { !marks.isEmpty }

    var isSelecting: Bool { !selection.isEmpty }
    var selectionCount: Int { selection.count }
    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    // MARK: - Moving one photo

    /// A tile swipe. Direction decides the move; the transition is pure and total.
    func swipe(_ move: TierMove, id: String) {
        guard let position = recorder.position(for: id) else { return }
        applySingle(TierTransition.apply(move, from: position), id: id)
    }

    /// A tier assigned from the single-photo analysis strip (Portfolio / Strong / Out).
    func applyFromAnalysis(_ action: TierAction, id: String) {
        applySingle(action.outcome, id: id)
    }

    private func applySingle(_ outcome: TierOutcome, id: String) {
        guard recorder.apply(outcome, for: id) else { return }   // .noChange etc: silent
        marks.append(Mark(ops: 1, ids: [id]))
        bumpRevision()
        Haptics.shared.tierMove(outcome)
        if let message = Self.confirmMessage(outcome, count: 1) { showToast(message) }
    }

    // MARK: - Multi-select

    /// Enter multi-select on a long-press, selecting the pressed tile.
    func beginSelection(id: String) {
        selection = [id]
    }

    func toggleSelection(id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func cancelSelection() { selection.removeAll() }

    /// Assign every selected photo to one destination (the bottom bar). One grouped
    /// undo covers the whole batch; photos already at the destination are silent no-ops.
    func assign(_ action: TierAction) {
        let ids = Array(selection)
        var ops = 0
        for id in ids where recorder.apply(action.outcome, for: id) { ops += 1 }
        if ops > 0 {
            marks.append(Mark(ops: ops, ids: ids))
            bumpRevision()
            Haptics.shared.tierMove(action.outcome)
            if let message = Self.confirmMessage(action.outcome, count: ops) { showToast(message) }
        }
        cancelSelection()
    }

    // MARK: - Undo (grouped, one user action at a time)

    func undo() {
        guard let mark = marks.popLast() else { return }
        for _ in 0..<mark.ops { recorder.undoLast() }
        bumpRevision()
        Haptics.shared.undo()
        toast = nil
    }

    // MARK: - Analysis & compare (reuse milestone 05, tier vocabulary)

    /// Tap a tile → single-photo analysis with the tier strip. Analysis never walks the
    /// grid; it acts on this one photo and returns.
    func analyze(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        analysis = AnalysisModel(
            tiersKind: .single, items: [item.deckItem], pipeline: pipeline,
            onTierAction: { [weak self] action, di in self?.applyFromAnalysis(action, id: di.id) },
            onExit: { [weak self] in self?.analysis = nil })
    }

    /// Long-press multi-select → Compare: the milestone-05 filmstrip over the assembled
    /// set, its buttons speaking tiers. This is the second compare entry path, the one
    /// that needed a grid to select on. The app never starts a comparison on its own.
    func compareSelection() {
        let selected = items.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        analysis = AnalysisModel(
            tiersKind: .compare, items: selected.map(\.deckItem), pipeline: pipeline,
            onTierAction: { [weak self] action, di in self?.applyFromAnalysis(action, id: di.id) },
            onExit: { [weak self] in self?.analysis = nil })
        cancelSelection()
    }

    /// Applied-tier lookup for the analysis strip.
    func tierOf(_ item: DeckItem) -> TierPosition? { recorder.position(for: item.id) }

    // MARK: - Leaving the review (the milestone-07 seam)

    /// The ONE place leaving the review is signalled. Milestone 07 hooks album sync
    /// here; this milestone only fires the event, exactly once, and writes nothing.
    func leave() {
        guard !didLeave else { return }
        didLeave = true
        onLeave()
    }

    // MARK: - Toast plumbing

    private func showToast(_ message: String) {
        toastSeq += 1
        toast = Toast(id: toastSeq, message: message)
    }

    /// Dismiss the toast if it is still the one that raised this token (so a newer move
    /// never has its toast cleared by an older auto-dismiss).
    func dismissToast(id: Int) { if toast?.id == id { toast = nil } }

    private static func confirmMessage(_ outcome: TierOutcome, count: Int) -> String? {
        let destination: String
        switch outcome {
        case .tier(.portfolio): destination = "Portfolio"
        case .tier(.strong):    destination = "Strong"
        case .removeFromReview: destination = "Keep"
        case .noChange:         return nil
        }
        return count == 1 ? "Moved to \(destination)" : "\(count) moved to \(destination)"
    }
}

// MARK: - Builders

extension ReviewModel {

    /// The real review, scoped to the CURRENT app run: the live candidates whose ids are in
    /// `restrictTo` (the deck's `runCandidateIDs()`). Passing nil pools every live candidate
    /// across the library — kept for tests and any future non-scoped entry. captureDate and
    /// the dHash come straight off the stored fingerprint — no PhotoKit round-trip — so the
    /// similarity sort is nearly free and the fingerprints are always warm (they are
    /// mandatory at record creation, milestone 02).
    @MainActor
    static func live(store: JudgmentStore, pipeline: ImagePipeline,
                     restrictTo ids: Set<String>? = nil,
                     onLeave: @escaping () -> Void) -> ReviewModel {
        var candidates = store.allJudgments().filter { $0.verdict == .candidate && !$0.isDormant }
        if let ids { candidates = candidates.filter { ids.contains($0.assetLocalIdentifier) } }

        var byID: [String: PHAsset] = [:]
        let ids = candidates.map(\.assetLocalIdentifier)
        if !ids.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        }

        // Per-candidate capture date + hash from the record; cluster into outings so the
        // "by outing" sort has stable session boundaries across the whole pool.
        var meta: [String: (date: Date, hash: UInt64)] = [:]
        var dated: [(id: String, date: Date)] = []
        for j in candidates {
            let date = j.fpCreationDate ?? byID[j.assetLocalIdentifier]?.creationDate ?? .distantPast
            meta[j.assetLocalIdentifier] = (date, UInt64(bitPattern: j.fpHash))
            dated.append((j.assetLocalIdentifier, date))
        }
        var sessionOf: [String: (id: String, label: String)] = [:]
        for (index, members) in SessionClusterer.cluster(dated).enumerated() {
            let clusterDate = members.first.flatMap { meta[$0]?.date } ?? Date()
            let label = SessionScope.label(for: clusterDate)
            for id in members { sessionOf[id] = ("s\(index)", label) }
        }

        let items: [ReviewItem] = candidates.compactMap { j in
            let id = j.assetLocalIdentifier
            guard let asset = byID[id], let m = meta[id] else { return nil }   // asset gone → skip
            let session = sessionOf[id] ?? ("s0", SessionScope.label(for: m.date))
            return ReviewItem(id: id, asset: asset, sessionID: session.id,
                              sessionLabel: session.label, captureDate: m.date,
                              hash: m.hash, syntheticIndex: nil)
        }

        return ReviewModel(items: items, recorder: StoreReviewRecorder(store: store),
                           pipeline: pipeline, onLeave: onLeave)
    }

    /// Debug-only synthetic review (no PhotoKit) so the whole grid — swipe, multi-select,
    /// toast, undo, filters — is driveable in the Simulator. Mixed tiers, two outings,
    /// and adjacent near-duplicate hash pairs so the similarity sort visibly groups them.
    static func synthetic(count: Int = 30) -> ReviewModel {
        let split = max(1, count / 2)
        let base = Date()
        var seed: [String: TierPosition] = [:]
        var items: [ReviewItem] = []
        for i in 0..<count {
            let id = "rev-\(i)"
            let newest = i < split
            // Pairs (0,1), (2,3)… share a hash, so similarity chains them next to each other.
            let hash = UInt64(i / 2) &* 0x1111_1111_1111_1111
            let date = base.addingTimeInterval(TimeInterval(-i * 3600))
            items.append(ReviewItem(id: id, asset: nil,
                                    sessionID: newest ? "syn-0" : "syn-1",
                                    sessionLabel: newest ? "Saturday · 23 Aug 2026"
                                                         : "Friday · 22 Aug 2026",
                                    captureDate: date, hash: hash, syntheticIndex: i))
            seed[id] = (i % 5 == 0) ? .portfolio : .strong
        }
        return ReviewModel(items: items, recorder: SyntheticReviewRecorder(seed: seed),
                           pipeline: nil, onLeave: {})
    }
}
