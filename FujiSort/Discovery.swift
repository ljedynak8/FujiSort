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
    static func fetchOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeAllBurstAssets = true      // finding 7: default drops burst frames
        o.predicate = NSPredicate(format: "(mediaSubtypes & %d) == 0",
                                  PHAssetMediaSubtype.photoScreenshot.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return o
    }

    /// Scoped identifiers in capture order. `sourceType` isn't predicate-able, so
    /// user-library filtering happens in the enumeration.
    static func scopedIdentifiers() -> [String] {
        let result = PHAsset.fetchAssets(with: .image, options: fetchOptions())
        var ids: [String] = []
        result.enumerateObjects { asset, _, _ in
            if asset.sourceType == .typeUserLibrary { ids.append(asset.localIdentifier) }
        }
        return ids
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
