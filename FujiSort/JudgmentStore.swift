//
//  JudgmentStore.swift
//  FujiSort — Milestone 02
//
//  The facade everything downstream reads and writes through. Core mutation
//  methods are PhotoKit-free (they take a Fingerprint) so the store is testable
//  without a library; PhotoKit convenience wrappers sit on top.
//

import Foundation
import SwiftData
import Photos

@MainActor
final class JudgmentStore {
    let context: ModelContext
    let undoStack = UndoStack()
    private let hasher: PerceptualHasher

    init(context: ModelContext, hasher: PerceptualHasher = PhotoKitHasher()) {
        self.context = context
        self.hasher = hasher
    }

    // MARK: - Retrieval

    func judgment(for identifier: String) -> Judgment? {
        var d = FetchDescriptor<Judgment>(predicate: #Predicate { $0.assetLocalIdentifier == identifier })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func allJudgments() -> [Judgment] {
        (try? context.fetch(FetchDescriptor<Judgment>())) ?? []
    }

    /// Judged = a record with a verdict recorded. Records can exist without a
    /// verdict (created-then-undone, dormant), so identity ≠ judged.
    func judgedIdentifiers() -> Set<String> {
        // In-memory filter rather than a #Predicate on a Codable enum, which
        // SwiftData cannot reliably translate to the backing store.
        Set(allJudgments().filter { $0.verdict != nil }.map { $0.assetLocalIdentifier })
    }

    func unjudged(scoped: [String]) -> [String] {
        Discovery.unjudged(scoped: scoped, judged: judgedIdentifiers())
    }

    // MARK: - Core mutations (PhotoKit-free, undoable)

    /// Records a verdict, creating the record (and its fingerprint) on first touch.
    /// The fingerprint is evaluated only on create — never recomputed or backfilled.
    @discardableResult
    func record(_ verdict: Verdict, for identifier: String,
                fingerprint: @autoclosure () -> Fingerprint, at date: Date = Date()) -> Judgment {
        let judgment: Judgment
        if let existing = self.judgment(for: identifier) {
            judgment = existing
        } else {
            judgment = Judgment(assetLocalIdentifier: identifier, fingerprint: fingerprint())
            context.insert(judgment)
        }
        let prevVerdict = judgment.verdict
        let prevAt = judgment.verdictRecordedAt
        judgment.verdict = verdict
        judgment.verdictRecordedAt = date
        save()
        undoStack.push({ [weak self] in
            guard let live = self?.judgment(for: identifier) else { return }
            live.verdict = prevVerdict
            live.verdictRecordedAt = prevAt
        }, label: "verdict \(verdict.rawValue)")
        return judgment
    }

    /// Moves a record between pass-2 tiers. Undoable, one action.
    func setTier(_ tier: Tier?, for identifier: String, at date: Date = Date()) {
        guard let judgment = self.judgment(for: identifier) else { return }
        let prevTier = judgment.tier
        let prevAt = judgment.tierRecordedAt
        judgment.tier = tier
        judgment.tierRecordedAt = date
        save()
        undoStack.push({ [weak self] in
            guard let live = self?.judgment(for: identifier) else { return }
            live.tier = prevTier
            live.tierRecordedAt = prevAt
        }, label: "tier \(tier?.rawValue ?? "none")")
    }

    /// A pass-2 review move as ONE undoable action. It may retier a candidate, or
    /// demote it out of the review (verdict → keep, tier cleared). Both fields are set
    /// and reverted together, so one gesture is exactly one undo — never two ops for a
    /// single move. Returns false, pushing nothing, when the target state equals the
    /// current one (e.g. assigning the tier already held).
    @discardableResult
    func setReviewState(verdict: Verdict?, tier: Tier?, for identifier: String, at date: Date = Date()) -> Bool {
        guard let judgment = self.judgment(for: identifier) else { return false }
        guard judgment.verdict != verdict || judgment.tier != tier else { return false }
        let prevVerdict = judgment.verdict
        let prevVerdictAt = judgment.verdictRecordedAt
        let prevTier = judgment.tier
        let prevTierAt = judgment.tierRecordedAt
        judgment.verdict = verdict
        judgment.verdictRecordedAt = date
        judgment.tier = tier
        judgment.tierRecordedAt = date
        save()
        undoStack.push({ [weak self] in
            guard let live = self?.judgment(for: identifier) else { return }
            live.verdict = prevVerdict
            live.verdictRecordedAt = prevVerdictAt
            live.tier = prevTier
            live.tierRecordedAt = prevTierAt
        }, label: "review move")
        return true
    }

    /// Reverts exactly one action, then persists. No redo.
    @discardableResult
    func undoLast() -> Bool {
        let reverted = undoStack.undo()
        if reverted { save() }
        return reverted
    }

    // MARK: - Reconciliation entry points (called by LibraryObserver)

    func handleDeleted(_ identifiers: Set<String>) {
        Reconciler.markDeletedDormant(deleted: identifiers, judgments: allJudgments())
        save()
    }

    func handleInserted(_ assets: [PHAsset]) async {
        let dormant = allJudgments().filter { $0.isDormant }
        guard !dormant.isEmpty else { return }
        var inserted: [(id: String, fp: Fingerprint)] = []
        for asset in assets { inserted.append((asset.localIdentifier, await fingerprint(for: asset))) }
        Reconciler.reactivateReadded(inserted: inserted, dormant: dormant)
        save()
    }

    // MARK: - PhotoKit convenience

    func fingerprint(for asset: PHAsset) async -> Fingerprint {
        let hash = await hasher.hash(for: asset) ?? 0
        return Fingerprint(creationDate: asset.creationDate,
                           pixelWidth: asset.pixelWidth,
                           pixelHeight: asset.pixelHeight,
                           hash: hash)
    }

    func record(_ verdict: Verdict, for asset: PHAsset, at date: Date = Date()) async {
        let fp = await fingerprint(for: asset)
        record(verdict, for: asset.localIdentifier, fingerprint: fp, at: date)
    }

    // MARK: -

    private func save() { try? context.save() }
}
