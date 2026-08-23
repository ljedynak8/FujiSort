//
//  Fingerprinting.swift
//  FujiSort — Milestone 02 (asset identity)
//
//  The fallback fingerprint and the re-match path. Built now because finding 2
//  (does localIdentifier survive a restore?) is UNRESOLVED in the spike, and the
//  fingerprint cannot be backfilled onto records created without it.
//

import Foundation
import Photos
import UIKit
import ImageIO

struct Fingerprint: Equatable, Sendable {
    var creationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var hash: UInt64
}

// MARK: - Perceptual hashing (the one place identity touches pixels)

/// Injected so the store stays testable without a photo library. The real
/// implementation requests a small *thumbnail* (local even when the original is
/// in iCloud — dodges finding 1's download cost), not the full-res image pipeline.
protocol PerceptualHasher: Sendable {
    func hash(for asset: PHAsset) async -> UInt64?
}

struct PhotoKitHasher: PerceptualHasher {
    func hash(for asset: PHAsset) async -> UInt64? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        let image: UIImage? = await withCheckedContinuation { cont in
            let once = OnceBox()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 32, height: 32),
                contentMode: .aspectFit,
                options: options
            ) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                once.fire { cont.resume(returning: img) }
            }
        }
        guard let cg = image?.cgImage else { return nil }
        return Self.dHash(cg)
    }

    /// 64-bit difference hash from a 9×8 grayscale downscale.
    static func dHash(_ cg: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        var idx = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if pixels[row * w + col] > pixels[row * w + col + 1] { bits |= (1 << UInt64(idx)) }
                idx += 1
            }
        }
        return bits
    }
}

/// One-shot guard so a stray second PhotoKit callback can't double-resume.
final class OnceBox: @unchecked Sendable {
    private var fired = false
    func fire(_ body: () -> Void) { if !fired { fired = true; body() } }
}

// MARK: - Re-match

enum FingerprintMatcher {
    /// creationDate should be byte-identical across a restore; allow a hair for rounding.
    static let dateTolerance: TimeInterval = 2
    /// Minimum confidence to accept a re-match (Hamming distance ≤ ~12 bits of 64).
    static let minConfidence: Double = 0.80

    /// Find the candidate whose fingerprint best matches an orphaned record.
    /// Requires exact pixel dimensions and agreeing creation dates; ranks by
    /// Hamming distance on the perceptual hash. Returns match + confidence [0,1].
    static func rematch(orphan: Fingerprint,
                        candidates: [(id: String, fp: Fingerprint)]) -> (id: String, confidence: Double)? {
        var best: (id: String, confidence: Double)?
        for c in candidates {
            guard c.fp.pixelWidth == orphan.pixelWidth,
                  c.fp.pixelHeight == orphan.pixelHeight else { continue }
            switch (orphan.creationDate, c.fp.creationDate) {
            case let (a?, b?):
                guard abs(a.timeIntervalSince(b)) <= dateTolerance else { continue }
            case (nil, nil):
                break
            default:
                continue    // one has a date, the other doesn't
            }
            let confidence = 1.0 - Double(hamming(orphan.hash, c.fp.hash)) / 64.0
            if confidence >= minConfidence, best == nil || confidence > best!.confidence {
                best = (c.id, confidence)
            }
        }
        return best
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
