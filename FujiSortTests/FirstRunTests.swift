//
//  FirstRunTests.swift
//  FujiSortTests — Milestone 08 (first-run experience)
//
//  The first-take selection core, exercised without a library (matching the pure
//  SessionScope/Discovery tests). Clusters arrive ascending capture order — oldest
//  first, newest last — the same shape SessionClusterer emits.
//

import Testing
import Foundation
@testable import FujiSort

@Suite("First-take selection")
struct FirstTakeSelectionTests {

    private func ids(_ prefix: String, _ n: Int) -> [String] { (0..<n).map { "\(prefix)\($0)" } }

    @Test("Picks the most recent cluster at or above the floor, not a stray newest pair")
    func floorSkipsTinyNewest() {
        let big = ids("b", 25)       // older, substantial
        let tiny = ids("t", 2)       // newest, below floor
        let result = FirstRun.selectFirstTake(clusters: [big, tiny], judged: [],
                                              minimum: 20, maximum: 120)
        #expect(result == .take(big))
    }

    @Test("Prefers the newest qualifying cluster when several clear the floor")
    func newestQualifyingWins() {
        let older = ids("o", 30)
        let newest = ids("n", 40)
        let result = FirstRun.selectFirstTake(clusters: [older, newest], judged: [],
                                              minimum: 20, maximum: 120)
        #expect(result == .take(newest))
    }

    @Test("Slices an enormous take to the first (earliest) maximum frames")
    func slicesEnormousTake() {
        let huge = ids("p", 400)
        let result = FirstRun.selectFirstTake(clusters: [huge], judged: [],
                                              minimum: 20, maximum: 120)
        guard case .take(let take) = result else { Issue.record("expected a take"); return }
        #expect(take.count == 120)
        #expect(take == Array(huge.prefix(120)))     // earliest, ascending
    }

    @Test("No cluster clears the floor → the honest scope question")
    func fallbackWhenNothingSubstantial() {
        let a = ids("a", 2), b = ids("b", 3), c = ids("c", 6)
        let result = FirstRun.selectFirstTake(clusters: [a, b, c], judged: [],
                                              minimum: 20, maximum: 120)
        #expect(result == .noSubstantialTake)
    }

    @Test("Judged members don't count toward the floor and are excluded from the take")
    func judgedSubtraction() {
        let older = ids("o", 20)                     // 20 unjudged, clears the floor
        let newest = ids("n", 25)                    // 25, but 8 judged → 17 remaining, below floor
        let judged = Set(newest.prefix(8))
        let result = FirstRun.selectFirstTake(clusters: [older, newest], judged: judged,
                                              minimum: 20, maximum: 120)
        #expect(result == .take(older))
    }

    @Test("Judged frames inside the chosen cluster are dropped from the take")
    func judgedDroppedFromTake() {
        let newest = ids("n", 25)
        let judged = Set(newest.prefix(3))           // 22 remain, still clears the floor
        let result = FirstRun.selectFirstTake(clusters: [newest], judged: judged,
                                              minimum: 20, maximum: 120)
        guard case .take(let take) = result else { Issue.record("expected a take"); return }
        #expect(take.count == 22)
        #expect(!take.contains("n0"))
        #expect(take == Array(newest.dropFirst(3)))
    }
}

@Suite("Scope choice windows")
struct ScopeChoiceTests {

    @Test("`since` produces the expected lower bounds")
    func sinceWindows() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // fixed reference

        #expect(ScopeChoice.today.since(now: now, calendar: cal) == cal.startOfDay(for: now))
        #expect(ScopeChoice.thisWeek.since(now: now, calendar: cal) == now.addingTimeInterval(-7 * 24 * 60 * 60))
        #expect(ScopeChoice.thisMonth.since(now: now, calendar: cal) == now.addingTimeInterval(-30 * 24 * 60 * 60))
        #expect(ScopeChoice.everything.since(now: now, calendar: cal) == nil)
    }
}
