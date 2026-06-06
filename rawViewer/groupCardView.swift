/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 分组卡片 view，叠放 JPG 缩略图异步加载；通过 imageService 拉取前 3 张缩略图，加载失败保留占位背景
*/

import AppKit
import CoreImage

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

        // Stack container for overlapping images
        stackContainer.wantsLayer = true
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        // Add up to 3 overlapping image previews
        let count = min(3, previewPhotos.count)
        let rotations: [CGFloat] = [-4, 3, -1]
        let offsets: [(CGFloat, CGFloat)] = [(8, 6), (22, 14), (32, 20)]

        for i in 0..<count {
            let imgView = NSImageView()
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.backgroundColor = NSColor.darkGray.cgColor
            imgView.layer?.cornerRadius = 4
            imgView.layer?.borderWidth = 0.5
            imgView.layer?.borderColor = NSColor.gray.withAlphaComponent(0.3).cgColor
            imgView.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(imgView)
            previewImageViews.append(imgView)

            NSLayoutConstraint.activate([
                imgView.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor, constant: offsets[i].0 - 20),
                imgView.centerYAnchor.constraint(equalTo: stackContainer.centerYAnchor, constant: offsets[i].1 - 10),
                imgView.widthAnchor.constraint(equalTo: stackContainer.widthAnchor, multiplier: 0.6),
                imgView.heightAnchor.constraint(equalTo: stackContainer.heightAnchor, multiplier: 0.75)
            ])

            imgView.layer?.transform = CATransform3DMakeRotation(rotations[i] * .pi / 180, 0, 0, 1)

            let photo = previewPhotos[i]
            let targetView = imgView
            let task = Task { [weak self] in
                let result = await imageService.loadImage(for: photo, kind: .thumbnail(width: 160, height: 110))
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self, self.previewImageViews.contains(targetView) else { return }
                    if case .image(let ciImage) = result {
                        let rep = NSCIImageRep(ciImage: ciImage)
                        let nsImage = NSImage(size: rep.size)
                        nsImage.addRepresentation(rep)
                        targetView.image = nsImage
                    }
                    // .unavailable 时保留 darkGray 占位背景（已在 setupView 设置）
                }
            }
            loadTasks.append(task)
        }

        // Labels
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
            stackContainer.heightAnchor.constraint(equalToConstant: 100),

            nameLabel.topAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4)
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @objc private func handleClick() {
        onTap?()
    }
}
