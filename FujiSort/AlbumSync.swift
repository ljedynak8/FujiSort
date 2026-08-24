//
//  AlbumSync.swift
//  FujiSort — Milestone 07 (finish)
//
//  One-way projection of the store's tiers onto two Photos albums. The store is the
//  truth; the album is a projection (fujisort-photokit). If they diverge — a photo the
//  user removed from the album in Photos, an album deleted — the next sync rewrites the
//  album to match the store. There is deliberately NO two-way reconciliation: a removal
//  in Photos is ambiguous and would silently lose a judgment.
//
//  Idempotent by construction: membership is reconciled to a target set (add the missing,
//  remove the extra), so running it twice produces identical membership, never duplicates.
//  All writes go in ONE performChanges block. Fires only from the ReviewModel.leave() seam
//  (via FinishCoordinator), never continuously as tiers change.
//

import Foundation
import Photos

@MainActor
enum AlbumSync {

    /// Flat namespaced titles (CLAUDE.md / fujisort-photokit). Isolated here so switching
    /// to a per-outing scheme for the Lightroom handoff is a single, contained change.
    enum Titles {
        static let portfolio = "FujiSort · Portfolio"
        static let strong    = "FujiSort · Strong"
    }

    // MARK: - Desired membership (pure — no PhotoKit, unit-tested directly)

    /// The two target id sets from the store. Portfolio = candidate + tier `.portfolio`.
    /// Strong = candidate + tier `.strong` OR no tier (candidates arrive in Strong). A
    /// dormant record's asset is gone from the library, so it is skipped.
    static func desiredMembership(judgments: [Judgment]) -> (portfolio: [String], strong: [String]) {
        var portfolio: [String] = []
        var strong: [String] = []
        for j in judgments where j.verdict == .candidate && !j.isDormant {
            if j.tier == .portfolio { portfolio.append(j.assetLocalIdentifier) }
            else { strong.append(j.assetLocalIdentifier) }      // .strong or nil ⇒ Strong
        }
        return (portfolio, strong)
    }

    /// Whether there is anything to sync at all — used to decide if the first-finish
    /// consent prompt is worth raising.
    static func hasSyncableCandidates(store: JudgmentStore) -> Bool {
        store.allJudgments().contains { $0.verdict == .candidate && !$0.isDormant }
    }

    // MARK: - The sync

    /// Reconcile both albums to the store, in one batched, idempotent change block.
    /// A no-op when album sync is disabled.
    static func run(store: JudgmentStore, preferences: AppPreferences) async {
        guard preferences.albumSyncEnabled else { return }

        let desired = desiredMembership(judgments: store.allJudgments())
        let portfolioAssets = assets(for: desired.portfolio)
        let strongAssets    = assets(for: desired.strong)
        let writeFavorites  = preferences.writeFavorites

        try? await PHPhotoLibrary.shared().performChanges {
            reconcile(title: Titles.portfolio, desired: portfolioAssets)
            reconcile(title: Titles.strong,    desired: strongAssets)

            if writeFavorites {
                // Additive only: set the heart, never clear one. Reading isFavorite avoids
                // a redundant write, and we never write `false`.
                for asset in portfolioAssets where !asset.isFavorite {
                    PHAssetChangeRequest(for: asset).isFavorite = true
                }
            }
        }
    }

    // MARK: - PhotoKit helpers

    /// Resolve identifiers to assets, preserving order and dropping any now-missing.
    private static func assets(for identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return identifiers.compactMap { byID[$0] }
    }

    /// Find-or-create the album and reconcile its membership to `desired`. MUST be called
    /// inside a `performChanges` block. Adding the missing and removing the extra is what
    /// makes a rerun a no-op and restores a photo the user removed in Photos.
    private static func reconcile(title: String, desired: [PHAsset]) {
        let desiredIDs = Set(desired.map(\.localIdentifier))

        if let album = fetchAlbum(title: title) {
            var current: [PHAsset] = []
            PHAsset.fetchAssets(in: album, options: nil)
                .enumerateObjects { asset, _, _ in current.append(asset) }
            let currentIDs = Set(current.map(\.localIdentifier))

            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            let toAdd    = desired.filter { !currentIDs.contains($0.localIdentifier) }
            let toRemove = current.filter { !desiredIDs.contains($0.localIdentifier) }
            if !toAdd.isEmpty    { request.addAssets(toAdd as NSArray) }
            if !toRemove.isEmpty { request.removeAssets(toRemove as NSArray) }
        } else {
            // Don't create an empty album just to hold nothing — only materialise a tier
            // once it has at least one member.
            guard !desired.isEmpty else { return }
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets(desired as NSArray)
        }
    }

    private static func fetchAlbum(title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", title)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }
}
