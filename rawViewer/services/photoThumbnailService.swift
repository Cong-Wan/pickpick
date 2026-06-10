/*
Author: wilbur
Version: 1.1
Date: 2026-06-06
Description: 基于 CGImageSource 的降采样缩略图加载服务，避免加载完整图像，缓存 NSImage 以隔离内存占用；闭包内重新生成 key 避免捕获非 Sendable NSString
*/

import AppKit
import ImageIO

public final class photoThumbnailService {
    private let cache = NSCache<NSString, NSImage>()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        cache.countLimit = 200
    }

    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let jpgPath = photo.jpgPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = self.decodeThumbnail(path: jpgPath, maxPixelSize: max(maxWidth, maxHeight))
                if let image {
                    let key = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
                    self.cache.setObject(image, forKey: key)
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func decodeThumbnail(path: String, maxPixelSize: Int) -> NSImage? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
