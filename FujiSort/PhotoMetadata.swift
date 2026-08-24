//
//  PhotoMetadata.swift
//  FujiSort — Milestone 05 (the HUD)
//
//  The HUD is OFF by default and deliberately spare: shutter, ISO, aperture, camera
//  model — the facets that survive a Fuji transfer. Focus point, film simulation,
//  and lens are NOT here: the spike measured all three absent from transferred
//  frames, so there are no placeholders for them (CLAUDE.md, interaction skill).
//
//  Clipping indication lives here too — a glanceable highlight overlay, the one HUD
//  addition the design blesses over a histogram (which must be *read*).
//

import Foundation
import Photos
import UIKit
import CoreImage
import ImageIO

/// The four HUD facets, pre-formatted for display. Any field may be absent.
struct PhotoMetadata: Equatable, Sendable {
    var shutter: String?      // "1/250 s"
    var iso: String?          // "ISO 400"
    var aperture: String?     // "f/2.8"
    var camera: String?       // "X-T4"

    var isEmpty: Bool { shutter == nil && iso == nil && aperture == nil && camera == nil }

    /// Read EXIF/TIFF from the asset's image data. The HUD is opt-in, so this is only
    /// called when the user turns it on — the whole-original fetch it implies (spike:
    /// nothing is on-device) never sits on the sort path.
    @MainActor
    static func load(for asset: PHAsset) async -> PhotoMetadata {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat      // any representation carries the EXIF
        options.isSynchronous = false

        let props: [CFString: Any]? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data,
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let dict = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: dict)
            }
        }
        return parse(props)
    }

    /// Split out so it unit-tests without PhotoKit.
    static func parse(_ props: [CFString: Any]?) -> PhotoMetadata {
        guard let props else { return PhotoMetadata() }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var m = PhotoMetadata()

        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            m.shutter = t < 1 ? "1/\(Int((1 / t).rounded())) s" : "\(trimmed(t)) s"
        }
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArray.first {
            m.iso = "ISO \(iso)"
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double, f > 0 {
            m.aperture = "f/\(trimmed(f))"
        }
        // Model alone reads cleanest ("X-T4", "iPhone 15 Pro"); Make survives too but
        // is redundant next to it.
        if let model = tiff?[kCGImagePropertyTIFFModel] as? String, !model.isEmpty {
            m.camera = model.trimmingCharacters(in: .whitespaces)
        }
        return m
    }

    private static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// Glanceable clipping indication. Renders a magenta highlight everywhere luminance
/// clips, once per loaded image (cached by the caller), so it costs nothing on the
/// gesture path. It marks *where* the frame blows out — it never scores the frame.
enum ClippingOverlay {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Luminance at/above this reads as clipped highlight.
    static let threshold: Float = 0.98

    private static let kernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 clip(__sample s, float threshold) {
        float l = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
        if (l >= threshold) { return vec4(0.85, 0.0, 0.85, 0.65); }
        return vec4(0.0, 0.0, 0.0, 0.0);
    }
    """)

    /// A transparent overlay the size of `image`, magenta where highlights clip.
    static func make(for image: UIImage) -> UIImage? {
        guard let kernel, let input = CIImage(image: image) else { return nil }
        guard let output = kernel.apply(extent: input.extent,
                                        arguments: [input, threshold]) else { return nil }
        guard let cg = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}
