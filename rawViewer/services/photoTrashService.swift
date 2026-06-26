/*
Author: wilbur
Version: 1.2
Date: 2026-06-25
Description: 照片废纸篓服务：将 photoItem 的 JPG/RAW 文件移入 macOS 废纸篓，支持批量清理已标记删除的照片；trash 改为对 jpg/raw 两文件尽力删除、收集失败路径最后统一抛错，避免删了 jpg、raw 因权限失败立刻 throw 导致半删状态
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
        var failedPaths: [String] = []
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                var resultUrl: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
            } catch {
                // 尽力删：记录失败路径，继续尝试同照片的其它文件，
                // 避免删了 jpg、raw 因权限失败就立刻 throw 把 jpg 留在半删状态。
                failedPaths.append(path)
                appFileLogger.log("trashItem failed path=\(path) error=\(error.localizedDescription)", level: .error)
            }
        }
        if !failedPaths.isEmpty {
            throw photoTrashError.trashFailed(
                path: failedPaths.joined(separator: ", "),
                underlying: NSError(
                    domain: "rawViewer.photoTrashService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to trash file(s): \(failedPaths.joined(separator: ", "))"]
                )
            )
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
                    appFileLogger.log("cleanupTrashedPhotos failed path=\(path) error=\(error.localizedDescription)", level: .error)
                }
            }
        }
    }
}
