/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 实现重复照片双图比较状态机、keep/pass/template 决策和最小 AppKit 比较界面
*/

import AppKit

public final class duplicateCompareState {
    public private(set) var photos: [photoItem]
    public private(set) var mainIndex: Int = 0
    public private(set) var candidateIndex: Int = 1
    public private(set) var deleteConfirmationRequested = false
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws {
        guard let right = candidatePhoto else {
            try finishIfSingleRemaining()
            return
        }
        try store.mark(photoId: right.photoId, status: .trashed)
        photos.remove(at: candidateIndex)
        candidateIndex = min(1, photos.count)
        try finishIfSingleRemaining()
    }

    public func keepRight() throws {
        guard let left = mainPhoto, let right = candidatePhoto else {
            try finishIfSingleRemaining()
            return
        }
        try store.mark(photoId: left.photoId, status: .trashed)
        photos.remove(at: mainIndex)
        if let newMainIndex = photos.firstIndex(where: { $0.photoId == right.photoId }) {
            mainIndex = newMainIndex
            candidateIndex = min(newMainIndex + 1, photos.count)
        }
        try finishIfSingleRemaining()
    }

    public func keepBoth(templatePhotoId: String) throws {
        if let left = mainPhoto { try store.mark(photoId: left.photoId, status: .kept) }
        if let right = candidatePhoto { try store.mark(photoId: right.photoId, status: .kept) }
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
    }

    public func finishIfSingleRemaining() throws {
        guard photos.count == 1, let remaining = photos.first else { return }
        try store.mark(photoId: remaining.photoId, status: .kept)
        if !remaining.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: remaining.reviewGroupId, templatePhotoId: remaining.photoId)
        }
    }
}

public final class duplicateCompareViewController: NSViewController {
    public let state: duplicateCompareState

    public init(group: photoGroup, store: jsonReviewStateStoring) {
        self.state = duplicateCompareState(photos: group.photos, store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.state = duplicateCompareState(photos: [], store: jsonReviewStateStore())
        super.init(coder: coder)
    }

    public override func loadView() {
        let label = NSTextField(labelWithString: "Duplicate Compare")
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
