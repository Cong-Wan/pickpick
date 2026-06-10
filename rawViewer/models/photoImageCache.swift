/*
Author: wilbur
Version: 1.1
Date: 2026-06-06
Description: 图片种类枚举与缓存值包装；photoImageCacheKey/photoImageCache 已随服务拆分迁移至各子服务内部
*/

import AppKit
import CoreImage

public enum photoImageKind: Hashable {
    case thumbnail(width: Int, height: Int)
    case displayJpg
    case displayRaw
}

public final class photoCachedImage {
    public let image: CIImage

    public init(image: CIImage) {
        self.image = image
    }
}

