/*
Author: wilbur
Version: 1.4
Date: 2026-06-25
Description: 基于 CGImageSource 的降采样缩略图加载服务；v1.3 按真实 JPG/RAW 文件选择缩略图源，RAW 使用内嵌预览优先并串行限流，避免 RAW-heavy 分组页缩略图解码阻塞显示；v1.4 缩略图缓存 key 加入实际来源路径、大小和修改时间
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

    private func thumbnailCacheKey(photo: photoItem, source: thumbnailSource, maxWidth: Int, maxHeight: Int) -> String {
        "\(photo.photoId)|thumb|\(source.path)|\(fileSignature(path: source.path))|\(maxWidth)x\(maxHeight)"
    }

    private func fileSignature(path: String) -> String {
        guard !path.isEmpty,
              let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)"
    }

    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        guard let source = resolveThumbnailSource(for: photo) else {
            return nil
        }

        let cacheKey = thumbnailCacheKey(photo: photo, source: source, maxWidth: maxWidth, maxHeight: maxHeight)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let maxPixelSize = max(maxWidth, maxHeight)
        let task = Task.detached(priority: .userInitiated) { [weak self, cacheKey] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }

            let image = self.decodeThumbnail(source: source, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return nil }

            if let image {
                self.cache.setObject(image, forKey: cacheKey as NSString)
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
