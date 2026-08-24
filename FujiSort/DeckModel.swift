//
//  DeckModel.swift
//  FujiSort — Milestone 04 (pass-1 deck)
//
//  The deck controller: holds the ordered cards, the current position, the pinned
//  compare set, and the end-of-deck phase. It is the single place verdicts commit
//  and undo — the view only reports gestures. Kept @Observable and library-optional
//  so it drives the synthetic Simulator deck and unit-tests unchanged.
//
//  Position is tracked in-memory for the run (a plain index). Persistence of
//  position is by construction: the deck is rebuilt from what is unjudged, so a
//  relaunch lands on the right card without a saved cursor.
//

import Foundation
import Observation
import Photos

@MainActor
@Observable
final class DeckModel {

    /// Where the pass is. The end-of-deck offers are surfaced here, never forced.
    enum Phase: Equatable {
        case sorting
        case skipLap(Int)       // N skipped — another lap?
        case pinnedOffer(Int)   // N pinned — compare them? (compare is milestone 05)
        case done
    }

    private(set) var deck: [DeckItem]
    private(set) var index: Int = 0
    private(set) var pinned: Set<String> = []
    private(set) var phase: Phase = .sorting
    /// The most recent committed verdict, for the synthetic-deck debug readout and
    /// nothing else. Cleared by undo.
    private(set) var lastCommitted: Verdict?

    let thresholds: SwipeThresholds
    let isSynthetic: Bool
    let pipeline: ImagePipeline?

    private let recorder: DeckRecorder
    private var deckAssets: [PHAsset]

    /// One entry per committed card, popped 1:1 by undo. Undo availability tracks
    /// THIS, not the recorder — so a fresh lap starts with a clean undo affordance
    /// while committed verdicts stay in the store.
    private struct UndoMark { let prevIndex: Int; let pinnedID: String? }
    private var marks: [UndoMark] = []

    init(deck: [DeckItem], recorder: DeckRecorder, pipeline: ImagePipeline? = nil,
         thresholds: SwipeThresholds = .standard, isSynthetic: Bool = false) {
        self.deck = deck
        self.recorder = recorder
        self.pipeline = pipeline
        self.thresholds = thresholds
        self.isSynthetic = isSynthetic
        self.deckAssets = deck.compactMap(\.asset)
        if deck.isEmpty { phase = .done }
    }

    // MARK: - Current card / pill

    var current: DeckItem? { index >= 0 && index < deck.count ? deck[index] : nil }
    var next: DeckItem? { index + 1 < deck.count ? deck[index + 1] : nil }
    var canUndo: Bool { !marks.isEmpty }
    var isExhausted: Bool { index >= deck.count }

    /// The current outing's label and REMAINING count. Outings are contiguous in
    /// the deck, so the remaining run of same-outing cards from `index` forward is
    /// exactly what's left in this outing. Relabels/decrements at each seam.
    var pillLabel: String { current?.sessionLabel ?? "" }
    var pillCount: Int {
        guard let sid = current?.sessionID else { return 0 }
        var count = 0
        var i = index
        while i < deck.count, deck[i].sessionID == sid { count += 1; i += 1 }
        return count
    }

    // MARK: - Commit / pin / undo

    func commit(_ verdict: Verdict) { commit(verdict, pinnedID: nil) }

    /// Pin marks the photo a Candidate AND remembers it for the end-of-deck compare
    /// offer. It commits and advances like any verdict — pinning never interrupts
    /// the pass.
    func pin() {
        guard let item = current else { return }
        commit(.candidate, pinnedID: item.id)
    }

    private func commit(_ verdict: Verdict, pinnedID: String?) {
        guard let item = current else { return }
        recorder.record(verdict, for: item)
        if let pinnedID { pinned.insert(pinnedID) }
        marks.append(UndoMark(prevIndex: index, pinnedID: pinnedID))
        lastCommitted = verdict
        Haptics.shared.verdict(verdict)
        advance()
    }

    /// Reverts exactly one committed card. Returns to that photo unjudged — the only
    /// way forward is a fresh verdict (no redo). Covers the store, never the library.
    func undo() {
        guard let mark = marks.popLast() else { return }
        recorder.undoLast()
        index = mark.prevIndex
        if let pinnedID = mark.pinnedID { pinned.remove(pinnedID) }
        lastCommitted = nil
        phase = .sorting
        Haptics.shared.undo()
        refreshPrefetch()
    }

    private func advance() {
        index += 1
        if index >= deck.count { presentEndOfDeck() } else { refreshPrefetch() }
    }

    // MARK: - End of deck

    private func presentEndOfDeck() {
        Task { @MainActor in
            await recorder.drain()          // ensure every verdict has landed
            let skipped = skippedIDs()
            if !skipped.isEmpty { phase = .skipLap(skipped.count) }
            else if !pinned.isEmpty { phase = .pinnedOffer(pinned.count) }
            else { phase = .done }
        }
    }

    /// Recomputed from the recorded verdict, never from tracked membership — the
    /// same trick as the deck itself. This is what makes Skip mean "decide later".
    func skippedIDs() -> [String] {
        deck.compactMap { recorder.verdict(for: $0.id) == .skip ? $0.id : nil }
    }

    /// Accept the skip lap: rebuild the deck from the still-skipped cards, in the
    /// original order. They re-enter with verdict `.skip`; re-sorting overwrites it.
    func beginSkipLap() {
        let skipped = Set(skippedIDs())
        deck = deck.filter { skipped.contains($0.id) }
        deckAssets = deck.compactMap(\.asset)
        index = 0
        marks.removeAll()
        phase = deck.isEmpty ? .done : .sorting
        refreshPrefetch()
    }

    /// Decline the lap; move on to the pinned offer (or finish).
    func leaveSkipped() {
        phase = pinned.isEmpty ? .done : .pinnedOffer(pinned.count)
    }

    /// Compare is milestone 05, so the pinned offer only acknowledges — it never
    /// presents a dead Compare button. Either choice finishes the pass.
    func acknowledgePinned() { phase = .done }

    // MARK: - Prefetch (exercises the milestone-03 pipeline on a fast pass)

    func refreshPrefetch() {
        guard let pipeline, !deckAssets.isEmpty, index < deckAssets.count else { return }
        let lower = min(index, deckAssets.count)
        let upper = min(index + 1, deckAssets.count)
        pipeline.updateCache(allAssets: deckAssets, visibleRange: lower..<max(lower + 1, upper))

        // Warm fingerprints just ahead so commits stay synchronous under a flick.
        let window = deck[index..<min(index + 8, deck.count)]
        recorder.prefetchFingerprints(for: Array(window))
    }

    func stopPrefetch() { pipeline?.stopCachingAll() }
}

// MARK: - Builders

extension DeckModel {
    /// The real deck: all unjudged photos, newest outing first, over the store.
    @MainActor
    static func live(store: JudgmentStore, pipeline: ImagePipeline) -> DeckModel {
        let deck = DeckBuilder.build(store: store)
        let model = DeckModel(deck: deck, recorder: StoreDeckRecorder(store: store), pipeline: pipeline)
        model.refreshPrefetch()
        return model
    }

    /// Debug-only synthetic deck (no PhotoKit) so the whole gesture surface is
    /// driveable in the Simulator, where a real multi-photo deck can't be seeded.
    /// Spans TWO fake outings so the pill seam is exercisable. Gate: see DeckHostView.
    static func synthetic(count: Int = 24) -> DeckModel {
        let split = max(1, count / 2)
        let items: [DeckItem] = (0..<count).map { i in
            let newest = i < split
            return DeckItem(id: "syn-\(i)", asset: nil,
                            sessionID: newest ? "syn-0" : "syn-1",
                            sessionLabel: newest ? "Saturday · 23 Aug 2026" : "Friday · 22 Aug 2026",
                            syntheticIndex: i)
        }
        return DeckModel(deck: items, recorder: SyntheticDeckRecorder(), isSynthetic: true)
    }
}
