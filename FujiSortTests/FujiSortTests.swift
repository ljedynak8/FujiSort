//
//  FujiSortTests.swift
//  FujiSortTests — Milestone 02
//
//  Store logic exercised on an in-memory SwiftData container with an injected
//  fake hasher, so no photo library is required.
//

import Testing
import Foundation
import SwiftData
import Photos
@testable import FujiSort

// MARK: - Helpers

private struct FakeHasher: PerceptualHasher {
    var value: UInt64 = 0
    func hash(for asset: PHAsset) async -> UInt64? { value }
}

@MainActor
private func makeStore() throws -> JudgmentStore {
    let schema = Schema([Judgment.self, CompareRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return JudgmentStore(context: ModelContext(container), hasher: FakeHasher())
}

private func fp(_ w: Int, _ h: Int, hash: UInt64 = 0, date: Date? = nil) -> Fingerprint {
    Fingerprint(creationDate: date, pixelWidth: w, pixelHeight: h, hash: hash)
}

// MARK: - Tests

@MainActor
struct JudgmentStoreTests {

    @Test func recordRetrieveUpdate() throws {
        let store = try makeStore()
        store.record(.keep, for: "A", fingerprint: fp(100, 200, hash: 0x1234))
        let created = try #require(store.judgment(for: "A"))
        #expect(created.verdict == .keep)
        #expect(created.fpPixelWidth == 100 && created.fpPixelHeight == 200)
        #expect(created.verdictRecordedAt != nil)

        // Update the verdict; the fingerprint must NOT be recomputed or backfilled.
        store.record(.reject, for: "A", fingerprint: fp(999, 999, hash: 0xFFFF))
        let updated = try #require(store.judgment(for: "A"))
        #expect(updated.verdict == .reject)
        #expect(updated.fpPixelWidth == 100 && updated.fingerprint.hash == 0x1234)
        #expect(store.allJudgments().count == 1)
    }

    @Test func unjudgedExcludesJudgedIncludesNew() throws {
        let store = try makeStore()
        let scoped = ["A", "B", "C"]
        #expect(store.unjudged(scoped: scoped) == ["A", "B", "C"])
        store.record(.keep, for: "A", fingerprint: fp(1, 1))
        store.record(.skip, for: "B", fingerprint: fp(1, 1))
        #expect(store.unjudged(scoped: scoped) == ["C"])
        // A brand-new asset D shows up in scope.
        #expect(store.unjudged(scoped: ["A", "B", "C", "D"]) == ["C", "D"])
    }

    @Test func externalDeleteLeavesRecordDormant() throws {
        let store = try makeStore()
        store.record(.candidate, for: "A", fingerprint: fp(1, 1))
        store.handleDeleted(["A"])
        let j = try #require(store.judgment(for: "A"))
        #expect(j.isDormant)
        #expect(j.dormantAt != nil)
        #expect(j.verdict == .candidate)          // judgment outlives the asset
        #expect(store.allJudgments().count == 1)  // not deleted
    }

    @Test func fingerprintRematchAfterIdentifierChange() throws {
        let store = try makeStore()
        store.record(.keep, for: "OLD", fingerprint: fp(3024, 4032, hash: 0xABCD_1234_5678_9AB0))
        store.handleDeleted(["OLD"])
        let dormant = store.allJudgments().filter { $0.isDormant }

        // Re-added under a new identifier: same dims/date, hash off by 2 bits;
        // plus a decoy with different dimensions that must not match.
        let inserted = [
            (id: "NEW", fp: fp(3024, 4032, hash: 0xABCD_1234_5678_9AB3)),
            (id: "DECOY", fp: fp(100, 100, hash: 0xABCD_1234_5678_9AB0)),
        ]
        let applied = Reconciler.reactivateReadded(inserted: inserted, dormant: dormant)
        #expect(applied.count == 1)
        #expect(applied.first?.newIdentifier == "NEW")
        #expect((applied.first?.confidence ?? 0) > 0.9)

        let reactivated = try #require(store.judgment(for: "NEW"))
        #expect(!reactivated.isDormant)
        #expect(reactivated.verdict == .keep)   // verdict carried across the id change
        #expect(store.judgment(for: "OLD") == nil)
    }

    @Test func undoRevertsExactlyOneActionToEmpty() throws {
        let store = try makeStore()
        store.record(.keep, for: "A", fingerprint: fp(1, 1))   // op 1: nil -> keep
        store.record(.reject, for: "A", fingerprint: fp(1, 1)) // op 2: keep -> reject
        store.setTier(.strong, for: "A")                       // op 3: nil -> strong
        #expect(store.undoStack.depth == 3)

        #expect(store.undoLast())
        #expect(store.judgment(for: "A")?.tier == nil)         // only the tier reverted
        #expect(store.judgment(for: "A")?.verdict == .reject)
        #expect(store.undoStack.depth == 2)

        #expect(store.undoLast())
        #expect(store.judgment(for: "A")?.verdict == .keep)    // exactly one verdict step
        #expect(store.undoStack.depth == 1)

        #expect(store.undoLast())
        #expect(store.judgment(for: "A")?.verdict == nil)
        #expect(store.undoStack.depth == 0)

        #expect(store.undoLast() == false)                     // empty, no redo
    }

    // MARK: - Session scoping (pure selection, decision 0003)

    @Test func currentSessionIsMostRecentClusterWithUnjudged() {
        // Two clusters, newest last. Nothing judged → newest cluster's members.
        let clusters = [["a1", "a2"], ["b1", "b2"]]
        #expect(SessionScope.selectCurrent(clusters: clusters, judged: []) == ["b1", "b2"])
    }

    @Test func currentSessionSkipsFullyJudgedRecentClusters() {
        // Newest cluster fully judged → fall back to the next most recent with work.
        let clusters = [["a1", "a2"], ["b1", "b2"]]
        let judged: Set<String> = ["b1", "b2"]
        #expect(SessionScope.selectCurrent(clusters: clusters, judged: judged) == ["a1", "a2"])
    }

    @Test func currentSessionReturnsOnlyUnjudgedMembers() {
        // Partially-judged recent cluster: keep its identity, show only the rest.
        let clusters = [["a1"], ["b1", "b2", "b3"]]
        let judged: Set<String> = ["b2"]
        #expect(SessionScope.selectCurrent(clusters: clusters, judged: judged) == ["b1", "b3"])
    }

    @Test func currentSessionNilWhenEverythingJudged() {
        let clusters = [["a1"], ["b1"]]
        #expect(SessionScope.selectCurrent(clusters: clusters, judged: ["a1", "b1"]) == nil)
    }

    @Test func sessionClusteringSplitsTwoOutingsFromOneTransfer() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400
        // Two outings a day apart, each two frames minutes apart. Arrival/import
        // order is irrelevant — clustering keys on capture time only.
        let items = [
            (id: "a1", date: base),
            (id: "a2", date: base.addingTimeInterval(120)),
            (id: "b1", date: base.addingTimeInterval(day)),
            (id: "b2", date: base.addingTimeInterval(day + 90)),
        ]
        let clusters = SessionClusterer.cluster(items)
        #expect(clusters.count == 2)
        #expect(clusters.first == ["a1", "a2"])
        #expect(clusters.last == ["b1", "b2"])
    }
}

// MARK: - Swipe decision (pure, milestone 04)

struct SwipeDecisionTests {
    private let t = SwipeThresholds.standard   // 90 pt / 800 pt·s⁻¹

    @Test func eachDirectionCommitsByDisplacement() {
        #expect(SwipeDecision.outcome(translation: CGSize(width: -120, height: 0), velocity: .zero, thresholds: t) == .verdict(.reject))
        #expect(SwipeDecision.outcome(translation: CGSize(width: 120, height: 0), velocity: .zero, thresholds: t) == .verdict(.keep))
        #expect(SwipeDecision.outcome(translation: CGSize(width: 0, height: -120), velocity: .zero, thresholds: t) == .verdict(.candidate))
        #expect(SwipeDecision.outcome(translation: CGSize(width: 0, height: 120), velocity: .zero, thresholds: t) == .verdict(.skip))
    }

    @Test func flickCommitsByVelocityWithLittleMovement() {
        // Below the displacement threshold, but a decisive flick.
        #expect(SwipeDecision.outcome(translation: CGSize(width: -10, height: 0), velocity: CGSize(width: -1000, height: 0), thresholds: t) == .verdict(.reject))
        #expect(SwipeDecision.outcome(translation: CGSize(width: 0, height: -8), velocity: CGSize(width: 0, height: -1200), thresholds: t) == .verdict(.candidate))
    }

    @Test func thresholdBoundaryCommits() {
        #expect(SwipeDecision.outcome(translation: CGSize(width: 90, height: 0), velocity: .zero, thresholds: t) == .verdict(.keep))
    }

    @Test func justBelowThresholdCancels() {
        #expect(SwipeDecision.outcome(translation: CGSize(width: 89, height: 0), velocity: .zero, thresholds: t) == .cancel)
    }

    @Test func belowBothDisplacementAndVelocityCancels() {
        #expect(SwipeDecision.outcome(translation: CGSize(width: 40, height: 12), velocity: CGSize(width: 200, height: 50), thresholds: t) == .cancel)
    }

    @Test func nearDiagonalResolvesToDominantAxis() {
        // Horizontal component dominates → keep, not candidate/skip.
        #expect(SwipeDecision.outcome(translation: CGSize(width: 120, height: 80), velocity: .zero, thresholds: t) == .verdict(.keep))
        // Vertical component dominates → skip.
        #expect(SwipeDecision.outcome(translation: CGSize(width: 40, height: 120), velocity: .zero, thresholds: t) == .verdict(.skip))
    }

    @Test func crossesCommitTracksThreshold() {
        #expect(SwipeDecision.crossesCommit(translation: CGSize(width: 89, height: 0), velocity: .zero, thresholds: t) == false)
        #expect(SwipeDecision.crossesCommit(translation: CGSize(width: 90, height: 0), velocity: .zero, thresholds: t))
    }
}

// MARK: - Deck ordering (pure, milestone 04)

struct DeckBuilderTests {
    @Test func newestOutingFirstAscendingWithinDropsJudged() {
        let clusters = [
            (sessionID: "s0", label: "old", members: ["a1", "a2"]),        // older outing
            (sessionID: "s1", label: "new", members: ["b1", "b2", "b3"]),  // newer outing
        ]
        let entries = DeckBuilder.order(clusters: clusters, judged: ["b2"])
        // Newer outing first, ascending within, b2 judged and dropped, outings contiguous.
        #expect(entries.map(\.id) == ["b1", "b3", "a1", "a2"])
        #expect(entries.map(\.sessionLabel) == ["new", "new", "old", "old"])
    }
}

// MARK: - Deck model: one swipe = one undo, laps, seam (milestone 04)

@MainActor
struct DeckModelTests {

    @Test func oneSwipeIsExactlyOneUndo() {
        let m = DeckModel.synthetic(count: 6)
        #expect(m.index == 0)
        #expect(m.canUndo == false)
        m.undo()                       // no-op on an empty stack
        #expect(m.index == 0)

        m.commit(.keep)
        m.commit(.reject)
        #expect(m.index == 2)
        #expect(m.canUndo)

        m.undo()
        #expect(m.index == 1)          // exactly one step back
        #expect(m.canUndo)

        m.undo()
        #expect(m.index == 0)
        #expect(m.canUndo == false)

        m.undo()                       // no redo, no underflow
        #expect(m.index == 0)
    }

    @Test func undoRevertsTheRecordedVerdict() {
        let m = DeckModel.synthetic(count: 4)
        m.commit(.skip)                // syn-0 skipped
        m.commit(.keep)                // syn-1 kept
        m.commit(.skip)                // syn-2 skipped
        #expect(Set(m.skippedIDs()) == ["syn-0", "syn-2"])
        m.undo()                       // reverts syn-2's skip in the store
        #expect(Set(m.skippedIDs()) == ["syn-0"])
    }

    @Test func skipLapIsRecomputedFromVerdictAndRebuildsDeck() {
        let m = DeckModel.synthetic(count: 4)
        m.commit(.skip); m.commit(.keep); m.commit(.skip); m.commit(.reject)
        #expect(Set(m.skippedIDs()) == ["syn-0", "syn-2"])
        m.beginSkipLap()
        #expect(m.deck.map(\.id) == ["syn-0", "syn-2"])   // original order preserved
        #expect(m.index == 0)
        #expect(m.canUndo == false)                        // fresh lap, clean undo
    }

    @Test func pillIsPerOutingAndRelabelsAtTheSeam() {
        let m = DeckModel.synthetic(count: 24)             // 12 + 12 across two outings
        #expect(m.pillLabel == "Saturday · 23 Aug 2026")
        #expect(m.pillCount == 12)
        for _ in 0..<12 { m.commit(.keep) }
        #expect(m.index == 12)
        #expect(m.pillLabel == "Friday · 22 Aug 2026")     // relabels at the seam
        #expect(m.pillCount == 12)                         // per-outing, not whole deck
        m.commit(.keep)
        #expect(m.pillCount == 11)
    }

    @Test func pinRecordsCandidateAndIsUndoneWholesale() {
        let m = DeckModel.synthetic(count: 3)
        m.pin()
        #expect(m.index == 1)
        #expect(m.pinned.contains("syn-0"))
        #expect(m.skippedIDs().isEmpty)                    // candidate, not skip
        m.undo()
        #expect(m.index == 0)
        #expect(m.pinned.contains("syn-0") == false)       // pin membership reverted too
    }
}
