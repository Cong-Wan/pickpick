/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 实现 AppKit 起始页、虚线文件夹选择区域、文件夹选择入口和仅接受文件夹的拖拽校验
*/

import AppKit

public struct folderDropValidator {
    public init() {}

    public func accepts(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}

public final class folderDropZoneView: NSView {
    private let shapeLayer = CAShapeLayer()
    private let plusLabel = NSTextField(labelWithString: "+")
    private let captionLabel = NSTextField(labelWithString: "Click to choose a folder")
    private let hintLabel = NSTextField(labelWithString: "or drag a folder here")

    public var onActivate: (() -> Void)?

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
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.lineDashPattern = [6, 4]
        shapeLayer.frame = bounds
        shapeLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(shapeLayer)

        plusLabel.font = .systemFont(ofSize: 48, weight: .light)
        plusLabel.textColor = .secondaryLabelColor
        plusLabel.alignment = .center
        plusLabel.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(plusLabel)
        addSubview(captionLabel)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            plusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            plusLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -28),

            captionLabel.topAnchor.constraint(equalTo: plusLabel.bottomAnchor, constant: 8),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    public override func layout() {
        super.layout()
        let inset: CGFloat = 1
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 12, yRadius: 12)
        shapeLayer.path = path.cgPath
    }

    @objc private func handleClick() {
        onActivate?()
    }
}

public final class startViewController: NSViewController {
    public var onFolderSelected: ((URL) -> Void)?
    private let validator = folderDropValidator()
    private let dropZone = folderDropZoneView()

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.onActivate = { [weak self] in
            self?.chooseFolder()
        }
        root.addSubview(dropZone)

        NSLayoutConstraint.activate([
            dropZone.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dropZone.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            dropZone.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            dropZone.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            dropZone.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            dropZone.heightAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])

        view = root
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, validator.accepts(url: url) {
            onFolderSelected?(url)
        }
    }
}
