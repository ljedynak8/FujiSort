//
//  ReviewTests.swift
//  FujiSortTests — Milestone 06 (pass-2 review)
//
//  The pure surface of the review: the tier-transition table (including the asymmetry
//  the milestone calls out), the filter predicate and live counts, and the three sort
//  orderers. Plus the controller's move/undo/multi-select behaviour over the synthetic
//  recorder — all deterministic and library-free, since the Simulator can't seed a
//  PhotoKit candidate pool.
//

import Testing
import Foundation
import Photos
import SwiftData
@testable import FujiSort

// MARK: - Helpers

private func item(_ id: String, date: Date = Date(), hash: UInt64 = 0,
                  session: String = "s0", label: String = "L", index: Int? = nil) -> ReviewItem {
    ReviewItem(id: id, asset: nil, sessionID: session, sessionLabel: label,
               captureDate: date, hash: hash, syntheticIndex: index)
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

// MARK: - The transition table (checked against the vocabulary)

struct TierTransitionTests {

    @Test func strongPromotesToPortfolio() {
        #expect(TierTransition.apply(.promote, from: .strong) == .tier(.portfolio))
    }

    @Test func strongDemoteLeavesTheReview() {
        // Left from Strong returns the photo to Keep and removes it from the review.
        #expect(TierTransition.apply(.demote, from: .strong) == .removeFromReview)
    }

    @Test func portfolioDemotesToStrong() {
        #expect(TierTransition.apply(.demote, from: .portfolio) == .tier(.strong))
    }

    @Test func portfolioPromoteIsANoOp() {
        // The asymmetry: Portfolio is the top; right does nothing.
        #expect(TierTransition.apply(.promote, from: .portfolio) == .noChange)
    }

    @Test func actionsMapToOutcomes() {
        #expect(TierAction.portfolio.outcome == .tier(.portfolio))
        #expect(TierAction.strong.outcome == .tier(.strong))
        #expect(TierAction.out.outcome == .removeFromReview)
    }
}

// MARK: - Filtering & live counts

struct ReviewFilterTests {

    @Test func filterMatchesByPosition() {
        #expect(ReviewFilter.all.matches(position: .strong))
        #expect(ReviewFilter.all.matches(position: .portfolio))
        #expect(!ReviewFilter.all.matches(position: nil))          // out of review shows nowhere
        #expect(ReviewFilter.portfolio.matches(position: .portfolio))
        #expect(!ReviewFilter.portfolio.matches(position: .strong))
        #expect(ReviewFilter.strong.matches(position: .strong))
        #expect(!ReviewFilter.strong.matches(position: .portfolio))
    }

    @Test func countsReflectPositionsAndIgnoreRemoved() {
        let items = [item("a"), item("b"), item("c"), item("d")]
        let positions: [String: TierPosition?] = ["a": .portfolio, "b": .strong, "c": .strong, "d": nil]
        let counts = ReviewCounting.counts(items: items) { positions[$0] ?? nil }
        #expect(counts == ReviewCounts(all: 3, portfolio: 1, strong: 2))   // 'd' left the review
    }
}

// MARK: - The three sorts

struct ReviewOrderingTests {

    @Test func captureDateIsNewestFirst() {
        let items = [item("old", date: t(100)), item("new", date: t(300)), item("mid", date: t(200))]
        #expect(ReviewOrdering.byCaptureDate(items).map(\.id) == ["new", "mid", "old"])
    }

    @Test func outingIsNewestOutingFirstAscendingWithin() {
        // Outing A (older) has t=100,150; outing B (newer) has t=300,350.
        let items = [
            item("a1", date: t(150), session: "A"),
            item("a0", date: t(100), session: "A"),
            item("b1", date: t(350), session: "B"),
            item("b0", date: t(300), session: "B"),
        ]
        // Newest outing (B) first, ascending capture within each.
        #expect(ReviewOrdering.byOuting(items).map(\.id) == ["b0", "b1", "a0", "a1"])
    }

    @Test func similarityChainsNearDuplicatesAdjacent() {
        // Two duplicate pairs by hash; capture dates interleave them so only similarity
        // ordering can pull each pair together.
        let items = [
            item("p0", date: t(400), hash: 0x0000),
            item("q0", date: t(300), hash: 0xFFFF),
            item("p1", date: t(200), hash: 0x0000),
            item("q1", date: t(100), hash: 0xFFFF),
        ]
        let order = ReviewOrdering.bySimilarity(items).map(\.id)
        // Each pair adjacent: index distance 1.
        func pos(_ id: String) -> Int { order.firstIndex(of: id)! }
        #expect(abs(pos("p0") - pos("p1")) == 1)
        #expect(abs(pos("q0") - pos("q1")) == 1)
    }
}

// MARK: - Controller: moves, grouped undo, leaving

@MainActor
struct ReviewModelTests {

    private func makeModel(onLeave: @escaping () -> Void = {}) -> ReviewModel {
        let items = (0..<4).map { item("\($0)", date: t(TimeInterval(1000 - $0))) }
        let seed: [String: TierPosition] = ["0": .strong, "1": .strong, "2": .portfolio, "3": .strong]
        return ReviewModel(items: items, recorder: SyntheticReviewRecorder(seed: seed),
                           pipeline: nil, onLeave: onLeave)
    }

    @Test func swipePromotesStrongToPortfolioAndUndoes() {
        let m = makeModel()
        m.swipe(.promote, id: "0")
        #expect(m.position(for: "0") == .portfolio)
        #expect(m.counts == ReviewCounts(all: 4, portfolio: 2, strong: 2))
        #expect(m.canUndo)
        m.undo()
        #expect(m.position(for: "0") == .strong)
        #expect(!m.canUndo)
    }

    @Test func swipeLeftFromStrongLeavesTheReview() {
        let m = makeModel()
        m.swipe(.demote, id: "1")
        #expect(m.position(for: "1") == nil)                         // out of the review
        #expect(!m.visibleItems.contains { $0.id == "1" })           // vanished from All
        #expect(m.counts.all == 3)
        m.undo()
        #expect(m.position(for: "1") == .strong)
        #expect(m.counts.all == 4)
    }

    @Test func promotingFromPortfolioIsSilentNoOp() {
        let m = makeModel()
        m.swipe(.promote, id: "2")                                   // '2' is Portfolio
        #expect(m.position(for: "2") == .portfolio)
        #expect(!m.canUndo)                                          // nothing recorded
    }

    @Test func multiSelectAssignsAsOneGroupedUndo() {
        let m = makeModel()
        m.beginSelection(id: "0")
        m.toggleSelection(id: "1")
        #expect(m.selectionCount == 2)
        m.assign(.portfolio)
        #expect(m.position(for: "0") == .portfolio)
        #expect(m.position(for: "1") == .portfolio)
        #expect(!m.isSelecting)                                      // selection cleared
        #expect(m.canUndo)
        m.undo()                                                     // ONE undo reverts BOTH
        #expect(m.position(for: "0") == .strong)
        #expect(m.position(for: "1") == .strong)
        #expect(!m.canUndo)
    }

    @Test func assigningToTheHeldTierRecordsNothing() {
        let m = makeModel()
        m.beginSelection(id: "2")                                   // already Portfolio
        m.assign(.portfolio)
        #expect(!m.canUndo)
    }

    @Test func leaveFiresOnLeaveExactlyOnce() {
        var count = 0
        let m = makeModel(onLeave: { count += 1 })
        m.leave()
        m.leave()
        #expect(count == 1)
    }
}

// MARK: - Store: the atomic review-state write

@MainActor
struct SetReviewStateTests {

    private func makeStore() throws -> JudgmentStore {
        let schema = Schema([Judgment.self, CompareRecord.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return JudgmentStore(context: ModelContext(container), hasher: PassThroughHasher())
    }

    private struct PassThroughHasher: PerceptualHasher {
        func hash(for asset: PHAsset) async -> UInt64? { 0 }
    }

    private func fp() -> Fingerprint { Fingerprint(creationDate: nil, pixelWidth: 1, pixelHeight: 1, hash: 0) }

    @Test func retierAndRemoveAreEachOneUndo() throws {
        let store = try makeStore()
        store.record(.candidate, for: "A", fingerprint: fp())

        // Promote to Portfolio.
        #expect(store.setReviewState(verdict: .candidate, tier: .portfolio, for: "A"))
        #expect(store.judgment(for: "A")?.tier == .portfolio)

        // Demote out of the review: verdict → keep, tier cleared, in ONE op.
        #expect(store.setReviewState(verdict: .keep, tier: nil, for: "A"))
        #expect(store.judgment(for: "A")?.verdict == .keep)
        #expect(store.judgment(for: "A")?.tier == nil)

        // One undo restores BOTH fields to the candidate/portfolio state.
        store.undoLast()
        #expect(store.judgment(for: "A")?.verdict == .candidate)
        #expect(store.judgment(for: "A")?.tier == .portfolio)
    }

    @Test func settingTheCurrentStatePushesNothing() throws {
        let store = try makeStore()
        store.record(.candidate, for: "A", fingerprint: fp())
        // Candidate with nil tier already; asking for exactly that is a no-op.
        #expect(!store.setReviewState(verdict: .candidate, tier: nil, for: "A"))
    }
}
