/*
Author: wilbur
Version: 1.3
Date: 2026-06-17
Description: 基于 CGImageSource 的降采样缩略图加载服务；v1.3 按真实 JPG/RAW 文件选择缩略图源，RAW 使用内嵌预览优先并串行限流，避免 RAW-heavy 分组页缩略图解码阻塞显示
*/

import AppKit
import ImageIO

nonisolated public final class photoThumbnailService: @unchecked Sendable {
    private enum thumbnailSource: Sendable {
        case jpg(path: String)
        case raw(path: String)

        var path: String {
            switch self {
            case .jpg(let path), .raw(let path):
                return path
            }
        }

        var isRaw: Bool {
            if case .raw = self { return true }
            return false
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let fileManager: FileManager
    private let rawDecodeQueue = DispatchQueue(label: "rawViewer.thumbnail.rawDecode")

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        cache.countLimit = 200
    }

    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = resolveThumbnailSource(for: photo) else {
            return nil
        }

        let photoId = photo.photoId
        let maxPixelSize = max(maxWidth, maxHeight)
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }

            let image = self.decodeThumbnail(source: source, maxPixelSize: maxPixelSize)
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

    private func resolveThumbnailSource(for photo: photoItem) -> thumbnailSource? {
        if photo.hasExistingJpgFile(fileManager: fileManager) {
            return .jpg(path: photo.jpgPath)
        }

        guard photo.hasExistingRawFile(fileManager: fileManager),
              let rawPath = photo.rawPath,
              !rawPath.isEmpty else {
            return nil
        }
        return .raw(path: rawPath)
    }

    private func decodeThumbnail(source: thumbnailSource, maxPixelSize: Int) -> NSImage? {
        if source.isRaw {
            return rawDecodeQueue.sync {
                guard !Task.isCancelled else { return nil }
                return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
            }
        }

        return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
    }

    private func decodeImageSourceThumbnail(path: String, source: thumbnailSource, maxPixelSize: Int) -> NSImage? {
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return nil
        }
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }

        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        if source.isRaw {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
