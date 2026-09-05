//
//  FirstRun.swift
//  FujiSort — Milestone 08 (first-run experience)
//
//  The bounded first take, and the scope question that backs it up. Decision 0003:
//  a new user cannot answer a scope question ("today? a month? everything?") because
//  they don't yet know what sorting costs — so first run offers ONE recent take and
//  raises the backlog only afterwards.
//
//  Decision 0003 literally says "the most recent capture-date cluster", but taken
//  against the real library that is 2 photos (M03 measured the newest cluster at two).
//  Two photos yields ~0 candidates at an ~8% rate, so pass 2 never appears and the
//  first-run loop the design rests on is never completed. So: the most recent cluster
//  AT OR ABOVE a size floor, sliced if enormous. The floor and cap are empirical and
//  tunable — expected to move after real use.
//
//  The selection core is pure (PhotoKit-free) so it unit-tests without a library,
//  matching SessionScope / Discovery / Reconciler.
//

import Foundation
import Photos

enum FirstRun {

    /// Size floor for the first take. Below this it isn't a real outing. Measured
    /// recent clusters run 67, 66, 28, 13, 6, 4, 4, 3, 2, then many 1s — 20 clears the
    /// long tail of strays and lands on a genuine take. Tunable.
    nonisolated static let minimumTake = 20

    /// Cap for the first take. A first session that cannot be finished defeats the
    /// design as thoroughly as one that is trivial, so an enormous take is sliced to
    /// its first (earliest) frames. 120 lets the two large recent clusters through
    /// whole while slicing a wedding-sized take. Tunable — the softest of the two.
    nonisolated static let maximumTake = 120

    // MARK: - Pure core (testable without PhotoKit)

    enum FirstTakeSelection: Equatable {
        /// The chosen take, in ascending capture order, sliced to `maximum`.
        case take([String])
        /// Nothing recent and substantial — fall back to the honest scope question.
        case noSubstantialTake
    }

    /// From clusters in ascending capture order, pick the most recent (last) whose
    /// UNJUDGED members reach the floor, and return that take sliced to the first
    /// `maximum` (earliest, ascending). `noSubstantialTake` when none qualifies.
    nonisolated static func selectFirstTake(clusters: [[String]], judged: Set<String>,
                                            minimum: Int, maximum: Int) -> FirstTakeSelection {
        for cluster in clusters.reversed() {                     // newest outing first
            let remaining = cluster.filter { !judged.contains($0) }
            if remaining.count >= minimum {
                return .take(Array(remaining.prefix(maximum)))   // first slice, ascending
            }
        }
        return .noSubstantialTake
    }

    // MARK: - Device wrapper

    /// A named, bounded take to open first run on.
    struct FirstTake {
        let label: String
        let assets: [PHAsset]              // ascending capture order
        var count: Int { assets.count }
    }

    /// What first run should open with, resolved against the real library.
    enum Start {
        case take(FirstTake)      // step 2: straight into a recent take, named plainly
        case scopeQuestion        // no substantial take → ask the honest question
        case nothingToSort        // empty library / everything already judged
    }

    /// Clusters all scoped assets by capture date (same scope as the deck), then applies
    /// the size floor. Distinguishes "no substantial take" (ask the scope question) from
    /// "nothing to sort at all" (an empty or fully-judged library).
    @MainActor
    static func start(store: JudgmentStore, includeScreenshots: Bool = false,
                      minimum: Int = minimumTake, maximum: Int = maximumTake) -> Start {
        let assets = DeckScope.scopedAssets(includeScreenshots: includeScreenshots)
        guard !assets.isEmpty else { return .nothingToSort }

        var byID: [String: PHAsset] = [:]
        var dated: [(id: String, date: Date)] = []
        for asset in assets {
            byID[asset.localIdentifier] = asset
            dated.append((asset.localIdentifier, asset.creationDate ?? .distantPast))
        }

        let clusters = SessionClusterer.cluster(dated)
        let judged = store.judgedIdentifiers()
        let anyUnjudged = clusters.contains { $0.contains { !judged.contains($0) } }
        guard anyUnjudged else { return .nothingToSort }

        switch selectFirstTake(clusters: clusters, judged: judged, minimum: minimum, maximum: maximum) {
        case .noSubstantialTake:
            return .scopeQuestion
        case .take(let ids):
            let takeAssets = ids.compactMap { byID[$0] }
            let date = takeAssets.first?.creationDate ?? Date()
            return .take(FirstTake(label: SessionScope.label(for: date), assets: takeAssets))
        }
    }
}

// MARK: - Scope choice (the honest question — fallback + backlog)

/// The bounded ranges offered by the scope question. Used in two places: the
/// no-substantial-take fallback, and the backlog offer's "Choose a range". `since`
/// is a rolling window on `creationDate`; `everything` is the full deck.
enum ScopeChoice: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case thisMonth
    case everything

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today:      return "Today"
        case .thisWeek:   return "This week"
        case .thisMonth:  return "This month"
        case .everything: return "Everything"
        }
    }

    /// Lower bound on capture date, or nil for the whole library.
    nonisolated func since(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:      return calendar.startOfDay(for: now)
        case .thisWeek:   return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .thisMonth:  return now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .everything: return nil
        }
    }
}
