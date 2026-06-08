/*
Author: wilbur
Version: 1.4
Date: 2026-06-08
Description: 注入 photoTrashService，keepLeft/keepRight 在标记 JSON 前先将文件移入废纸篓
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
        try store.mark(photoId: right.photoId, status: .trashed)
        photos.removeAll { $0.photoId == right.photoId }
        if photos.count == 1 {
            try markFinalKept(left)
            return .finished
        }
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
        try store.mark(photoId: left.photoId, status: .trashed)
        photos.removeAll { $0.photoId == left.photoId }
        if photos.count == 1 {
            try markFinalKept(right)
            return .finished
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
        if let left = mainPhoto {
            try store.mark(photoId: left.photoId, status: .kept)
            try store.clearReviewGroupId(photoId: left.photoId)
        }
        if let right = candidatePhoto {
            try store.mark(photoId: right.photoId, status: .kept)
            try store.clearReviewGroupId(photoId: right.photoId)
        }

        let keptIds = Set([mainPhoto, candidatePhoto].compactMap { $0?.photoId })
        photos.removeAll { keptIds.contains($0.photoId) }

        switch photos.count {
        case 0:
            return .finished
        case 1:
            if let last = photos.first {
                try markFinalKept(last)
            }
            return .finished
        default:
            if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
                try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
            }
            mainIndex = 0
            candidateIndex = min(1, photos.count - 1)
            return .continueComparing
        }
    }

    private func markFinalKept(_ photo: photoItem) throws {
        try store.mark(photoId: photo.photoId, status: .kept)
        if !photo.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
            try store.clearReviewGroupId(photoId: photo.photoId)
        }
    }
}
