/*
Author: wilbur
Version: 1.2
Date: 2026-06-06
Description: duplicate compare ViewModel，markFinalKept 和 keepBoth 均新增 clearReviewGroupId 调用
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

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
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
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
        return .finished
    }

    private func markFinalKept(_ photo: photoItem) throws {
        try store.mark(photoId: photo.photoId, status: .kept)
        if !photo.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
            try store.clearReviewGroupId(photoId: photo.photoId)
        }
    }
}
