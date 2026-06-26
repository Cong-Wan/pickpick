/*
Author: wilbur
Version: 1.5
Date: 2026-06-25
Description: JPG/RAW display 图加载服务，独立缓存 JPG(20) 和 RAW(10)，加载前按文件类型校验，避免 RAW-only 照片被当作 JPG 显示。v1.3 使用可取消 detached task 收敛后台解码工作；v1.4 缓存 key 加入文件路径、大小和修改时间，避免跨文件夹同名照片串图；v1.5 display 加载增加尺寸与单边维度检查
*/

import AppKit
import CoreImage

nonisolated public final class photoDisplayService: @unchecked Sendable {
    private let jpgCache = NSCache<NSString, photoCachedImage>()
    private let rawCache = NSCache<NSString, photoCachedImage>()
    private let fileManager: FileManager
    private let maxDisplayJpgPixels = 100_000_000

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        jpgCache.countLimit = 20
        rawCache.countLimit = 10
    }

    private func displayCacheKey(photo: photoItem, source: displaySource) -> String {
        let path: String
        switch source {
        case .jpg:
            path = photo.jpgPath
        case .raw:
            path = photo.rawPath ?? ""
        }
        return "\(photo.photoId)|display|\(source.rawValue)|\(path)|\(fileSignature(path: path))"
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

    private func isDisplayExtentAllowed(_ extent: CGRect) -> Bool {
        let integralExtent = extent.integral
        guard integralExtent.width.isFinite, integralExtent.height.isFinite,
              integralExtent.width > 0, integralExtent.height > 0 else {
            return false
        }
        guard integralExtent.width <= 32_768, integralExtent.height <= 32_768 else {
            return false
        }
        return integralExtent.width * integralExtent.height <= CGFloat(maxDisplayJpgPixels)
    }

    public func loadDisplayJpg(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingJpgFile(fileManager: fileManager) else {
            return .unavailable("JPG missing")
        }

        let key = displayCacheKey(photo: photo, source: .jpg)
        if let cached = jpgCache.object(forKey: key as NSString) {
            return .image(cached.image)
        }

        let jpgPath = photo.jpgPath
        let task = Task.detached(priority: .userInitiated) { [weak self, key] () -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadJpg(jpgPath: jpgPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                self.jpgCache.setObject(photoCachedImage(image: image), forKey: key as NSString)
            }
            return result
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func loadDisplayRaw(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingRawFile(fileManager: fileManager) else {
            return .unavailable("RAW missing")
        }

        let key = displayCacheKey(photo: photo, source: .raw)
        if let cached = rawCache.object(forKey: key as NSString) {
            return .image(cached.image)
        }

        let rawPath = photo.rawPath
        let task = Task.detached(priority: .userInitiated) { [weak self, key] () -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadRaw(rawPath: rawPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                self.rawCache.setObject(photoCachedImage(image: image), forKey: key as NSString)
            }
            return result
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadJpg(jpgPath: String) -> photoImageResult {
        guard fileManager.fileExists(atPath: jpgPath) else {
            return .unavailable("Missing JPG")
        }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            return .unavailable("Cannot decode JPG")
        }
        guard isDisplayExtentAllowed(image.extent) else {
            return .unavailable("Invalid or too large JPG extent")
        }
        return .image(image)
    }

    private func loadRaw(rawPath: String?) -> photoImageResult {
        guard let rawPath, !rawPath.isEmpty else {
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
        guard isDisplayExtentAllowed(image.extent) else {
            return .unavailable("Invalid or too large RAW extent")
        }
        return .image(image)
    }
}
