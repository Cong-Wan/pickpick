/*
Author: wilbur
Version: 1.5
Date: 2026-06-24
Description: Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；修正顶部坐标渲染下的向上拖拽方向；新增图片区域顶部文件名栏；新增 contentTopAnchor 锚点供外部按钮紧贴文件名栏下方布局
*/

import AppKit
import CoreImage

public final class photoMetalViewController: NSViewController {
    private let metalView = metalPhotoView()
    private let fileNameBar = NSView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var fileNameBarHeightConstraint: NSLayoutConstraint?
    private var panOffset: CGPoint = .zero

    public private(set) var hasImage: Bool = false

    public var currentZoom: Double { metalView.currentZoom }

    /// 图片区顶部锚点（fileNameBar 底部），供外部按钮紧贴文件名栏下方布局。
    /// fileNameBar 高度随 setDisplayName 动态变化（有名字 30、无名字 0），用此锚点可避免固定偏移导致悬空。
    public var contentTopAnchor: NSLayoutYAxisAnchor { fileNameBar.bottomAnchor }

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

        fileNameBar.wantsLayer = true
        fileNameBar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        fileNameBar.isHidden = true
        fileNameBar.translatesAutoresizingMaskIntoConstraints = false

        fileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.alignment = .center
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.maximumNumberOfLines = 1
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        metalView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        fileNameBar.addSubview(fileNameLabel)
        container.addSubview(fileNameBar)
        container.addSubview(metalView)
        container.addSubview(errorLabel)

        let heightConstraint = fileNameBar.heightAnchor.constraint(equalToConstant: 0)
        fileNameBarHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            fileNameBar.topAnchor.constraint(equalTo: container.topAnchor),
            fileNameBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fileNameBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heightConstraint,

            fileNameLabel.centerYAnchor.constraint(equalTo: fileNameBar.centerYAnchor),
            fileNameLabel.leadingAnchor.constraint(equalTo: fileNameBar.leadingAnchor, constant: 12),
            fileNameLabel.trailingAnchor.constraint(equalTo: fileNameBar.trailingAnchor, constant: -12),

            metalView.topAnchor.constraint(equalTo: fileNameBar.bottomAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: metalView.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: metalView.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: metalView.trailingAnchor, constant: -24)
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        container.addGestureRecognizer(pan)

        view = container
    }

    // MARK: - 状态 API

    public func setDisplayName(_ name: String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fileNameLabel.stringValue = trimmedName
        let shouldShowName = !trimmedName.isEmpty
        fileNameBar.isHidden = !shouldShowName
        fileNameBarHeightConstraint?.constant = shouldShowName ? 30 : 0
    }

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
        setDisplayName(nil)
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
            panOffset.y -= translation.y
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
