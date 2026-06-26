/*
Author: wilbur
Version: 2.1
Date: 2026-06-25
Description: 图像加载 Facade，内部分发到 photoThumbnailService（降采样缩略图）和 photoDisplayService（完整显示图）；已删除零调用方的旧图片加载入口与缩略图缩放辅助，对外保留 loadThumbnail 与 preloadDisplayPair
*/

import AppKit
import CoreImage

public enum photoImageResult: Equatable {
    case image(CIImage)
    case unavailable(String)

    public static func == (lhs: photoImageResult, rhs: photoImageResult) -> Bool {
        switch (lhs, rhs) {
        case (.image, .image):
            return true
        case (.unavailable(let lMessage), .unavailable(let rMessage)):
            return lMessage == rMessage
        default:
            return false
        }
    }
}

public struct photoDisplayPair: Equatable {
    public let photoId: String
    public let jpg: photoImageResult
    public let raw: photoImageResult

    public init(photoId: String, jpg: photoImageResult, raw: photoImageResult) {
        self.photoId = photoId
        self.jpg = jpg
        self.raw = raw
    }
}

public final class photoImageService {
    private let thumbnailService: photoThumbnailService
    private let displayService: photoDisplayService

    public init(
        thumbnailService: photoThumbnailService? = nil,
        displayService: photoDisplayService? = nil
    ) {
        self.thumbnailService = thumbnailService ?? photoThumbnailService()
        self.displayService = displayService ?? photoDisplayService()
    }

    /// 加载降采样缩略图，返回 NSImage（内部使用 CGImageSource，不加载完整图）
    public func loadThumbnail(for photo: photoItem, maxWidth: Int = 150, maxHeight: Int = 56) async -> NSImage? {
        await thumbnailService.loadThumbnail(for: photo, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    public func preloadDisplayPair(for photo: photoItem) async -> photoDisplayPair {
        async let jpgResult = displayService.loadDisplayJpg(for: photo)
        async let rawResult = displayService.loadDisplayRaw(for: photo)
        return await photoDisplayPair(photoId: photo.photoId, jpg: jpgResult, raw: rawResult)
    }
}
