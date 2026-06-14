/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 基于 CGImageSource 的降采样缩略图加载服务，避免加载完整图像，缓存 NSImage 以隔离内存占用。v1.2 使用可取消 detached task 收敛后台缩略图解码工作
*/

import AppKit
import ImageIO

nonisolated public final class photoThumbnailService: @unchecked Sendable {
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

        let photoId = photo.photoId
        let jpgPath = photo.jpgPath
        let maxPixelSize = max(maxWidth, maxHeight)
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }
            let image = self.decodeThumbnail(path: jpgPath, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return nil }
            if let image {
                let key = "\(photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
                self.cache.setObject(image, forKey: key)
            }
            return image
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
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
