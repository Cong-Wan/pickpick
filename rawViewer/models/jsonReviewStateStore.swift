/*
Author: wilbur
Version: 1.7
Date: 2026-06-13
Description: 新增 Restore Normal 和照片旋转角度持久化接口；保留 review 状态写回时既有 configSnapshot。v1.7 通过 analysisStore 串行 update 入口执行 JSON 状态变更
*/

import Foundation

public enum reviewOperation: Equatable {
    case status(photoId: String, status: reviewStatus)
    case template(reviewGroupId: String, templatePhotoId: String)
    case restoreNormal(photoIds: Set<String>)
    case rotations([String: Int])
}

public enum reviewStateStoreError: LocalizedError, Equatable {
    case emptyPhotoIds
    case missingPhotoIds([String])

    public var errorDescription: String? {
        switch self {
        case .emptyPhotoIds:
            return "No photo ids were provided"
        case .missingPhotoIds(let ids):
            return "Photo ids were not found in analysis store: \(ids.joined(separator: ","))"
        }
    }
}

public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
    func restoreNormal(photoIds: Set<String>) throws
    func setRotations(_ rotationsByPhotoId: [String: Int]) throws
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

    public func restoreNormal(photoIds: Set<String>) throws {
        guard !photoIds.isEmpty else { throw reviewStateStoreError.emptyPhotoIds }
        try updateThrowing { items in
            var missingIds = photoIds
            for index in items.indices where photoIds.contains(items[index].photoId) {
                items[index].exposureStatus = "normal"
                items[index].isBlurry = false
                missingIds.remove(items[index].photoId)
            }
            guard missingIds.isEmpty else {
                throw reviewStateStoreError.missingPhotoIds(missingIds.sorted())
            }
        }
        operations.append(.restoreNormal(photoIds: photoIds))
    }

    public func setRotations(_ rotationsByPhotoId: [String: Int]) throws {
        let photoIds = Set(rotationsByPhotoId.keys)
        guard !photoIds.isEmpty else { throw reviewStateStoreError.emptyPhotoIds }
        try updateThrowing { items in
            var missingIds = photoIds
            for index in items.indices {
                let photoId = items[index].photoId
                guard let rotation = rotationsByPhotoId[photoId] else { continue }
                items[index].rotationDegrees = normalizedRotationDegrees(rotation)
                missingIds.remove(photoId)
            }
            guard missingIds.isEmpty else {
                throw reviewStateStoreError.missingPhotoIds(missingIds.sorted())
            }
        }
        operations.append(.rotations(rotationsByPhotoId.mapValues { normalizedRotationDegrees($0) }))
    }

    public func update(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { return }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            mutate(&items)
        }
    }

    private func updateThrowing(_ mutate: (inout [photoItem]) throws -> Void) throws {
        guard let folderUrl else { return }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            try mutate(&items)
        }
    }
}
