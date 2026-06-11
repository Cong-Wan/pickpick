/*
Author: wilbur
Version: 2.7
Date: 2026-06-11
Description: 收窄扑克牌扇形角度与水平偏移，避免分组缩略图散开过度
*/

import AppKit

private struct fanCardLayout {
    let rotationDegrees: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    let zPosition: CGFloat
}

public final class groupCardView: NSView {
    public var onTap: (() -> Void)?

    private let stackContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var previewImageViews: [NSImageView] = []
    private var loadTasks: [Task<Void, Never>] = []

    public init(group: photoGroup, previewPhotos: [photoItem], imageService: photoImageService) {
        super.init(frame: .zero)
        setupView(group: group, previewPhotos: previewPhotos, imageService: imageService)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        loadTasks.forEach { $0.cancel() }
    }

    private func setupView(group: photoGroup, previewPhotos: [photoItem], imageService: photoImageService) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8

        stackContainer.wantsLayer = true
        stackContainer.layer?.masksToBounds = false
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        let count = min(5, previewPhotos.count)
        let layouts = fanLayouts(for: count)

        for index in 0..<count {
            let layout = layouts[index]
            let cardContainer = NSView()
            cardContainer.wantsLayer = true
            cardContainer.layer?.backgroundColor = NSColor.clear.cgColor
            cardContainer.layer?.zPosition = layout.zPosition
            cardContainer.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(cardContainer)

            let imgView = NSImageView()
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.backgroundColor = NSColor.clear.cgColor
            imgView.layer?.cornerRadius = 0
            imgView.layer?.borderWidth = 0
            imgView.layer?.borderColor = nil
            imgView.layer?.shadowOpacity = 0
            imgView.translatesAutoresizingMaskIntoConstraints = false
            cardContainer.addSubview(imgView)
            previewImageViews.append(imgView)

            NSLayoutConstraint.activate([
                cardContainer.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor, constant: layout.xOffset),
                cardContainer.centerYAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: layout.yOffset),
                cardContainer.widthAnchor.constraint(equalToConstant: 82),
                cardContainer.heightAnchor.constraint(equalToConstant: 216),

                imgView.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),
                imgView.bottomAnchor.constraint(equalTo: cardContainer.centerYAnchor),
                imgView.widthAnchor.constraint(equalToConstant: 82),
                imgView.heightAnchor.constraint(equalToConstant: 108)
            ])

            cardContainer.frameCenterRotation = layout.rotationDegrees

            let photo = previewPhotos[index]
            let targetView = imgView
            let task = Task { [weak self] in
                let image = await imageService.loadThumbnail(for: photo, maxWidth: 164, maxHeight: 216)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self, self.previewImageViews.contains(targetView) else { return }
                    targetView.image = image
                }
            }
            loadTasks.append(task)
        }

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = group.kind.title

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.stringValue = "\(group.photos.count)"
        countLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            stackContainer.topAnchor.constraint(equalTo: topAnchor),
            stackContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackContainer.heightAnchor.constraint(equalToConstant: 120),

            nameLabel.topAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    private func fanLayouts(for count: Int) -> [fanCardLayout] {
        switch count {
        case 1:
            return [
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -8, zPosition: 1)
            ]
        case 2:
            return [
                fanCardLayout(rotationDegrees: 10, xOffset: -6, yOffset: -8, zPosition: 1),
                fanCardLayout(rotationDegrees: -10, xOffset: 6, yOffset: -8, zPosition: 2)
            ]
        case 3:
            return [
                fanCardLayout(rotationDegrees: 18, xOffset: -10, yOffset: -8, zPosition: 1),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -10, zPosition: 3),
                fanCardLayout(rotationDegrees: -18, xOffset: 10, yOffset: -8, zPosition: 2)
            ]
        case 4:
            return [
                fanCardLayout(rotationDegrees: 24, xOffset: -14, yOffset: -7, zPosition: 1),
                fanCardLayout(rotationDegrees: 8, xOffset: -5, yOffset: -10, zPosition: 3),
                fanCardLayout(rotationDegrees: -8, xOffset: 5, yOffset: -10, zPosition: 4),
                fanCardLayout(rotationDegrees: -24, xOffset: 14, yOffset: -7, zPosition: 2)
            ]
        default:
            return [
                fanCardLayout(rotationDegrees: 26, xOffset: -18, yOffset: -6, zPosition: 1),
                fanCardLayout(rotationDegrees: 13, xOffset: -8, yOffset: -9, zPosition: 3),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -11, zPosition: 5),
                fanCardLayout(rotationDegrees: -13, xOffset: 8, yOffset: -9, zPosition: 4),
                fanCardLayout(rotationDegrees: -26, xOffset: 18, yOffset: -6, zPosition: 2)
            ]
        }
    }

    @objc private func handleClick() {
        onTap?()
    }
}
