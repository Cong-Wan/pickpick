/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；新增展示旋转角度传递
*/

import AppKit
import CoreImage

public final class photoMetalViewController: NSViewController {
    private let metalView = metalPhotoView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var panOffset: CGPoint = .zero

    public private(set) var hasImage: Bool = false

    public var currentZoom: Double { metalView.currentZoom }

    public var onZoomChanged: ((Double) -> Void)? {
        get { metalView.onZoomChanged }
        set { metalView.onZoomChanged = newValue }
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    public override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        metalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(metalView)

        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        container.addGestureRecognizer(pan)

        view = container
    }

    // MARK: - 状态 API

    public func load(image: CIImage?, rotationDegrees: Int = 0) {
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        if let image {
            metalView.setImage(image, rotationDegrees: rotationDegrees)
            hasImage = true
        } else {
            metalView.clearImage()
            hasImage = false
        }
    }

    public func reset() {
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        metalView.clearImage()
        metalView.resetZoom()
        metalView.resetPan()
        panOffset = .zero
        hasImage = false
    }

    public func showError(_ message: String) {
        metalView.showError(message)
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        hasImage = false
    }

    // MARK: - 缩放

    public func zoomIn() { metalView.zoomIn() }
    public func zoomOut() { metalView.zoomOut() }
    public func resetZoom() {
        metalView.resetZoom()
        panOffset = .zero
        metalView.setPanOffset(.zero)
    }

    // MARK: - Pan

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: view)
            panOffset.x += translation.x
            panOffset.y += translation.y
            gesture.setTranslation(.zero, in: view)
            metalView.setPanOffset(panOffset)
        default:
            break
        }
    }

    // MARK: - Key events

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "r", "R": resetZoom()
        default: super.keyDown(with: event)
        }
    }
}
