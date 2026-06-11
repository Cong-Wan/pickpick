/*
Author: wilbur
Version: 1.5
Date: 2026-06-11
Description: 提供 Swift 侧 review 状态更新接口，使用 analysisStore 替代直接 JSON 文件操作。v1.5 review 状态写回时保留既有 configSnapshot，避免覆盖真实分析配置
*/

import Foundation

public enum reviewOperation: Equatable {
    case status(photoId: String, status: reviewStatus)
    case template(reviewGroupId: String, templatePhotoId: String)
}

public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
    func update(_ mutate: (inout [photoItem]) -> Void) throws
}

public final class jsonReviewStateStore: jsonReviewStateStoring {
    public private(set) var operations: [reviewOperation] = []
    private let folderUrl: URL?

    public init(folderUrl: URL? = nil) {
        self.folderUrl = folderUrl
    }

    public func mark(photoId: String, status: reviewStatus) throws {
        try update { items in
            guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
            items[index].reviewStatus = status
        }
        operations.append(.status(photoId: photoId, status: status))
    }

    public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
        try update { items in
            for index in items.indices where items[index].reviewGroupId == reviewGroupId {
                items[index].templatePhotoId = templatePhotoId
            }
        }
        operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
    }

    public func clearReviewGroupId(photoId: String) throws {
        try update { items in
            guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
            items[index].reviewGroupId = ""
        }
    }

    public func update(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { return }
        var records = try analysisStore.shared.load(for: folderUrl)
        mutate(&records)
        try analysisStore.shared.save(folderUrl: folderUrl, records: records)
    }
}
