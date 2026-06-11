/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 浏览器视图模型：封装 photos/currentIndex/checkedPhotoIds/displaySource 状态，支持 Restore Normal 和展示旋转状态同步；
并通过单调递增的 currentRequestId 让控制器在异步预加载完成时识别请求是否已被新的导航覆盖，
避免在快速上下切换时把陈旧的 JPG/RAW 结果渲染到当前主图上；
集成 photoTrashService，删除时先移入废纸篓再标记 JSON 状态
*/

import Foundation

public final class photoBrowserViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public private(set) var checkedPhotoIds: Set<String> = []
    public private(set) var displaySource: displaySource
    public private(set) var currentRequestId: Int = 0
    private let store: jsonReviewStateStoring
    private let trashService: photoTrashServicing

    public init(photos: [photoItem], store: jsonReviewStateStoring, trashService: photoTrashServicing, displaySource: displaySource = .jpg) {
        self.photos = photos
        self.store = store
        self.trashService = trashService
        self.displaySource = displaySource
    }

    public var currentPhoto: photoItem? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
        currentRequestId += 1
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        currentRequestId += 1
    }

    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        currentRequestId += 1
    }

    public func setDisplaySource(_ source: displaySource) {
        displaySource = source
        currentRequestId += 1
    }

    public func isCurrentRequest(_ requestId: Int, photoId: String) -> Bool {
        currentRequestId == requestId && currentPhoto?.photoId == photoId
    }

    public func toggleCheck(photoId: String, isChecked: Bool) {
        if isChecked {
            checkedPhotoIds.insert(photoId)
        } else {
            checkedPhotoIds.remove(photoId)
        }
    }

    public func toggleAll(isChecked: Bool) {
        checkedPhotoIds = isChecked ? Set(photos.map(\.photoId)) : []
    }

    public func deleteTargets() -> [photoItem] {
        if checkedPhotoIds.isEmpty {
            return currentPhoto.map { [$0] } ?? []
        }
        return photos.filter { checkedPhotoIds.contains($0.photoId) }
    }

    public func restoreNormalTargets() -> [photoItem] {
        if checkedPhotoIds.isEmpty {
            return currentPhoto.map { [$0] } ?? []
        }
        return photos.filter { checkedPhotoIds.contains($0.photoId) }
    }

    public func restoreNormalTargetsAndUpdateList() throws {
        let targets = restoreNormalTargets()
        let ids = Set(targets.map(\.photoId))
        guard !ids.isEmpty else { return }

        try store.restoreNormal(photoIds: ids)

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }

    @discardableResult
    public func rotateCurrentPhoto(direction: photoRotationDirection) throws -> Int? {
        guard let photo = currentPhoto else { return nil }
        let newRotation = rotatedDegrees(photo.rotationDegrees, direction: direction)
        try store.setRotations([photo.photoId: newRotation])
        photos[currentIndex].rotationDegrees = newRotation
        currentRequestId += 1
        return newRotation
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets {
            try trashService.trash(photo)
        }

        let ids = Set(targets.map(\.photoId))
        try store.update { items in
            for index in items.indices where ids.contains(items[index].photoId) {
                items[index].reviewStatus = .trashed
            }
        }

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }
}
