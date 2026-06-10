/*
Author: wilbur
Version: 2.0
Date: 2026-06-06
Description: 图像加载 Facade，内部分发到 photoThumbnailService（降采样缩略图）和 photoDisplayService（完整显示图）；对外保持 loadImage/preloadDisplayPair 接口不变，新增 loadThumbnail 返回 NSImage
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

    /// 加载指定类型的图像（displayJpg/displayRaw 由 displayService 处理；thumbnail 向后兼容走 display + 缩放）
    public func loadImage(for photo: photoItem, kind: photoImageKind) async -> photoImageResult {
        switch kind {
        case .thumbnail(let width, let height):
            let result = await displayService.loadDisplayJpg(for: photo)
            guard case .image(let image) = result else { return result }
            return scaleToThumbnail(image: image, width: width, height: height)
        case .displayJpg:
            return await displayService.loadDisplayJpg(for: photo)
        case .displayRaw:
            return await displayService.loadDisplayRaw(for: photo)
        }
    }

    public func preloadDisplayPair(for photo: photoItem) async -> photoDisplayPair {
        async let jpgResult = displayService.loadDisplayJpg(for: photo)
        async let rawResult = displayService.loadDisplayRaw(for: photo)
        return await photoDisplayPair(photoId: photo.photoId, jpg: jpgResult, raw: rawResult)
    }

    private func scaleToThumbnail(image: CIImage, width: Int, height: Int) -> photoImageResult {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return .unavailable("Invalid JPG extent")
        }
        let safeWidth = max(1, CGFloat(width))
        let safeHeight = max(1, CGFloat(height))
        let scale = min(safeWidth / extent.width, safeHeight / extent.height)
        guard scale.isFinite, scale > 0 else {
            return .unavailable("Invalid thumbnail scale")
        }
        return .image(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
    }
}
