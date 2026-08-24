//
//  ImagePipeline.swift
//  FujiSort — Milestone 03 (library layer & image pipeline)
//
//  One loading layer over PHCachingImageManager. Shaped entirely by spike §1
//  (decision 0007): nothing in this library is on-device, so every full-res view
//  is a network round trip (median 402 ms on good wifi). Therefore:
//    • isNetworkAccessAllowed = true on every request — false returned nothing.
//    • deliveryMode = .opportunistic — a degraded frame shows immediately and is
//      replaced when the original lands. No path assumes a synchronous original.
//    • prefetch ahead / evict behind / cancel out-of-window, or 9,594 assets queue
//      thousands of downloads.
//

import Foundation
import Photos
import UIKit
import os

/// One progressive delivery from PhotoKit. `isDegraded` is true for the fast
/// low-quality frame, false for the final full-quality one.
struct ImageUpdate: Sendable {
    let image: UIImage
    let isDegraded: Bool
}

@MainActor
final class ImagePipeline {

    /// Thumbnail request size, in **pixels**. Milestone 06's review grid is a 3-up
    /// tile grid: on a ~390-pt iPhone that's ~130 pt/cell, ×3 scale ≈ 390 px. 400 px
    /// square covers that at native density with headroom, is reused verbatim for
    /// this milestone's list, and — squared with `.aspectFill` — needs no per-cell
    /// size math. At ~640 KB decoded a full 67-photo session of thumbs is ~43 MB.
    static let thumbnailTargetSize = CGSize(width: 400, height: 400)

    /// Items kept warm on each side of the visible range. ~40 cached 400 px thumbs
    /// ≈ 25 MB — deliberately at the spike's 25.3 MB line: big enough to absorb a
    /// fast fling inside a real session (max observed 67), small enough to bound
    /// memory. One edit to tune.
    static let prefetchWindow = 20

    private let manager = PHCachingImageManager()
    private let log = Logger(subsystem: "com.fianchetto.FujiSort", category: "pipeline")

    /// The window currently handed to PHCachingImageManager, so updates can diff.
    private var cachedAssets: [PHAsset] = []

    /// Options for caching must match the request options, or the cache won't hit.
    private var cachingOptions: PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        return o
    }

    init() {
        // Default is true, but state it — decision 0007 rests on network access.
        manager.allowsCachingHighQualityImages = false
    }

    // MARK: - Requests (progressive, cancellable, re-entrant)

    /// A thumbnail for list/grid tiles. Progressive: yields a fast degraded frame,
    /// then the sharp one. Cancelled automatically when the consuming task ends.
    func thumbnailStream(for asset: PHAsset) -> AsyncStream<ImageUpdate> {
        imageStream(for: asset, targetSize: Self.thumbnailTargetSize, contentMode: .aspectFill)
    }

    /// Full-resolution for full-screen viewing. Opportunistic: placeholder is the
    /// caller's business; this yields low-quality then original.
    func fullResolutionStream(for asset: PHAsset) -> AsyncStream<ImageUpdate> {
        imageStream(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit)
    }

    /// The one request path. `AsyncStream` gives progressive delivery *and*
    /// cancellation for free: when the consuming task is cancelled (view gone, id
    /// changed), `onTermination` fires and the PhotoKit request is cancelled —
    /// never left queued. Re-entrant: each call owns its own request id.
    private func imageStream(for asset: PHAsset,
                             targetSize: CGSize,
                             contentMode: PHImageContentMode) -> AsyncStream<ImageUpdate> {
        let mgr = manager
        let log = log
        let id = asset.localIdentifier
        return AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast

            let idBox = RequestIDBox()
            let start = DispatchTime.now()
            log.debug("request start \(id, privacy: .public)")

            let requestID = mgr.requestImage(for: asset,
                                             targetSize: targetSize,
                                             contentMode: contentMode,
                                             options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if let image {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    log.debug("deliver \(id, privacy: .public) degraded=\(degraded) at \(ms, format: .fixed(precision: 1)) ms")
                    continuation.yield(ImageUpdate(image: image, isDegraded: degraded))
                }
                if !degraded || cancelled || failed { continuation.finish() }
            }
            idBox.id = requestID

            continuation.onTermination = { reason in
                if case .cancelled = reason, let rid = idBox.id {
                    mgr.cancelImageRequest(rid)
                    log.debug("cancel \(id, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Windowed prefetch / evict

    /// Drive the caching window from the grid's visible range. Starts caching for
    /// the newly-entered slice and stops it for the slice that fell out — Apple's
    /// `AssetGridViewController` diffing pattern, so PhotoKit only ever holds one
    /// bounded window regardless of library size.
    func updateCache(allAssets: [PHAsset], visibleRange: Range<Int>) {
        guard !allAssets.isEmpty else { stopCachingAll(); return }
        let lower = max(0, visibleRange.lowerBound - Self.prefetchWindow)
        let upper = min(allAssets.count, visibleRange.upperBound + Self.prefetchWindow)
        guard lower < upper else { return }
        let target = Array(allAssets[lower..<upper])

        let targetIDs = Set(target.map(\.localIdentifier))
        let cachedIDs = Set(cachedAssets.map(\.localIdentifier))
        let toStart = target.filter { !cachedIDs.contains($0.localIdentifier) }
        let toStop = cachedAssets.filter { !targetIDs.contains($0.localIdentifier) }

        if !toStart.isEmpty {
            manager.startCachingImages(for: toStart, targetSize: Self.thumbnailTargetSize,
                                       contentMode: .aspectFill, options: cachingOptions)
        }
        if !toStop.isEmpty {
            manager.stopCachingImages(for: toStop, targetSize: Self.thumbnailTargetSize,
                                      contentMode: .aspectFill, options: cachingOptions)
        }
        if !toStart.isEmpty || !toStop.isEmpty {
            log.debug("cache window \(lower)..<\(upper): +\(toStart.count) -\(toStop.count)")
        }
        cachedAssets = target
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        cachedAssets = []
    }
}

/// Holds a PHImageRequestID across the request/termination boundary. Written on
/// the main actor, read from the (possibly off-main) termination handler.
private final class RequestIDBox: @unchecked Sendable {
    var id: PHImageRequestID?
}
