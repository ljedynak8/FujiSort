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
