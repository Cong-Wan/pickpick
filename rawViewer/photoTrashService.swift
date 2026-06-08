/*
Author: wilbur
Version: 1.1
Date: 2026-06-08
Description: 照片废纸篓服务：将 photoItem 的 JPG/RAW 文件移入 macOS 废纸篓，支持批量清理已标记删除的照片
*/

import Foundation

public enum photoTrashError: Error {
    case trashFailed(path: String, underlying: Error)
}

public protocol photoTrashServicing {
    func trash(_ photo: photoItem) throws
    func cleanupTrashedPhotos(_ photos: [photoItem])
}

public final class photoTrashService: photoTrashServicing {
    public init() {}

    public func trash(_ photo: photoItem) throws {
        let paths = [photo.jpgPath, photo.rawPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let fm = FileManager.default
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                var resultUrl: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
            } catch {
                throw photoTrashError.trashFailed(path: path, underlying: error)
            }
        }
    }

    public func cleanupTrashedPhotos(_ photos: [photoItem]) {
        let fm = FileManager.default
        let trashedPhotos = photos.filter { $0.reviewStatus == .trashed }

        for photo in trashedPhotos {
            let paths = [photo.jpgPath, photo.rawPath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }

            for path in paths {
                guard fm.fileExists(atPath: path) else { continue }
                do {
                    var resultUrl: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
                } catch {
                    print("⚠️ cleanupTrashedPhotos: failed to trash \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}
