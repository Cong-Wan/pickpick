/*
Author: wilbur
Version: 1.3
Date: 2026-06-25
Description: 图片缓存值包装；已删除零调用方的图片种类枚举，photoImageCacheKey/photoImageCache 已随服务拆分迁移至各子服务内部
*/

import AppKit
import CoreImage

nonisolated public final class photoCachedImage: @unchecked Sendable {
    public let image: CIImage

    public init(image: CIImage) {
        self.image = image
    }
}

