/*
Author: wilbur
Version: 1.4
Date: 2026-06-25
Description: 浏览器视图模型：封装 photos/currentIndex/checkedPhotoIds/displaySource 状态，支持 Restore Normal 和展示旋转状态同步；
并通过单调递增的 currentRequestId 让控制器在异步预加载完成时识别请求是否已被新的导航覆盖，
避免在快速上下切换时把陈旧的 JPG/RAW 结果渲染到当前主图上；
集成 photoTrashService，删除时先把目标状态落盘为 trashed、再逐张尽力删文件（失败只记日志不抛错），状态先于文件动作落盘消除幽灵照片；
新增 carriedRotation 惯性角度 + handledPhotoIds 已处理集合：旋转某张后翻页逐张继承并落盘，已处理照片回翻不覆盖
*/

import Foundation

public final class photoBrowserViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public private(set) var checkedPhotoIds: Set<String> = []
    public private(set) var displaySource: displaySource
    public private(set) var currentRequestId: Int = 0
    public private(set) var carriedRotation: Int?  // nil = 尚未开始带旋转
    public private(set) var handledPhotoIds: Set<String> = []  // 已处理照片（手动转过或已被惯性带过），回翻不再覆盖
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
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }

    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        applyCarriedRotationIfNeeded()
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
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }

    @discardableResult
    public func rotateCurrentPhoto(direction: photoRotationDirection) throws -> Int? {
        guard let photo = currentPhoto else { return nil }
        let base = carriedRotation ?? photo.rotationDegrees
        let newRotation = rotatedDegrees(base, direction: direction)
        try store.setRotations([photo.photoId: newRotation])
        carriedRotation = newRotation
        handledPhotoIds.insert(photo.photoId)
        photos[currentIndex].rotationDegrees = newRotation
        currentRequestId += 1
        return newRotation
    }

    /// 导航切到新当前照片时，若已开始带旋转且该照片未被处理过，则把 carriedRotation 继承到该照片并落盘。
    /// 已处理照片（手动转过或已被惯性带过）跳过，保留用户为它设定的角度——这是回翻不覆盖的关键。
    /// 失败只记日志、不阻断导航；此时内存角度未更新、该照片未入 handledPhotoIds，下次切换会再尝试，可自愈。
    private func applyCarriedRotationIfNeeded() {
        guard let carried = carriedRotation else { return }
        guard photos.indices.contains(currentIndex) else { return }
        let photo = photos[currentIndex]
        guard !handledPhotoIds.contains(photo.photoId) else { return }
        do {
            try store.setRotations([photo.photoId: carried])
            photos[currentIndex].rotationDegrees = carried
            handledPhotoIds.insert(photo.photoId)
        } catch {
            appFileLogger.log("carry rotation failed photoId=\(photo.photoId) rotation=\(carried) error=\(error.localizedDescription)", level: .error)
        }
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        let ids = Set(targets.map(\.photoId))
        guard !ids.isEmpty else { return }

        // 1. 先把目标状态落盘为 trashed —— 保证 JSON 永不落后于磁盘。
        //    即便后续文件删除失败，状态已是 trashed，下次启动 cleanupTrashedPhotos 会兜底删文件，
        //    不会出现"文件已删但状态还是 active"的幽灵照片。
        //    注意：只有这步会抛错（磁盘 IO 失败），那时 photos 尚未变更，VC catch 不刷新 UI 也安全。
        try store.update { items in
            for index in items.indices where ids.contains(items[index].photoId) {
                items[index].reviewStatus = .trashed
            }
        }

        // 2. 逐张删文件，尽力而为：失败只记日志，不抛错。
        //    状态已 trashed，文件若未删成功，下次启动 cleanupTrashedPhotos 会兜底。
        //    刻意不抛错——与 duplicateCompareViewModel.keepLeft/keepRight 行为一致，
        //    让 photoBrowserViewController.deleteClicked 始终走 do 成功路径刷新 UI，
        //    避免"部分成功时抛错进 catch、列表不刷新"导致 UI/内存不一致。
        for photo in targets {
            do {
                try trashService.trash(photo)
            } catch {
                appFileLogger.log("delete photo failed photoId=\(photo.photoId) error=\(error.localizedDescription)", level: .error)
            }
        }

        // 3. 从内存列表移除全部目标（状态已正确落盘，缺失文件由启动时 cleanup 兜底，不会产生幽灵照片）
        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
}
