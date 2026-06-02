/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 实现 AppKit 起始页、文件夹选择入口和仅接受文件夹的拖拽校验
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

public final class startViewController: NSViewController {
    public var onFolderSelected: ((URL) -> Void)?
    private let validator = folderDropValidator()

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let button = NSButton(title: "+\nclick to choose a folder or drag it here", target: self, action: #selector(chooseFolder))
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 18)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            button.heightAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
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
