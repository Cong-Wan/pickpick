/*
Author: wilbur
Version: 3.5
Date: 2026-06-12
Description: 重复照片双图比较界面，按左右任意一侧 JPG/RAW 文件存在性控制对应 segment，并新增左右一起旋转和同步缩放快捷键
*/

import AppKit
import CoreImage

public final class duplicateCompareViewController: NSViewController {
    public let viewModel: duplicateCompareViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public var onFinished: (() -> Void)?

    private let sourceStore = displaySourceStore()
    private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)
    private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
    private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
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
        self.viewModel = duplicateCompareViewModel(photos: [], store: jsonReviewStateStore(), trashService: photoTrashService())
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

        sourceControl.target = self
        sourceControl.action = #selector(sourceChanged(_:))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        rotateLeftButton.target = self
        rotateLeftButton.action = #selector(rotateLeftClicked)
        rotateLeftButton.bezelStyle = .rounded
        rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false

        rotateRightButton.target = self
        rotateRightButton.action = #selector(rotateRightClicked)
        rotateRightButton.bezelStyle = .rounded
        rotateRightButton.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(keepBothBtn)
        toolbar.addSubview(sourceControl)
        toolbar.addSubview(rotateLeftButton)
        toolbar.addSubview(rotateRightButton)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: rotateLeftButton.leadingAnchor, constant: -8),
            rotateLeftButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            rotateLeftButton.trailingAnchor.constraint(equalTo: rotateRightButton.leadingAnchor, constant: -6),
            rotateRightButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            rotateRightButton.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
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
        updateSourceControlAvailability()
        let selectedSource = sourceStore.current
        updateActionButtons()

        if let left = viewModel.mainPhoto {
            let photoId = left.photoId
            leftLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: left)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.mainPhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: selectedSource, isLeft: true)
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
                    self.show(pair: pair, source: selectedSource, isLeft: false)
                }
            }
        }
    }

    private func updateActionButtons() {
        let hasPhoto = viewModel.mainPhoto != nil || viewModel.candidatePhoto != nil
        rotateLeftButton.isEnabled = hasPhoto
        rotateRightButton.isEnabled = hasPhoto
    }

    private func updateSourceControlAvailability() {
        let canSelectJpg = canSelectJpgForCurrentPair()
        let canSelectRaw = canSelectRawForCurrentPair()
        sourceControl.setEnabled(canSelectJpg, forSegment: 0)
        sourceControl.setEnabled(canSelectRaw, forSegment: 1)

        if sourceStore.current == .jpg, !canSelectJpg, canSelectRaw {
            appFileLogger.log("JPG source unavailable, switching to RAW page=duplicate", level: .warning)
            sourceStore.current = .raw
        } else if sourceStore.current == .raw, !canSelectRaw, canSelectJpg {
            appFileLogger.log("RAW source unavailable, switching to JPG page=duplicate", level: .warning)
            sourceStore.current = .jpg
        }

        if canSelectJpg || canSelectRaw {
            sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        } else {
            sourceControl.selectedSegment = -1
        }
    }

    private func canSelectJpgForCurrentPair() -> Bool {
        let leftHasJpg = viewModel.mainPhoto?.hasExistingJpgFile() == true
        let rightHasJpg = viewModel.candidatePhoto?.hasExistingJpgFile() == true
        return leftHasJpg || rightHasJpg
    }

    private func canSelectRawForCurrentPair() -> Bool {
        let leftHasRaw = viewModel.mainPhoto?.hasExistingRawFile() == true
        let rightHasRaw = viewModel.candidatePhoto?.hasExistingRawFile() == true
        return leftHasRaw || rightHasRaw
    }

    private func show(pair: photoDisplayPair, source: displaySource, isLeft: Bool) {
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        let controller: photoMetalViewController = isLeft ? leftPhotoController : rightPhotoController
        let rotationDegrees = isLeft
            ? (viewModel.mainPhoto?.rotationDegrees ?? 0)
            : (viewModel.candidatePhoto?.rotationDegrees ?? 0)
        if case .image(let image) = selected {
            controller.load(image: image, rotationDegrees: rotationDegrees)
            return
        }

        if source == .raw, case .unavailable(let rawReason) = pair.raw {
            let side = isLeft ? "left" : "right"
            if case .image(let jpgImage) = pair.jpg {
                appFileLogger.log("RAW unavailable, fallback to JPG page=duplicate side=\(side) photoId=\(pair.photoId) reason=\(rawReason)", level: .warning)
                controller.load(image: jpgImage, rotationDegrees: rotationDegrees)
                return
            }
            appFileLogger.log("RAW unavailable and JPG unavailable page=duplicate side=\(side) photoId=\(pair.photoId) rawReason=\(rawReason) jpgReason=\(unavailableReason(pair.jpg))", level: .error)
        }

        if case .image(let jpgImage) = pair.jpg {
            controller.load(image: jpgImage, rotationDegrees: rotationDegrees)
            return
        }
        controller.showError("No image available")
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
        if source == .jpg, !canSelectJpgForCurrentPair() {
            appFileLogger.log("JPG selection rejected page=duplicate reason=noJpgFileInPair", level: .warning)
            updateSourceControlAvailability()
            return
        }
        if source == .raw, !canSelectRawForCurrentPair() {
            appFileLogger.log("RAW selection rejected page=duplicate reason=noRawFileInPair", level: .warning)
            updateSourceControlAvailability()
            return
        }
        sourceStore.current = source
        loadPhotos()
    }

    @objc private func rotateLeftClicked() {
        rotateCurrentPair(direction: .left, actionName: "rotateLeft")
    }

    @objc private func rotateRightClicked() {
        rotateCurrentPair(direction: .right, actionName: "rotateRight")
    }

    private func rotateCurrentPair(direction: photoRotationDirection, actionName: String) {
        let left = viewModel.mainPhoto
        let right = viewModel.candidatePhoto
        guard left != nil || right != nil else { return }

        let oldLeftRotation = left?.rotationDegrees
        let oldRightRotation = right?.rotationDegrees
        let targetLeftRotation = oldLeftRotation.map { rotatedDegrees($0, direction: direction) }
        let targetRightRotation = oldRightRotation.map { rotatedDegrees($0, direction: direction) }

        do {
            _ = try viewModel.rotateCurrentPair(direction: direction)
            loadPhotos()
        } catch {
            let leftId = left?.photoId ?? ""
            let rightId = right?.photoId ?? ""
            let oldLeft = oldLeftRotation.map(String.init) ?? ""
            let targetLeft = targetLeftRotation.map(String.init) ?? ""
            let oldRight = oldRightRotation.map(String.init) ?? ""
            let targetRight = targetRightRotation.map(String.init) ?? ""
            appFileLogger.log("operation failed page=duplicate action=\(actionName) leftPhotoId=\(leftId) rightPhotoId=\(rightId) oldLeftRotation=\(oldLeft) targetLeftRotation=\(targetLeft) oldRightRotation=\(oldRight) targetRightRotation=\(targetRight) error=\(error.localizedDescription)", level: .error)
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = viewModel.mainPhoto else { return }

        // 若当前仅剩这两张照片（或更少），无需选择模板，直接保留并结束
        if viewModel.photos.count <= 2 {
            do {
                let result = try viewModel.keepBoth(templatePhotoId: left.photoId)
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Select template photo"
        alert.informativeText = "Which photo should be the template for this group?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Left")
        alert.addButton(withTitle: "Right")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                let result = try viewModel.keepBoth(templatePhotoId: left.photoId)
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        } else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
            do {
                let result = try viewModel.keepBoth(templatePhotoId: right.photoId)
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
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

    private func zoomBothIn() {
        leftPhotoController.zoomIn()
        rightPhotoController.zoomIn()
    }

    private func zoomBothOut() {
        leftPhotoController.zoomOut()
        rightPhotoController.zoomOut()
    }

    private func resetBothZoom() {
        leftPhotoController.resetZoom()
        rightPhotoController.resetZoom()
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            do {
                let result = try viewModel.keepLeft()
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        case 124: // Right arrow
            do {
                let result = try viewModel.keepRight()
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        default:
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoomBothIn()
            case "-": zoomBothOut()
            case "r", "R": resetBothZoom()
            default: super.keyDown(with: event)
            }
        }
    }
}
