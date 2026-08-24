//
//  Discovery.swift
//  FujiSort — Milestone 02 (incremental discovery)
//
//  "What is unjudged" = the scoped fetch minus judged identifiers. The
//  always-correct path is pure and works with no change token at all. The
//  token-based incremental path is best-effort and falls back silently.
//

import Foundation
import Photos

enum Discovery {
    /// Always-correct: everything in scope that has not been judged. Pure.
    static func unjudged(scoped: [String], judged: Set<String>) -> [String] {
        scoped.filter { !judged.contains($0) }
    }
}

/// The camera-agnostic deck scope, per spike finding 7:
/// images · not screenshots · user library · **all burst frames**.
enum DeckScope {
    /// `includeScreenshots` defaults to false (the app default). A predicate change like
    /// this MUST be count-verified against the real library — the bitmask trap below is
    /// exactly why unit tests can't catch a regression here (fujisort-photokit).
    static func fetchOptions(includeScreenshots: Bool = false) -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeAllBurstAssets = true      // finding 7: default drops burst frames
        // Exclude screenshots (unless opted in). NOTE: PhotoKit mistranslates the
        // "bit-clear" forms `(mediaSubtypes & bit) == 0` and `(mediaSubtypes & bit) != bit`
        // — both collapse to "mediaSubtypes == 0" and wrongly drop every Live/HDR/pano/
        // depth asset (deck 9,593 → 5,127 on the real library, measured M03). Only the
        // negated bit-set form evaluates correctly.
        if !includeScreenshots {
            let screenshot = PHAssetMediaSubtype.photoScreenshot.rawValue
            o.predicate = NSPredicate(format: "NOT ((mediaSubtypes & %d) == %d)", screenshot, screenshot)
        }
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return o
    }

    /// Scoped identifiers in capture order. `sourceType` isn't predicate-able, so
    /// user-library filtering happens in the enumeration.
    static func scopedIdentifiers(includeScreenshots: Bool = false) -> [String] {
        scopedAssets(includeScreenshots: includeScreenshots).map(\.localIdentifier)
    }

    /// Scoped assets in capture order — same scope as `scopedIdentifiers()`, but
    /// carrying the `PHAsset`s (session scoping needs their `creationDate`, and the
    /// image pipeline needs the objects themselves). `sourceType` isn't
    /// predicate-able, so user-library filtering happens in the enumeration.
    static func scopedAssets(includeScreenshots: Bool = false) -> [PHAsset] {
        let result = PHAsset.fetchAssets(with: .image, options: fetchOptions(includeScreenshots: includeScreenshots))
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.sourceType == .typeUserLibrary { assets.append(asset) }
        }
        return assets
    }
}

/// Persists a persistent-change token across launches. Any failure is routine and
/// resolves to `nil`, which callers treat as "fall back to the always-correct path".
enum ChangeTokenStore {
    static let key = "milestone02.persistentChangeToken"

    static func save(_ token: PHPersistentChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> PHPersistentChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }
}
