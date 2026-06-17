/*
Author: wilbur
Version: 1.6
Date: 2026-06-17
Description: 注入 photoTrashService，keepLeft/keepRight 在标记 JSON 前先将文件移入废纸篓；Duplicate 旋转改为当前组剩余照片整体旋转，确保新顶替照片继承旋转状态
*/

import Foundation

public enum duplicateCompareActionResult: Equatable {
    case continueComparing
    case finished
}

public final class duplicateCompareViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var mainIndex: Int = 0
    public private(set) var candidateIndex: Int = 1
    private let store: jsonReviewStateStoring
    private let trashService: photoTrashServicing

    public init(photos: [photoItem], store: jsonReviewStateStoring, trashService: photoTrashServicing) {
        self.photos = photos
        self.store = store
        self.trashService = trashService
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try trashService.trash(right)
        photos.removeAll { $0.photoId == right.photoId }
        let shouldFinish = photos.count == 1
        try store.update { items in
            if let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
                items[rightIndex].reviewStatus = .trashed
            }
            if shouldFinish, let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
                items[leftIndex].reviewStatus = .kept
                if !left.reviewGroupId.isEmpty {
                    for index in items.indices where items[index].reviewGroupId == left.reviewGroupId {
                        items[index].templatePhotoId = left.photoId
                    }
                    items[leftIndex].reviewGroupId = ""
                }
            }
        }
        if shouldFinish { return .finished }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepRight() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try trashService.trash(left)
        photos.removeAll { $0.photoId == left.photoId }
        let shouldFinish = photos.count == 1
        try store.update { items in
            if let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
                items[leftIndex].reviewStatus = .trashed
            }
            if shouldFinish, let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
                items[rightIndex].reviewStatus = .kept
                if !right.reviewGroupId.isEmpty {
                    for index in items.indices where items[index].reviewGroupId == right.reviewGroupId {
                        items[index].templatePhotoId = right.photoId
                    }
                    items[rightIndex].reviewGroupId = ""
                }
            }
        }
        if shouldFinish { return .finished }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
        let left = mainPhoto
        let right = candidatePhoto
        let originalGroupId = left?.reviewGroupId.isEmpty == false ? left?.reviewGroupId : right?.reviewGroupId
        let keptIds = Set([left, right].compactMap { $0?.photoId })

        photos.removeAll { keptIds.contains($0.photoId) }
        let remainingCount = photos.count
        let remainingLast = photos.first

        try store.update { items in
            for index in items.indices where keptIds.contains(items[index].photoId) {
                items[index].reviewStatus = .kept
                items[index].reviewGroupId = ""
            }

            if remainingCount == 1, let last = remainingLast,
               let lastIndex = items.firstIndex(where: { $0.photoId == last.photoId }) {
                items[lastIndex].reviewStatus = .kept
                if !last.reviewGroupId.isEmpty {
                    for index in items.indices where items[index].reviewGroupId == last.reviewGroupId {
                        items[index].templatePhotoId = last.photoId
                    }
                    items[lastIndex].reviewGroupId = ""
                }
            } else if remainingCount > 1, let groupId = originalGroupId, !groupId.isEmpty {
                for index in items.indices where items[index].reviewGroupId == groupId {
                    items[index].templatePhotoId = templatePhotoId
                }
            }
        }

        switch remainingCount {
        case 0:
            return .finished
        case 1:
            return .finished
        default:
            mainIndex = 0
            candidateIndex = min(1, photos.count - 1)
            return .continueComparing
        }
    }

    @discardableResult
    public func rotateCurrentGroup(direction: photoRotationDirection) throws -> [String: Int] {
        guard !photos.isEmpty else { return [:] }

        let baseRotation = mainPhoto?.rotationDegrees
            ?? candidatePhoto?.rotationDegrees
            ?? photos.first?.rotationDegrees
            ?? 0
        let targetRotation = rotatedDegrees(baseRotation, direction: direction)
        let rotations = Dictionary(uniqueKeysWithValues: photos.map { ($0.photoId, targetRotation) })

        try store.setRotations(rotations)

        for index in photos.indices {
            photos[index].rotationDegrees = targetRotation
        }
        return rotations
    }

    @discardableResult
    public func rotateCurrentPair(direction: photoRotationDirection) throws -> [String: Int] {
        try rotateCurrentGroup(direction: direction)
    }

    private func markFinalKept(_ photo: photoItem) throws {
        try store.update { items in
            guard let index = items.firstIndex(where: { $0.photoId == photo.photoId }) else { return }
            items[index].reviewStatus = .kept
            if !photo.reviewGroupId.isEmpty {
                for itemIndex in items.indices where items[itemIndex].reviewGroupId == photo.reviewGroupId {
                    items[itemIndex].templatePhotoId = photo.photoId
                }
                items[index].reviewGroupId = ""
            }
        }
    }
}
