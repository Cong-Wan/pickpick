# Image Service Split 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 photoImageService 拆分为 photoThumbnailService（降采样 NSImage）和 photoDisplayService（完整 CIImage），photoImageService 成为 Facade，对外 API 保持兼容

**Architecture:** 新建两个独立服务，各自管理自己的 NSCache；photoImageService 内部持有并分发到两个服务。缩略图使用 CGImageSourceCreateThumbnailAtIndex 实现真正的降采样加载，不再加载完整图。

**Tech Stack:** Swift, AppKit, CoreImage, ImageIO

**Depends on:** 无（可独立执行）

---

### Task 1: Create photoThumbnailService

**Goal:** 新建基于 CGImageSource 的降采样缩略图加载服务，返回 NSImage，内部 NSCache countLimit=200

**Files touched:**

- `rawViewer/photoThumbnailService.swift` — 缩略图加载服务（新建）

------

#### Step 1 — Implement

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: 基于 CGImageSource 的降采样缩略图加载服务，避免加载完整图像，缓存 NSImage 以隔离内存占用
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

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = self.decodeThumbnail(path: photo.jpgPath, maxPixelSize: max(maxWidth, maxHeight))
                if let image {
                    self.cache.setObject(image, forKey: cacheKey)
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
```

------

#### Step 2 — Verify compilation

将文件添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 2: Create photoDisplayService

**Goal:** 新建 JPG/RAW display 图加载服务，独立缓存 JPG(20) 和 RAW(10)，拒绝 >1GB RAW 文件

**Files touched:**

- `rawViewer/photoDisplayService.swift` — display 图加载服务（新建）

------

#### Step 1 — Implement

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: JPG/RAW display 图加载服务，独立缓存 JPG(20) 和 RAW(10)，拒绝超大 RAW 文件
*/

import AppKit
import CoreImage

public final class photoDisplayService {
    private let jpgCache = NSCache<NSString, photoCachedImage>()
    private let rawCache = NSCache<NSString, photoCachedImage>()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        jpgCache.countLimit = 20
        rawCache.countLimit = 10
    }

    public func loadDisplayJpg(for photo: photoItem) async -> photoImageResult {
        let key = "\(photo.photoId)|displayJpg" as NSString
        if let cached = jpgCache.object(forKey: key) {
            return .image(cached.image)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailable("Service deallocated"))
                    return
                }
                let result = self.loadJpg(photo: photo)
                if case .image(let image) = result {
                    self.jpgCache.setObject(photoCachedImage(image: image), forKey: key)
                }
                continuation.resume(returning: result)
            }
        }
    }

    public func loadDisplayRaw(for photo: photoItem) async -> photoImageResult {
        let key = "\(photo.photoId)|displayRaw" as NSString
        if let cached = rawCache.object(forKey: key) {
            return .image(cached.image)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailable("Service deallocated"))
                    return
                }
                let result = self.loadRaw(photo: photo)
                if case .image(let image) = result {
                    self.rawCache.setObject(photoCachedImage(image: image), forKey: key)
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func loadJpg(photo: photoItem) -> photoImageResult {
        guard fileManager.fileExists(atPath: photo.jpgPath) else {
            return .unavailable("Missing JPG")
        }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: photo.jpgPath)) else {
            return .unavailable("Cannot decode JPG")
        }
        return .image(image)
    }

    private func loadRaw(photo: photoItem) -> photoImageResult {
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else {
            return .unavailable("RAW missing")
        }
        guard fileManager.fileExists(atPath: rawPath) else {
            return .unavailable("Missing RAW")
        }
        if let attrs = try? fileManager.attributesOfItem(atPath: rawPath),
           let fileSize = attrs[.size] as? UInt64, fileSize > 1_000_000_000 {
            return .unavailable("RAW too large")
        }
        guard let filter = CIFilter(imageURL: URL(fileURLWithPath: rawPath), options: nil),
              let image = filter.outputImage else {
            return .unavailable("Cannot decode RAW")
        }
        return .image(image)
    }
}
```

------

#### Step 2 — Verify compilation

将文件添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 3: Refactor photoImageService as Facade

**Goal:** 将 photoImageService 改造为 Facade，内部创建并持有 thumbnailService 和 displayService；保留 `loadImage` / `preloadDisplayPair` 对外接口不变，新增 `loadThumbnail` 返回 NSImage

**Files touched:**

- `rawViewer/photoImageService.swift` — 改造为 Facade

------

#### Step 1 — Implement

```swift
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
```

------

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过，所有现有调用方（photoThumbnailView、groupCardView、photoBrowserViewController、duplicateCompareViewController）无需任何改动即可正常编译运行。
