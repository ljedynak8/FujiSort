//
//  LibraryChangeReconciler.swift
//  FujiSort — Milestone 02 (change observation & reconciliation)
//
//  The reconciliation LOGIC is pure so it can be unit-tested without a library.
//  `LibraryObserver` is a thin PHPhotoLibraryChangeObserver adapter that feeds it
//  (that half needs a real device and is exercised in the app, not in tests).
//

import Foundation
import Photos

@MainActor
enum Reconciler {
    /// Asset deleted externally → mark the record dormant, never delete it.
    /// A judgment outlives a missing asset.
    static func markDeletedDormant(deleted: Set<String>, judgments: [Judgment], now: Date = Date()) {
        for j in judgments where deleted.contains(j.assetLocalIdentifier) && !j.isDormant {
            j.isDormant = true
            j.dormantAt = now
        }
    }

    /// Asset re-added → re-match a dormant record by fingerprint and reactivate it
    /// under the new identifier. Returns the applied matches (for logging/tests).
    @discardableResult
    static func reactivateReadded(inserted: [(id: String, fp: Fingerprint)],
                                  dormant: [Judgment]) -> [(judgment: Judgment, newIdentifier: String, confidence: Double)] {
        var applied: [(judgment: Judgment, newIdentifier: String, confidence: Double)] = []
        var claimed = Set<String>()
        for j in dormant where j.isDormant {
            let candidates = inserted.filter { !claimed.contains($0.id) }.map { ($0.id, $0.fp) }
            guard let match = FingerprintMatcher.rematch(orphan: j.fingerprint, candidates: candidates) else { continue }
            j.assetLocalIdentifier = match.id
            j.isDormant = false
            j.dormantAt = nil
            claimed.insert(match.id)
            applied.append((j, match.id, match.confidence))
        }
        return applied
    }

    // Asset edited elsewhere: the judgment STILL APPLIES (CLAUDE.md default). We do
    // not change the verdict; an edit does not un-make a decision about the photo.
    // No action required here beyond leaving the record intact.
}

/// Thin adapter: translates PhotoKit change notifications into `Reconciler` calls.
/// Registered at store construction. Device-only; not unit-tested.
@MainActor
final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private var fetchResult: PHFetchResult<PHAsset>
    private weak var store: JudgmentStore?

    init(store: JudgmentStore) {
        self.store = store
        self.fetchResult = PHAsset.fetchAssets(with: .image, options: DeckScope.fetchOptions())
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, let details = changeInstance.changeDetails(for: self.fetchResult) else { return }
            self.fetchResult = details.fetchResultAfterChanges
            let removed = Set(details.removedObjects.map { $0.localIdentifier })
            if !removed.isEmpty { self.store?.handleDeleted(removed) }
            let inserted = details.insertedObjects
            if !inserted.isEmpty { await self.store?.handleInserted(inserted) }
        }
    }

    func stop() { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}
