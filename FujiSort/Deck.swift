//
//  Deck.swift
//  FujiSort — Milestone 04 (pass-1 deck)
//
//  The deck's data spine: what a card is, how the ordered deck is built, and how
//  verdicts are recorded/undone behind it. Ordering and recording are split from
//  SwiftUI so they test without a library.
//
//  Deck definition (CLAUDE.md, confirmed with the user): ALL unjudged photos,
//  ordered outing-by-outing NEWEST FIRST, capture order (ascending) within each
//  outing. The count pill is per-outing; the deck spans outings. No cursor, no
//  saved position — the deck is recomputed from what is unjudged, so closing
//  mid-deck and reopening lands on the right card by construction.
//

import Foundation
import Photos

/// One card. `asset` is nil for a synthetic debug card (see DeckModel.synthetic).
struct DeckItem: Identifiable, Equatable {
    let id: String
    let asset: PHAsset?
    let sessionID: String
    let sessionLabel: String
    let syntheticIndex: Int?

    static func == (lhs: DeckItem, rhs: DeckItem) -> Bool { lhs.id == rhs.id }
}

/// Pure ordering output — one entry per deck card, in deck order.
struct DeckEntry: Equatable {
    let id: String
    let sessionID: String
    let sessionLabel: String
}

enum DeckBuilder {

    /// Pure core. Clusters arrive in ascending capture order (SessionClusterer);
    /// emit them newest-outing-first, ascending within, dropping judged ids and
    /// tagging every card with its outing so the pill can count per outing.
    static func order(clusters: [(sessionID: String, label: String, members: [String])],
                      judged: Set<String>) -> [DeckEntry] {
        var out: [DeckEntry] = []
        for cluster in clusters.reversed() {                 // newest outing first
            for id in cluster.members where !judged.contains(id) {
                out.append(DeckEntry(id: id, sessionID: cluster.sessionID, sessionLabel: cluster.label))
            }
        }
        return out
    }

    /// Device wrapper. Same scope as the rest of the app (DeckScope), clustered by
    /// capture date, ordered newest outing first. `since` optionally bounds the deck to
    /// captures on or after a date — used by the backlog offer's "Choose a range" and the
    /// no-substantial-take scope question (milestone 08); nil is the full deck.
    @MainActor
    static func build(store: JudgmentStore, includeScreenshots: Bool = false, since: Date? = nil) -> [DeckItem] {
        var assets = DeckScope.scopedAssets(includeScreenshots: includeScreenshots)
        if let since { assets = assets.filter { ($0.creationDate ?? .distantPast) >= since } }
        guard !assets.isEmpty else { return [] }

        var byID: [String: PHAsset] = [:]
        var dated: [(id: String, date: Date)] = []
        for asset in assets {
            byID[asset.localIdentifier] = asset
            dated.append((asset.localIdentifier, asset.creationDate ?? .distantPast))
        }

        let clusters = SessionClusterer.cluster(dated)
        let meta: [(sessionID: String, label: String, members: [String])] =
            clusters.enumerated().map { index, members in
                let date = members.first.flatMap { byID[$0]?.creationDate } ?? Date()
                return (sessionID: "s\(index)", label: SessionScope.label(for: date), members: members)
            }

        return order(clusters: meta, judged: store.judgedIdentifiers()).map {
            DeckItem(id: $0.id, asset: byID[$0.id],
                     sessionID: $0.sessionID, sessionLabel: $0.sessionLabel, syntheticIndex: nil)
        }
    }
}

// MARK: - Recording

/// The deck's write surface, abstracted so the model can run against the real
/// store OR an in-memory fake in the Simulator/tests. Every conformer routes undo
/// through a single stack so one swipe is exactly one undo.
@MainActor
protocol DeckRecorder: AnyObject {
    func record(_ verdict: Verdict, for item: DeckItem)
    @discardableResult func undoLast() -> Bool
    var canUndo: Bool { get }
    func verdict(for id: String) -> Verdict?
    /// Warm fingerprints for upcoming cards so their eventual commit is synchronous
    /// and off the gesture's critical path. No-op where identity isn't persisted.
    func prefetchFingerprints(for items: [DeckItem])
    /// Barrier — resolves once all queued writes have been applied. Used before
    /// recomputing the skip lap so no verdict is missed.
    func drain() async
}

/// Real recording over `JudgmentStore`. Fingerprints for upcoming cards are
/// precomputed during prefetch (`cache`), so a commit records synchronously and
/// stays off the gesture's critical path. Record and undo are both serialized
/// through one task `chain`, so a fast pass that outruns the cache still applies
/// writes — and their reverts — in exact gesture order; `logicalDepth` gives the
/// UI a synchronous, correct `canUndo`.
@MainActor
final class StoreDeckRecorder: DeckRecorder {
    private let store: JudgmentStore
    private var cache: [String: Fingerprint] = [:]
    private var inFlight: Set<String> = []
    private var chain: Task<Void, Never> = Task {}
    private var logicalDepth = 0

    init(store: JudgmentStore) { self.store = store }

    func prefetchFingerprints(for items: [DeckItem]) {
        for item in items {
            guard let asset = item.asset, cache[item.id] == nil, !inFlight.contains(item.id) else { continue }
            inFlight.insert(item.id)
            Task { @MainActor in
                let fp = await store.fingerprint(for: asset)
                cache[item.id] = fp
                inFlight.remove(item.id)
            }
        }
    }

    func record(_ verdict: Verdict, for item: DeckItem) {
        logicalDepth += 1
        let store = store
        let cached = cache[item.id]
        let previous = chain
        chain = Task { @MainActor in
            await previous.value
            let fp: Fingerprint?
            if let cached { fp = cached }
            else if let asset = item.asset { fp = await store.fingerprint(for: asset) }
            else { fp = nil }
            if let fp { store.record(verdict, for: item.id, fingerprint: fp) }
        }
    }

    func undoLast() -> Bool {
        guard logicalDepth > 0 else { return false }
        logicalDepth -= 1
        let store = store
        let previous = chain
        chain = Task { @MainActor in
            await previous.value
            store.undoLast()
        }
        return true
    }

    var canUndo: Bool { logicalDepth > 0 }
    func verdict(for id: String) -> Verdict? { store.judgment(for: id)?.verdict }
    func drain() async { await chain.value }
}

/// In-memory recording over the real `UndoStack`, so the deck's gesture surface
/// and undo are exercisable in the Simulator (which can't seed a PhotoKit deck)
/// and testable without a library. Uses the SAME `UndoStack` type as the store.
@MainActor
final class SyntheticDeckRecorder: DeckRecorder {
    private var verdicts: [String: Verdict] = [:]
    private let undo = UndoStack()

    func record(_ verdict: Verdict, for item: DeckItem) {
        let id = item.id
        let previous = verdicts[id]
        verdicts[id] = verdict
        undo.push({ [weak self] in self?.verdicts[id] = previous }, label: "verdict \(verdict.rawValue)")
    }

    func undoLast() -> Bool { undo.undo() }
    var canUndo: Bool { undo.canUndo }
    func verdict(for id: String) -> Verdict? { verdicts[id] }
    func prefetchFingerprints(for items: [DeckItem]) {}
    func drain() async {}
}
