//
//  SessionClusterer.swift
//  FujiSort — Milestone 02 (session labelling)
//
//  A session is a DERIVED label for naming/grouping on screen. It never scopes a
//  queue and never holds state — this is a pure computed grouping over assets.
//

import Foundation

enum SessionClusterer {
    /// Gap between consecutive *capture* times that starts a new session.
    ///
    /// Chosen 4 hours: long enough that a single outing stays whole (intra-outing
    /// gaps are minutes), short enough to split a morning vs an evening outing and
    /// any two shoots on different days. Because it keys on capture time — which
    /// finding 5 confirmed is capture, not arrival — two outings imported in one
    /// transfer still split. Tune here.
    static let sessionGapThreshold: TimeInterval = 4 * 60 * 60

    /// Groups items into sessions by capture-date gaps, ascending. Items without a
    /// date sort to the front and cluster together.
    static func cluster(_ items: [(id: String, date: Date)],
                        gap: TimeInterval = sessionGapThreshold) -> [[String]] {
        let sorted = items.sorted { $0.date < $1.date }
        var clusters: [[String]] = []
        var current: [String] = []
        var previous: Date?
        for item in sorted {
            if let previous, item.date.timeIntervalSince(previous) > gap {
                clusters.append(current)
                current = []
            }
            current.append(item.id)
            previous = item.date
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }
}
