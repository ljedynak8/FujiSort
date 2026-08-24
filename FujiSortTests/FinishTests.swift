//
//  FinishTests.swift
//  FujiSortTests — Milestone 07 (finish)
//
//  The pure, library-free surface of the finish milestone: which candidates project onto
//  which album. Membership is derived from tier exactly the way album sync will write it —
//  Portfolio = candidate + tier .portfolio; Strong = candidate + (tier .strong or none);
//  dormant and non-candidate records project nowhere. The PhotoKit reconcile/delete paths
//  need a real library and are verified on device (see the milestone write-back).
//

import Testing
import Foundation
import SwiftData
import Photos
@testable import FujiSort

@MainActor
private func makeStore() throws -> JudgmentStore {
    let schema = Schema([Judgment.self, CompareRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return JudgmentStore(context: ModelContext(container), hasher: Hasher0())
}

private struct Hasher0: PerceptualHasher {
    func hash(for asset: PHAsset) async -> UInt64? { 0 }
}

private func fp() -> Fingerprint { Fingerprint(creationDate: nil, pixelWidth: 1, pixelHeight: 1, hash: 0) }

@MainActor
struct AlbumSyncMembershipTests {

    @Test func candidatesSplitByTierWithNilDefaultingToStrong() throws {
        let store = try makeStore()
        // P → Portfolio; S → explicit Strong; N → candidate with no tier (⇒ Strong).
        store.record(.candidate, for: "P", fingerprint: fp())
        store.setReviewState(verdict: .candidate, tier: .portfolio, for: "P")
        store.record(.candidate, for: "S", fingerprint: fp())
        store.setReviewState(verdict: .candidate, tier: .strong, for: "S")
        store.record(.candidate, for: "N", fingerprint: fp())

        let desired = AlbumSync.desiredMembership(judgments: store.allJudgments())
        #expect(Set(desired.portfolio) == ["P"])
        #expect(Set(desired.strong) == ["S", "N"])
    }

    @Test func nonCandidatesAndDormantProjectNowhere() throws {
        let store = try makeStore()
        store.record(.keep, for: "K", fingerprint: fp())
        store.record(.reject, for: "R", fingerprint: fp())
        store.record(.skip, for: "SK", fingerprint: fp())
        // A candidate whose asset later disappeared — dormant, so it must not sync.
        store.record(.candidate, for: "D", fingerprint: fp())
        store.handleDeleted(["D"])

        let desired = AlbumSync.desiredMembership(judgments: store.allJudgments())
        #expect(desired.portfolio.isEmpty)
        #expect(desired.strong.isEmpty)
    }

    @Test func hasSyncableCandidatesReflectsLiveCandidates() throws {
        let store = try makeStore()
        #expect(!AlbumSync.hasSyncableCandidates(store: store))

        store.record(.candidate, for: "C", fingerprint: fp())
        #expect(AlbumSync.hasSyncableCandidates(store: store))

        // Demoting out of the review (back to Keep) removes the last candidate.
        store.setReviewState(verdict: .keep, tier: nil, for: "C")
        #expect(!AlbumSync.hasSyncableCandidates(store: store))
    }
}
