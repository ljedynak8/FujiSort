//
//  Review.swift
//  FujiSort — Milestone 06 (pass-2 review)
//
//  The review's data spine: what a review tile is, the pure tier-transition function,
//  the filter/count and the three sort orderers, and the record surface abstracted so
//  the grid runs against the real store OR an in-memory fake (the Simulator can't seed
//  a PhotoKit deck). Everything here is PhotoKit-free and unit-tested directly — the
//  correctness the milestone flags (the asymmetry, the sorts) lives in these pure types.
//
//  Vocabulary is exact (CLAUDE.md, fujisort-interaction): two tiers, Portfolio and
//  Strong. Candidates arrive in Strong. From Strong: promote to Portfolio, or demote
//  OUT of the review (back to Keep). From Portfolio: demote to Strong. No third tier,
//  no cap, no automatic duel.
//

import Foundation
import Photos

// MARK: - Review tile

/// One tile in the pass-2 grid. `asset` is nil for a synthetic debug tile. Carries the
/// stored dHash so visual-similarity ordering is free — the fingerprint is written at
/// record creation (milestone 02) and never needs recomputing here.
struct ReviewItem: Identifiable, Equatable {
    let id: String
    let asset: PHAsset?
    let sessionID: String
    let sessionLabel: String
    let captureDate: Date
    let hash: UInt64
    let syntheticIndex: Int?

    static func == (lhs: ReviewItem, rhs: ReviewItem) -> Bool { lhs.id == rhs.id }

    /// Bridge to the deck's item type so `AnalysisModel`/`AnalysisView` are reused
    /// verbatim — analysis is analysis whether reached from the deck or the review.
    var deckItem: DeckItem {
        DeckItem(id: id, asset: asset, sessionID: sessionID,
                 sessionLabel: sessionLabel, syntheticIndex: syntheticIndex)
    }
}

// MARK: - Tier position, moves, and the transition

/// Where a photo currently sits in the review. A candidate with no tier defaults to
/// Strong (candidates arrive in Strong), so `nil`-tier ⇒ `.strong` at the read boundary.
enum TierPosition: Equatable { case strong, portfolio }

/// A directional nudge from a tile swipe. Right promotes, left demotes.
enum TierMove: Equatable { case promote, demote }

/// An absolute destination named by a button — the analysis strip and the multi-select
/// bottom bar. `out` demotes a photo out of the review (back to Keep).
enum TierAction: Equatable {
    case portfolio, strong, out

    var outcome: TierOutcome {
        switch self {
        case .portfolio: return .tier(.portfolio)
        case .strong:    return .tier(.strong)
        case .out:       return .removeFromReview
        }
    }
}

/// The result of a move, applied by the recorder as ONE undoable action. `noChange`
/// pushes nothing (e.g. promoting from Portfolio, or assigning the tier already held).
enum TierOutcome: Equatable {
    case tier(Tier)          // stays a candidate, retiered
    case removeFromReview    // verdict → keep, tier cleared; leaves the review
    case noChange
}

/// The core the milestone asks to be checked against the vocabulary. Pure and total.
enum TierTransition {
    static func apply(_ move: TierMove, from position: TierPosition) -> TierOutcome {
        switch (position, move) {
        case (.strong, .promote):    return .tier(.portfolio)   // Strong → Portfolio
        case (.strong, .demote):     return .removeFromReview   // Strong → out (back to Keep)
        case (.portfolio, .demote):  return .tier(.strong)      // Portfolio → Strong
        case (.portfolio, .promote): return .noChange           // Portfolio is the top
        }
    }
}

// MARK: - Filtering & counts

/// The three filter chips. Membership and counts are computed live from the recorder's
/// current positions, never cached, so a demote-out vanishes from a lane immediately.
enum ReviewFilter: CaseIterable, Equatable { case all, portfolio, strong

    /// Whether an item at `position` (nil = out of the review) shows under this filter.
    func matches(position: TierPosition?) -> Bool {
        guard let position else { return false }   // out of the review shows nowhere
        switch self {
        case .all:       return true
        case .portfolio: return position == .portfolio
        case .strong:    return position == .strong
        }
    }
}

struct ReviewCounts: Equatable { let all: Int; let portfolio: Int; let strong: Int }

enum ReviewCounting {
    /// Live counts for the chips. `position` maps an id to its current position, or nil
    /// when the photo has left the review.
    static func counts(items: [ReviewItem], position: (String) -> TierPosition?) -> ReviewCounts {
        var all = 0, portfolio = 0, strong = 0
        for item in items {
            switch position(item.id) {
            case .portfolio: all += 1; portfolio += 1
            case .strong:    all += 1; strong += 1
            case nil:        break
            }
        }
        return ReviewCounts(all: all, portfolio: portfolio, strong: strong)
    }
}

// MARK: - Sorting

/// The three sort options. Ordering and grouping only — none of these scores a
/// photograph for quality or hides anything (the automation boundary).
enum ReviewSort: CaseIterable, Equatable { case captureDate, outing, similarity

    var label: String {
        switch self {
        case .captureDate: return "Capture date"
        case .outing:      return "Outing"
        case .similarity:  return "Similarity"
        }
    }

    func order(_ items: [ReviewItem]) -> [ReviewItem] {
        switch self {
        case .captureDate: return ReviewOrdering.byCaptureDate(items)
        case .outing:      return ReviewOrdering.byOuting(items)
        case .similarity:  return ReviewOrdering.bySimilarity(items)
        }
    }
}

enum ReviewOrdering {

    /// Newest first — the default. Stable id tiebreak so equal dates never reshuffle.
    static func byCaptureDate(_ items: [ReviewItem]) -> [ReviewItem] {
        items.sorted { a, b in
            a.captureDate != b.captureDate ? a.captureDate > b.captureDate : a.id < b.id
        }
    }

    /// Newest outing first, ascending capture within — the deck's rule, applied to the
    /// candidate pool. Groups by sessionID; a group's recency is its latest capture.
    static func byOuting(_ items: [ReviewItem]) -> [ReviewItem] {
        let groups = Dictionary(grouping: items, by: \.sessionID)
        let orderedGroups = groups.values.sorted { a, b in
            let ra = a.map(\.captureDate).max() ?? .distantPast
            let rb = b.map(\.captureDate).max() ?? .distantPast
            if ra != rb { return ra > rb }                          // newest outing first
            return (a.first?.sessionID ?? "") < (b.first?.sessionID ?? "")
        }
        return orderedGroups.flatMap { group in
            group.sorted { $0.captureDate != $1.captureDate ? $0.captureDate < $1.captureDate : $0.id < $1.id }
        }
    }

    /// Visual-similarity ordering: a greedy nearest-neighbour chain over the stored
    /// dHash (Hamming distance, via the milestone-02 matcher), started from the newest
    /// photo. Likely duplicates land adjacent. This is grouping, explicitly allowed —
    /// it never ranks by merit and never removes a frame.
    static func bySimilarity(_ items: [ReviewItem]) -> [ReviewItem] {
        guard items.count > 2 else { return byCaptureDate(items) }
        var remaining = byCaptureDate(items)                        // deterministic start
        var chain: [ReviewItem] = [remaining.removeFirst()]
        while !remaining.isEmpty {
            let last = chain[chain.count - 1].hash
            var bestIdx = 0
            var bestDist = Int.max
            for (i, candidate) in remaining.enumerated() {
                let d = FingerprintMatcher.hamming(last, candidate.hash)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            chain.append(remaining.remove(at: bestIdx))
        }
        return chain
    }
}

// MARK: - Recording surface

/// The review's write surface, abstracted like `DeckRecorder` so the model drives the
/// real store OR an in-memory fake. `position(for:)` is the single source of truth for
/// which lane a tile is in and whether it is still in the review at all.
@MainActor
protocol ReviewRecorder: AnyObject {
    /// Current lane, or nil when the photo has left the review (verdict no longer a
    /// candidate). Candidates with no explicit tier read as `.strong`.
    func position(for id: String) -> TierPosition?

    /// Apply a move as one undoable action. Returns false — pushing nothing — when the
    /// outcome is `.noChange` or would set the state already held.
    @discardableResult
    func apply(_ outcome: TierOutcome, for id: String) -> Bool

    @discardableResult
    func undoLast() -> Bool
    var canUndo: Bool { get }
}

/// Real recording over `JudgmentStore`. Reads position from the live `Judgment`; writes
/// verdict+tier atomically through `setReviewState`, so each move is exactly one undo op.
@MainActor
final class StoreReviewRecorder: ReviewRecorder {
    private let store: JudgmentStore
    init(store: JudgmentStore) { self.store = store }

    func position(for id: String) -> TierPosition? {
        guard let j = store.judgment(for: id), j.verdict == .candidate else { return nil }
        return j.tier == .portfolio ? .portfolio : .strong      // candidate defaults to Strong
    }

    @discardableResult
    func apply(_ outcome: TierOutcome, for id: String) -> Bool {
        switch outcome {
        case .tier(let t):        return store.setReviewState(verdict: .candidate, tier: t, for: id)
        case .removeFromReview:   return store.setReviewState(verdict: .keep, tier: nil, for: id)
        case .noChange:           return false
        }
    }

    @discardableResult
    func undoLast() -> Bool { store.undoLast() }
    var canUndo: Bool { store.undoStack.canUndo }
}

/// In-memory recording over the SAME `UndoStack` type as the store, so the grid's moves
/// and undo are driveable in the Simulator and testable without a library.
@MainActor
final class SyntheticReviewRecorder: ReviewRecorder {
    private var positions: [String: TierPosition] = [:]     // absent ⇒ out of the review
    private let undo = UndoStack()

    init(seed: [String: TierPosition]) { positions = seed }

    func position(for id: String) -> TierPosition? { positions[id] }

    @discardableResult
    func apply(_ outcome: TierOutcome, for id: String) -> Bool {
        let previous = positions[id]
        let next: TierPosition?
        switch outcome {
        case .tier(let t):      next = (t == .portfolio) ? .portfolio : .strong
        case .removeFromReview: next = nil
        case .noChange:         return false
        }
        guard next != previous else { return false }
        positions[id] = next
        undo.push({ [weak self] in self?.positions[id] = previous }, label: "review move")
        return true
    }

    @discardableResult
    func undoLast() -> Bool { undo.undo() }
    var canUndo: Bool { undo.canUndo }
}
