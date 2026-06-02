/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 实现普通照片浏览器状态机、键盘导航、删除目标选择和最小 AppKit 浏览界面
*/

import AppKit

public final class photoBrowserState {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public var checkedPhotoIds: Set<String> = []
    public private(set) var updateHappenedBeforeAdvance = false
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var currentPhoto: photoItem? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
    }

    public func deleteTargets() -> [photoItem] {
        if !checkedPhotoIds.isEmpty {
            return photos.filter { checkedPhotoIds.contains($0.photoId) }
        }
        return currentPhoto.map { [$0] } ?? []
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets {
            try store.mark(photoId: photo.photoId, status: .trashed)
        }
        updateHappenedBeforeAdvance = true
        let targetIds = Set(targets.map(\.photoId))
        photos.removeAll { targetIds.contains($0.photoId) }
        checkedPhotoIds.subtract(targetIds)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
    }
}

public final class photoBrowserViewController: NSViewController {
    public let state: photoBrowserState

    public init(group: photoGroup, store: jsonReviewStateStoring) {
        self.state = photoBrowserState(photos: group.photos, store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.state = photoBrowserState(photos: [], store: jsonReviewStateStore())
        super.init(coder: coder)
    }

    public override func loadView() {
        let label = NSTextField(labelWithString: "Photo Browser")
        label.alignment = .center
        view = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
