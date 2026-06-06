/*
Author: wilbur
Version: 3.0
Date: 2026-06-06
Description: 重复照片双图比较界面，使用 photoMetalViewController 替代直接 metalPhotoView；loadPhotos 时先 reset() 两个 controller
*/

import AppKit
import CoreImage

public final class duplicateCompareViewController: NSViewController {
    public let viewModel: duplicateCompareViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public var onFinished: (() -> Void)?

    private let sourceStore = displaySourceStore()
    private var leftPhotoController: photoMetalViewController!
    private var rightPhotoController: photoMetalViewController!
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?

    public init(viewModel: duplicateCompareViewModel, imageService: photoImageService) {
        self.viewModel = viewModel
        self.imageService = imageService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.viewModel = duplicateCompareViewModel(photos: [], store: jsonReviewStateStore())
        self.imageService = photoImageService()
        super.init(coder: coder)
    }

    deinit {
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let backButton = NSButton(title: "← Back", target: self, action: #selector(backClicked))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Duplicate · \(viewModel.photos.count)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let keepBothBtn = NSButton(title: "Keep both", target: self, action: #selector(keepBothClicked(_:)))
        keepBothBtn.translatesAutoresizingMaskIntoConstraints = false

        let sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: self, action: #selector(sourceChanged(_:)))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(keepBothBtn)
        toolbar.addSubview(sourceControl)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
            keepBothBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            keepBothBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        // Split view for two photo controllers
        let splitView = NSStackView()
        splitView.orientation = .horizontal
        splitView.distribution = .fillEqually
        splitView.spacing = 0
        splitView.translatesAutoresizingMaskIntoConstraints = false

        leftPhotoController = photoMetalViewController()
        rightPhotoController = photoMetalViewController()
        addChild(leftPhotoController)
        addChild(rightPhotoController)

        leftPhotoController.view.translatesAutoresizingMaskIntoConstraints = false
        rightPhotoController.view.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(leftPhotoController.view)
        splitView.addArrangedSubview(rightPhotoController.view)

        root.addSubview(toolbar)
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        loadPhotos()
    }

    private func loadPhotos() {
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
        leftPhotoController.reset()
        rightPhotoController.reset()

        if let left = viewModel.mainPhoto {
            let photoId = left.photoId
            leftLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: left)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.mainPhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: true)
                }
            }
        }

        if let right = viewModel.candidatePhoto {
            let photoId = right.photoId
            rightLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: right)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.candidatePhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: false)
                }
            }
        }
    }

    private func show(pair: photoDisplayPair, source: displaySource, isLeft: Bool) {
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        let controller: photoMetalViewController = isLeft ? leftPhotoController : rightPhotoController
        if case .image(let image) = selected {
            controller.load(image: image)
            return
        }
        if case .image(let jpgImage) = pair.jpg {
            controller.load(image: jpgImage)
            return
        }
        controller.showError("No image available")
    }

    @objc private func backClicked() {
        onBack?()
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        sourceStore.current = (sender.selectedSegment == 0) ? .jpg : .raw
        loadPhotos()
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = viewModel.mainPhoto else { return }
        let alert = NSAlert()
        alert.messageText = "Select template photo"
        alert.informativeText = "Which photo should be the template for this group?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Left")
        alert.addButton(withTitle: "Right")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = try? viewModel.keepBoth(templatePhotoId: left.photoId)
            handleActionResult(.finished)
        } else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
            _ = try? viewModel.keepBoth(templatePhotoId: right.photoId)
            handleActionResult(.finished)
        }
    }

    private func handleActionResult(_ result: duplicateCompareActionResult) {
        switch result {
        case .finished:
            onFinished?()
        case .continueComparing:
            loadPhotos()
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            if let result = try? viewModel.keepLeft() {
                handleActionResult(result)
            }
        case 124: // Right arrow
            if let result = try? viewModel.keepRight() {
                handleActionResult(result)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
