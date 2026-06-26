/*
Author: wilbur
Version: 1.1
Date: 2026-06-25
Description: 缩略图列表 NSTableCellView，包含 NSImageView + checkbox + 选中态边框，自管理异步缩略图加载 Task；v1.1 异步缩略图回调校验 photoId，避免 cell 复用串图
*/

import AppKit

public final class photoThumbnailCellView: NSTableCellView {
    public let thumbImageView = NSImageView()
    public let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var loadTask: Task<Void, Never>?
    private var representedPhotoId: String?

    public var thumbIndex: Int = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.darkGray.cgColor

        thumbImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbImageView.imageAlignment = .alignCenter
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbImageView)
        NSLayoutConstraint.activate([
            thumbImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbImageView.topAnchor.constraint(equalTo: topAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
        ])
    }

    public func configure(
        photo: photoItem,
        index: Int,
        isSelected: Bool,
        isChecked: Bool,
        imageService: photoImageService?
    ) {
        thumbIndex = index
        representedPhotoId = photo.photoId
        cancelLoad()
        thumbImageView.image = nil
        layer?.backgroundColor = NSColor.darkGray.cgColor
        layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        checkbox.state = isChecked ? .on : .off
        checkbox.tag = index

        guard let imageService = imageService else { return }
        let targetView = thumbImageView
        let expectedPhotoId = photo.photoId
        loadTask = Task { [weak self, weak targetView] in
            let image = await imageService.loadThumbnail(for: photo)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self,
                      self.representedPhotoId == expectedPhotoId,
                      let targetView = targetView,
                      self.thumbImageView === targetView else { return }
                if let image {
                    targetView.image = image
                    self.layer?.backgroundColor = NSColor.clear.cgColor
                }
            }
        }
    }

    public func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        representedPhotoId = nil
        thumbImageView.image = nil
        layer?.backgroundColor = NSColor.darkGray.cgColor
        layer?.borderColor = NSColor.clear.cgColor
    }
}
