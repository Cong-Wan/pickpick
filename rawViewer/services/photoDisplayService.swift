/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: JPG/RAW display 图加载服务，独立缓存 JPG(20) 和 RAW(10)，加载前按文件类型校验，避免 RAW-only 照片被当作 JPG 显示
*/

import AppKit
import CoreImage

public final class photoDisplayService {
    private let jpgCache = NSCache<NSString, photoCachedImage>()
    private let rawCache = NSCache<NSString, photoCachedImage>()
    private let fileManager: FileManager
    private let maxDisplayJpgPixels = 100_000_000

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        jpgCache.countLimit = 20
        rawCache.countLimit = 10
    }

    public func loadDisplayJpg(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingJpgFile(fileManager: fileManager) else {
            return .unavailable("JPG missing")
        }

        let key = "\(photo.photoId)|displayJpg" as NSString
        if let cached = jpgCache.object(forKey: key) {
            return .image(cached.image)
        }

        let photoId = photo.photoId
        let jpgPath = photo.jpgPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailable("Service deallocated"))
                    return
                }
                let key = "\(photoId)|displayJpg" as NSString
                let result = self.loadJpg(jpgPath: jpgPath)
                if case .image(let image) = result {
                    self.jpgCache.setObject(photoCachedImage(image: image), forKey: key)
                }
                continuation.resume(returning: result)
            }
        }
    }

    public func loadDisplayRaw(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingRawFile(fileManager: fileManager) else {
            return .unavailable("RAW missing")
        }

        let key = "\(photo.photoId)|displayRaw" as NSString
        if let cached = rawCache.object(forKey: key) {
            return .image(cached.image)
        }

        let photoId = photo.photoId
        let rawPath = photo.rawPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .unavailable("Service deallocated"))
                    return
                }
                let key = "\(photoId)|displayRaw" as NSString
                let result = self.loadRaw(rawPath: rawPath)
                if case .image(let image) = result {
                    self.rawCache.setObject(photoCachedImage(image: image), forKey: key)
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func loadJpg(jpgPath: String) -> photoImageResult {
        guard fileManager.fileExists(atPath: jpgPath) else {
            return .unavailable("Missing JPG")
        }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            return .unavailable("Cannot decode JPG")
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return .unavailable("Invalid JPG extent")
        }
        let totalPixels = extent.width * extent.height
        guard totalPixels <= CGFloat(maxDisplayJpgPixels) else {
            return .unavailable("JPG too large")
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
        return .image(image)
    }
}
