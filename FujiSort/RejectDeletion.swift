//
//  RejectDeletion.swift
//  FujiSort — Milestone 07 (finish)
//
//  The only irreversible thing the app does. Rejects are MARKED during the pass and
//  deleted as ONE batch at the finish screen — one un-suppressible system confirmation
//  for the whole pile, never one per swipe (fujisort-photokit). Deleted photos go to
//  Recently Deleted for 30 days; that window is the recovery path and is stated in the UI.
//
//  Reconciliation is against REALITY, not the request: after the change block we re-fetch
//  the targets and treat whichever are gone as deleted. That handles a cancelled dialog
//  (nothing gone ⇒ nothing touched) and any partial outcome truthfully, without trusting
//  the requested set. Deleted records become dormant (milestone 02) — undo covers the
//  store, never the library, so a deleted photo's judgment is kept, not erased.
//

import Foundation
import Photos

@MainActor
enum RejectDeletion {

    struct Outcome { let deletedCount: Int; let cancelled: Bool }

    /// Assets marked Reject and still present in the library. Dormant records (asset
    /// already gone) are skipped.
    static func rejectAssets(store: JudgmentStore) -> [PHAsset] {
        let ids = store.allJudgments()
            .filter { $0.verdict == .reject && !$0.isDormant }
            .map(\.assetLocalIdentifier)
        guard !ids.isEmpty else { return [] }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Delete a batch. Raises the system confirmation, then reconciles against what the
    /// library actually shows afterwards.
    static func run(assets: [PHAsset], store: JudgmentStore) async -> Outcome {
        guard !assets.isEmpty else { return Outcome(deletedCount: 0, cancelled: false) }
        let requested = Set(assets.map(\.localIdentifier))

        var raised = true
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            // User cancelled the confirmation, or the write failed. Either way, fall
            // through to reconcile — the re-fetch below is the source of truth.
            raised = false
        }

        // What actually happened: any target no longer in the library was deleted.
        var stillPresent = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(requested), options: nil)
            .enumerateObjects { asset, _, _ in stillPresent.insert(asset.localIdentifier) }
        let deleted = requested.subtracting(stillPresent)

        // Mark the genuinely-deleted records dormant (keeps the record — milestone 02).
        if !deleted.isEmpty { store.handleDeleted(deleted) }

        return Outcome(deletedCount: deleted.count, cancelled: !raised && deleted.isEmpty)
    }
}
