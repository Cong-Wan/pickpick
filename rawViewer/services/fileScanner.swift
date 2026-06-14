/*
Author: wilbur
Version: 1.1
Date: 2026-06-13
Description: 顶层目录扫描, 按 stem 配对 JPG (jpg/jpeg) 和 RAW (rw2/cr2)。v1.1 明确扫描结果和扫描器可在后台分析任务中使用
*/

import Foundation

nonisolated public struct photoFilePair: Sendable {
    public let photoId: String
    public let jpgPath: String?
    public let rawPath: String?

    public init(photoId: String, jpgPath: String?, rawPath: String?) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
    }

    public var hasJpg: Bool { jpgPath != nil }
    public var hasRaw: Bool { rawPath != nil }
}

nonisolated public final class fileScanner: @unchecked Sendable {
    private static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    private static let rawExtensions: Set<String> = ["rw2", "cr2"]

    public init() {}

    public func scanTopLevel(_ folderUrl: URL) throws -> [photoFilePair] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderUrl.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "rawViewer.fileScanner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(folderUrl.path)"]
            )
        }

        let items = try fm.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var pairs: [String: photoFilePair] = [:]

        for url in items {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()

            if Self.jpgExtensions.contains(ext) {
                pairs[stem] = photoFilePair(photoId: stem, jpgPath: url.path, rawPath: pairs[stem]?.rawPath)
            } else if Self.rawExtensions.contains(ext) {
                pairs[stem] = photoFilePair(photoId: stem, jpgPath: pairs[stem]?.jpgPath, rawPath: url.path)
            }
        }

        return pairs.values.sorted { $0.photoId < $1.photoId }
    }
}
