/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 提供照片缩略图异步加载缓存和分组卡片代表图片选择辅助逻辑
*/

import AppKit

public final class photoThumbnailCache {
    private var cache: [String: NSImage] = [:]

    public init() {}

    public func thumbnail(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        return image
    }
}

public func representativePhoto(for group: photoGroup) -> photoItem? {
    if case .duplicate = group.kind,
       let templateId = group.photos.first(where: { !$0.templatePhotoId.isEmpty })?.templatePhotoId,
       let template = group.photos.first(where: { $0.photoId == templateId }) {
        return template
    }
    return group.photos.first
}
