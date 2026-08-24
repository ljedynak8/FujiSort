//
//  SessionScope.swift
//  FujiSort — Milestone 03 (session scoping)
//
//  "The current session" per decision 0003: the most recent capture-date cluster
//  that still contains unjudged photos. Sessions are labels, never queues — a
//  session names and groups; it never scopes the deck.
//
//  The selection logic is pure (PhotoKit-free) so it unit-tests without a library,
//  matching Discovery/Reconciler. The device wrapper feeds it real assets.
//

import Foundation
import Photos

enum SessionScope {

    /// A named group of unjudged photos to show. Tiny sessions are correct, not a
    /// bug: the spike saw 23 clusters in 30 days, sizes 67, 66, 28, 13, then mostly
    /// 1–4. A pill reading "Tuesday · 1" is right behaviour.
    struct Session {
        let label: String
        let date: Date
        let assets: [PHAsset]
        var count: Int { assets.count }
    }

    // MARK: - Pure core (testable without PhotoKit)

    /// From clusters in ascending capture order, pick the most recent (last) whose
    /// members include at least one unjudged id, and return just its unjudged
    /// members. `nil` when nothing is left to sort.
    static func selectCurrent(clusters: [[String]], judged: Set<String>) -> [String]? {
        for cluster in clusters.reversed() {
            let remaining = cluster.filter { !judged.contains($0) }
            if !remaining.isEmpty { return remaining }
        }
        return nil
    }

    // MARK: - Device wrapper

    /// Builds the current session from the real library. Clusters over **all**
    /// scoped assets (stable outing boundaries as judging progresses), then keeps
    /// the most recent cluster's unjudged members.
    @MainActor
    static func current(store: JudgmentStore) -> Session? {
        let assets = DeckScope.scopedAssets()
        guard !assets.isEmpty else { return nil }

        var byID: [String: PHAsset] = [:]
        var dated: [(id: String, date: Date)] = []
        for asset in assets {
            byID[asset.localIdentifier] = asset
            dated.append((asset.localIdentifier, asset.creationDate ?? .distantPast))
        }

        let clusters = SessionClusterer.cluster(dated)
        guard let ids = selectCurrent(clusters: clusters, judged: store.judgedIdentifiers()) else {
            return nil
        }

        let sessionAssets = ids.compactMap { byID[$0] }
        let date = sessionAssets.first?.creationDate ?? Date()
        return Session(label: label(for: date), date: date, assets: sessionAssets)
    }

    /// Human label from the cluster's capture date, e.g. "Saturday · 23 Aug 2026".
    static func label(for date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(weekday) · \(day)"
    }
}
