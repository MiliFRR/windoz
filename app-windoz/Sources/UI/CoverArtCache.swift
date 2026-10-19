// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md

import UIKit
import ImageIO

/// Decodes cover art off the main thread and keeps it in a bounded cache.
///
/// Idle-heat fix (Phase 1): the shelf used to call `UIImage(contentsOfFile:)`
/// inside `body`, so every re-render of the library or home screen re-read and
/// re-decoded every visible tile from disk on the main thread. Views now await
/// `image(at:)` and hold the result in their own `@State`; the decode runs on a
/// background queue and repeats only once per file version.
enum CoverArtCache {
    private static let cache = NSCache<NSString, UIImage>()
    private static let queue = DispatchQueue(label: "windoz.cover-art", qos: .userInitiated,
                                             attributes: .concurrent)

    /// The decoded image for `path`, downscaled so it is never larger than
    /// `maxPixel` on its longest edge. Nil when the file is missing or not an
    /// image.
    static func image(at path: String, maxPixel: CGFloat = 1024) async -> UIImage? {
        guard !path.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let key = cacheKey(path, maxPixel: maxPixel)
                if let cached = cache.object(forKey: key as NSString) {
                    continuation.resume(returning: cached)
                    return
                }
                let image = decode(path: path, maxPixel: maxPixel)
                if let image { cache.setObject(image, forKey: key as NSString) }
                continuation.resume(returning: image)
            }
        }
    }

    /// The key includes the file's modification date, so the art backfill
    /// replacing a file invalidates the entry without any bookkeeping.
    private static func cacheKey(_ path: String, maxPixel: CGFloat) -> String {
        var stamp = 0.0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date {
            stamp = modified.timeIntervalSince1970
        }
        return "\(path)#\(stamp)#\(Int(maxPixel))"
    }

    private static func decode(path: String, maxPixel: CGFloat) -> UIImage? {
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
        }
        // Not an image-source readable file; leave the last word to UIImage.
        return UIImage(contentsOfFile: path)
    }
}
