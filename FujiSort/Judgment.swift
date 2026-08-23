//
//  Judgment.swift
//  FujiSort — Milestone 02 (judgment store)
//
//  One record per asset. Keyed by localIdentifier, carrying a mandatory
//  fingerprint (set at creation, never backfilled) for post-restore re-matching.
//

import Foundation
import SwiftData

/// Pass-1 verdict. `nil` on a record means "no verdict recorded yet".
enum Verdict: String, Codable, CaseIterable, Sendable {
    case reject, keep, candidate, skip
}

/// Pass-2 tier. `nil` means "not tiered".
enum Tier: String, Codable, CaseIterable, Sendable {
    case portfolio, strong
}

@Model
final class Judgment {
    /// Primary key. Mutated only by fingerprint re-match after a restore/re-add.
    @Attribute(.unique) var assetLocalIdentifier: String

    // Fingerprint — computed and stored once, at creation. Cannot be backfilled.
    var fpCreationDate: Date?
    var fpPixelWidth: Int
    var fpPixelHeight: Int
    var fpHash: Int64            // dHash bit-pattern (UInt64 stored as Int64)

    var verdict: Verdict?
    var tier: Tier?

    var createdAt: Date
    var verdictRecordedAt: Date?
    var tierRecordedAt: Date?

    /// Set when the backing asset disappears from the library. A judgment
    /// outlives a missing asset; it is never deleted here.
    var isDormant: Bool
    var dormantAt: Date?

    init(assetLocalIdentifier: String, fingerprint: Fingerprint, createdAt: Date = Date()) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.fpCreationDate = fingerprint.creationDate
        self.fpPixelWidth = fingerprint.pixelWidth
        self.fpPixelHeight = fingerprint.pixelHeight
        self.fpHash = Int64(bitPattern: fingerprint.hash)
        self.createdAt = createdAt
        self.verdict = nil
        self.tier = nil
        self.isDormant = false
        self.dormantAt = nil
    }

    var fingerprint: Fingerprint {
        Fingerprint(creationDate: fpCreationDate,
                    pixelWidth: fpPixelWidth,
                    pixelHeight: fpPixelHeight,
                    hash: UInt64(bitPattern: fpHash))
    }
}

/// Minimal compare history. Standalone by design — nothing depends on it yet.
@Model
final class CompareRecord {
    var leftLocalIdentifier: String
    var rightLocalIdentifier: String
    var outcome: String
    var date: Date

    init(leftLocalIdentifier: String, rightLocalIdentifier: String, outcome: String, date: Date = Date()) {
        self.leftLocalIdentifier = leftLocalIdentifier
        self.rightLocalIdentifier = rightLocalIdentifier
        self.outcome = outcome
        self.date = date
    }
}
