/*
Author: wilbur
Version: 3.0
Date: 2026-06-06
Description: 浏览器控制器，使用 photoMetalViewController 替代直接 metalPhotoView；loadCurrentPhoto 先 reset() 清空 zoom/pan
*/

import AppKit
import CoreImage

public final class photoBrowserViewController: NSViewController {
    public let viewModel: photoBrowserViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public private(set) var groupTitle: String

    private var toolbarView = NSView()
    private var thumbnailView: photoThumbnailView!
    private var mainPhotoController: photoMetalViewController!
    private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)
    private var loadTask: Task<Void, Never>?

    public init(viewModel: photoBrowserViewModel, imageService: photoImageService) {
        self.viewModel = viewModel
        self.imageService = imageService
        self.groupTitle = "Browser"
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(group: photoGroup, store: jsonReviewStateStoring, trashService: photoTrashServicing = photoTrashService(), imageService: photoImageService = photoImageService()) {
        let initialSource = displaySourceStore().current
        let viewModel = photoBrowserViewModel(photos: group.photos, store: store, trashService: trashService, displaySource: initialSource)
        self.init(viewModel: viewModel, imageService: imageService)
        self.groupTitle = group.kind.title
    }

    required init?(coder: NSCoder) {
        self.viewModel = photoBrowserViewModel(photos: [], store: jsonReviewStateStore(), trashService: photoTrashService())
        self.imageService = photoImageService()
        self.groupTitle = "Browser"
        super.init(coder: coder)
    }

    deinit {
        loadTask?.cancel()
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
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let backButton = NSButton(title: "← Back", target: self, action: #selector(backClicked))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "\(groupTitle) · \(viewModel.photos.count)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        sourceControl.target = self
        sourceControl.action = #selector(sourceChanged(_:))
        sourceControl.selectedSegment = viewModel.displaySource == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton(title: "🗑", target: self, action: #selector(deleteClicked))
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        toolbarView.addSubview(backButton)
        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(sourceControl)
        toolbarView.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            toolbarView.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])

        // Thumbnail list
        thumbnailView = photoThumbnailView(photos: viewModel.photos, imageService: imageService)
        thumbnailView.delegate = self
        thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
        thumbnailView.setCurrentIndex(viewModel.currentIndex)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 150)
        ])

        // Main photo controller
        mainPhotoController = photoMetalViewController()
        addChild(mainPhotoController)
        mainPhotoController.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbarView)
        root.addSubview(thumbnailView)
        root.addSubview(mainPhotoController.view)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            thumbnailView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            mainPhotoController.view.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            mainPhotoController.view.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            mainPhotoController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainPhotoController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        loadCurrentPhoto()
    }

    private func loadCurrentPhoto() {
        loadTask?.cancel()
        mainPhotoController.reset()

        guard let photo = viewModel.currentPhoto else {
            return
        }
        let requestId = viewModel.currentRequestId
        let photoId = photo.photoId
        let selectedSource = viewModel.displaySource
        loadTask = Task { [weak self] in
            guard let self else { return }
            let pair = await self.imageService.preloadDisplayPair(for: photo)
            if Task.isCancelled { return }
            await MainActor.run {
                guard self.viewModel.isCurrentRequest(requestId, photoId: photoId) else { return }
                self.show(pair: pair, source: selectedSource)
            }
        }
    }

    private func show(pair: photoDisplayPair, source: displaySource) {
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        if case .image(let image) = selected {
            mainPhotoController.load(image: image)
            return
        }
        if case .image(let jpgImage) = pair.jpg {
            mainPhotoController.load(image: jpgImage)
            return
        }
        mainPhotoController.showError("No image available")
    }

    @objc private func backClicked() {
        onBack?()
    }

    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Operation failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        let source: displaySource = (sender.selectedSegment == 0) ? .jpg : .raw
        displaySourceStore().current = source
        viewModel.setDisplaySource(source)
        loadCurrentPhoto()
    }

    @objc private func deleteClicked() {
        let targets = viewModel.deleteTargets()
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(targets.count) photo(s)?"
        alert.informativeText = "This will move the selected photo(s) to trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try viewModel.confirmDelete()
                thumbnailView.updatePhotos(viewModel.photos)
                thumbnailView.setCurrentIndex(viewModel.currentIndex)
                loadCurrentPhoto()
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down arrow
            viewModel.moveNext()
            thumbnailView.setCurrentIndex(viewModel.currentIndex)
            loadCurrentPhoto()
        case 126: // Up arrow
            viewModel.movePrevious()
            thumbnailView.setCurrentIndex(viewModel.currentIndex)
            loadCurrentPhoto()
        case 51: // Backspace
            deleteClicked()
        default:
            switch event.charactersIgnoringModifiers {
            case "=", "+": mainPhotoController.zoomIn()
            case "-": mainPhotoController.zoomOut()
            case "r", "R": mainPhotoController.resetZoom()
            default: super.keyDown(with: event)
            }
        }
    }
}

extension photoBrowserViewController: photoThumbnailViewDelegate {
    public func thumbnailDidSelect(index: Int) {
        viewModel.setCurrentIndex(index)
        loadCurrentPhoto()
    }

    public func thumbnailDidToggleCheck(photoId: String, isChecked: Bool) {
        viewModel.toggleCheck(photoId: photoId, isChecked: isChecked)
    }

    public func thumbnailDidToggleAll(isChecked: Bool) {
        viewModel.toggleAll(isChecked: isChecked)
    }
}
