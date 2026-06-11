/*
Author: wilbur
Version: 3.4
Date: 2026-06-11
Description: 浏览器控制器，按当前照片 JPG/RAW 文件存在性禁用对应 segment，新增 Restore Normal 与显示旋转按钮，并显式设置左侧布局填充分布
*/

import AppKit
import CoreImage

public final class photoBrowserViewController: NSViewController {
    public let viewModel: photoBrowserViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public private(set) var groupTitle: String

    private let groupKind: photoGroupKind?
    private var toolbarView = NSView()
    private var thumbnailView: photoThumbnailView!
    private var mainPhotoController: photoMetalViewController!
    private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)
    private var restoreNormalButton: NSButton?
    private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
    private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
    private var loadTask: Task<Void, Never>?

    public init(viewModel: photoBrowserViewModel, imageService: photoImageService, groupKind: photoGroupKind? = nil) {
        self.viewModel = viewModel
        self.imageService = imageService
        self.groupKind = groupKind
        self.groupTitle = groupKind?.title ?? "Browser"
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(group: photoGroup, store: jsonReviewStateStoring, trashService: photoTrashServicing = photoTrashService(), imageService: photoImageService = photoImageService()) {
        let initialSource = displaySourceStore().current
        let viewModel = photoBrowserViewModel(photos: group.photos, store: store, trashService: trashService, displaySource: initialSource)
        self.init(viewModel: viewModel, imageService: imageService, groupKind: group.kind)
    }

    required init?(coder: NSCoder) {
        self.viewModel = photoBrowserViewModel(photos: [], store: jsonReviewStateStore(), trashService: photoTrashService())
        self.imageService = photoImageService()
        self.groupKind = nil
        self.groupTitle = "Browser"
        super.init(coder: coder)
    }

    deinit {
        loadTask?.cancel()
    }

    public override var acceptsFirstResponder: Bool { true }

    private var canRestoreNormal: Bool {
        switch groupKind {
        case .overexposed, .underexposed, .blurry:
            return true
        default:
            return false
        }
    }

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

        rotateLeftButton.target = self
        rotateLeftButton.action = #selector(rotateLeftClicked)
        rotateLeftButton.bezelStyle = .rounded
        rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false

        rotateRightButton.target = self
        rotateRightButton.action = #selector(rotateRightClicked)
        rotateRightButton.bezelStyle = .rounded
        rotateRightButton.translatesAutoresizingMaskIntoConstraints = false

        toolbarView.addSubview(backButton)
        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(sourceControl)
        toolbarView.addSubview(rotateLeftButton)
        toolbarView.addSubview(rotateRightButton)
        toolbarView.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            toolbarView.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: rotateLeftButton.leadingAnchor, constant: -8),
            rotateLeftButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            rotateLeftButton.trailingAnchor.constraint(equalTo: rotateRightButton.leadingAnchor, constant: -6),
            rotateRightButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            rotateRightButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])

        // Thumbnail list
        thumbnailView = photoThumbnailView(photos: viewModel.photos, imageService: imageService)
        thumbnailView.delegate = self
        thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
        thumbnailView.setCurrentIndex(viewModel.currentIndex)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let leftPanel = NSStackView()
        leftPanel.orientation = .vertical
        leftPanel.distribution = .fill
        leftPanel.spacing = 6
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.widthAnchor.constraint(equalToConstant: 150).isActive = true

        if canRestoreNormal {
            let button = NSButton(title: "Restore Normal", target: self, action: #selector(restoreNormalClicked))
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            restoreNormalButton = button
            leftPanel.addArrangedSubview(button)
        }
        leftPanel.addArrangedSubview(thumbnailView)

        // Main photo controller
        mainPhotoController = photoMetalViewController()
        addChild(mainPhotoController)
        mainPhotoController.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbarView)
        root.addSubview(leftPanel)
        root.addSubview(mainPhotoController.view)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            leftPanel.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 6),
            leftPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            mainPhotoController.view.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            mainPhotoController.view.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            mainPhotoController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainPhotoController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        loadCurrentPhoto()
    }

    private func loadCurrentPhoto() {
        loadTask?.cancel()
        mainPhotoController.reset()
        updateSourceControlAvailability()
        updateActionButtons()

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

    private func updateActionButtons() {
        let hasPhoto = viewModel.currentPhoto != nil
        restoreNormalButton?.isEnabled = hasPhoto && canRestoreNormal
        rotateLeftButton.isEnabled = hasPhoto
        rotateRightButton.isEnabled = hasPhoto
    }

    private func updateSourceControlAvailability() {
        guard let photo = viewModel.currentPhoto else {
            sourceControl.setEnabled(false, forSegment: 0)
            sourceControl.setEnabled(false, forSegment: 1)
            sourceControl.selectedSegment = -1
            return
        }

        let hasJpg = photo.hasExistingJpgFile()
        let hasRaw = photo.hasExistingRawFile()
        sourceControl.setEnabled(hasJpg, forSegment: 0)
        sourceControl.setEnabled(hasRaw, forSegment: 1)

        if viewModel.displaySource == .jpg, !hasJpg, hasRaw {
            appFileLogger.log("JPG source unavailable, switching to RAW page=browser photoId=\(photo.photoId)", level: .warning)
            displaySourceStore().current = .raw
            viewModel.setDisplaySource(.raw)
        } else if viewModel.displaySource == .raw, !hasRaw, hasJpg {
            appFileLogger.log("RAW source unavailable, switching to JPG page=browser photoId=\(photo.photoId)", level: .warning)
            displaySourceStore().current = .jpg
            viewModel.setDisplaySource(.jpg)
        }

        if hasJpg || hasRaw {
            sourceControl.selectedSegment = viewModel.displaySource == .jpg ? 0 : 1
        } else {
            sourceControl.selectedSegment = -1
        }
    }

    private func show(pair: photoDisplayPair, source: displaySource) {
        let rotationDegrees = viewModel.currentPhoto?.rotationDegrees ?? 0
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        if case .image(let image) = selected {
            mainPhotoController.load(image: image, rotationDegrees: rotationDegrees)
            return
        }

        if source == .raw, case .unavailable(let rawReason) = pair.raw {
            if case .image(let jpgImage) = pair.jpg {
                appFileLogger.log("RAW unavailable, fallback to JPG page=browser photoId=\(pair.photoId) reason=\(rawReason)", level: .warning)
                mainPhotoController.load(image: jpgImage, rotationDegrees: rotationDegrees)
                return
            }
            appFileLogger.log("RAW unavailable and JPG unavailable page=browser photoId=\(pair.photoId) rawReason=\(rawReason) jpgReason=\(unavailableReason(pair.jpg))", level: .error)
        }

        if case .image(let jpgImage) = pair.jpg {
            mainPhotoController.load(image: jpgImage, rotationDegrees: rotationDegrees)
            return
        }
        mainPhotoController.showError("No image available")
    }

    private func unavailableReason(_ result: photoImageResult) -> String {
        if case .unavailable(let message) = result {
            return message
        }
        return "unknown"
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
        guard let photo = viewModel.currentPhoto else {
            sender.selectedSegment = -1
            return
        }

        if source == .jpg, !photo.hasExistingJpgFile() {
            appFileLogger.log("JPG selection rejected page=browser photoId=\(photo.photoId) reason=jpgFileUnavailable", level: .warning)
            updateSourceControlAvailability()
            return
        }
        if source == .raw, !photo.hasExistingRawFile() {
            appFileLogger.log("RAW selection rejected page=browser photoId=\(photo.photoId) reason=rawFileUnavailable", level: .warning)
            updateSourceControlAvailability()
            return
        }

        displaySourceStore().current = source
        viewModel.setDisplaySource(source)
        loadCurrentPhoto()
    }

    @objc private func restoreNormalClicked() {
        let targets = viewModel.restoreNormalTargets()
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.photoId)
        do {
            try viewModel.restoreNormalTargetsAndUpdateList()
            thumbnailView.updatePhotos(viewModel.photos)
            thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
            if viewModel.photos.isEmpty {
                onBack?()
            } else {
                thumbnailView.setCurrentIndex(viewModel.currentIndex)
                loadCurrentPhoto()
            }
        } catch {
            appFileLogger.log("operation failed page=browser action=restoreNormal targetCount=\(targets.count) photoIds=\(ids.joined(separator: ",")) error=\(error.localizedDescription)", level: .error)
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func rotateLeftClicked() {
        rotateCurrent(direction: .left, actionName: "rotateLeft")
    }

    @objc private func rotateRightClicked() {
        rotateCurrent(direction: .right, actionName: "rotateRight")
    }

    private func rotateCurrent(direction: photoRotationDirection, actionName: String) {
        guard let photo = viewModel.currentPhoto else { return }
        let oldRotation = photo.rotationDegrees
        let targetRotation = rotatedDegrees(oldRotation, direction: direction)
        do {
            _ = try viewModel.rotateCurrentPhoto(direction: direction)
            loadCurrentPhoto()
        } catch {
            appFileLogger.log("operation failed page=browser action=\(actionName) photoId=\(photo.photoId) oldRotation=\(oldRotation) targetRotation=\(targetRotation) error=\(error.localizedDescription)", level: .error)
            showErrorAlert(message: error.localizedDescription)
        }
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
