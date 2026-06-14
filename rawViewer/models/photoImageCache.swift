/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 图片种类枚举与缓存值包装；photoImageCacheKey/photoImageCache 已随服务拆分迁移至各子服务内部。v1.2 标注缓存包装可在后台图片任务中创建
*/

import AppKit
import CoreImage

nonisolated public enum photoImageKind: Hashable, Sendable {
    case thumbnail(width: Int, height: Int)
    case displayJpg
    case displayRaw
}

nonisolated public final class photoCachedImage: @unchecked Sendable {
    public let image: CIImage

    public init(image: CIImage) {
        self.image = image
    }
}

