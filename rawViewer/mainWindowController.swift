/*
Author: wilbur
Version: 2.0
Date: 2026-06-06
Description: 窗口控制器，仅负责窗口创建/菜单/生命周期管理；数据和路由逻辑全部转交 appCoordinator
*/

import AppKit

public enum windowScreenState: Equatable {
    case start
    case progress
    case groups
    case browser
    case duplicateCompare
    case error(String)
}

public final class mainWindowController: NSWindowController {
    public private(set) var screenState: windowScreenState = .start
    public var analyzer: photoAnalyzerBridge
    private var coordinator: appCoordinator?

    public convenience init() {
        self.init(analyzer: photoAnalyzerBridge())
    }

    public convenience init(analyzer: photoAnalyzerBridge = photoAnalyzerBridge()) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "rawViewer"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        self.init(window: window)
        self.analyzer = analyzer
        NSLog("🔥 mainWindowController init done, window=%@", window)

        let coord = appCoordinator(window: window, analyzer: analyzer)
        self.coordinator = coord
        coord.showStart()
    }

    public override init(window: NSWindow?) {
        self.analyzer = photoAnalyzerBridge()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.analyzer = photoAnalyzerBridge()
        super.init(coder: coder)
    }

    // 以下方法保留为向后兼容入口，实际转发到 coordinator

    public func showStart() {
        coordinator?.showStart()
    }

    public func startAnalysis(folderUrl: URL) {
        coordinator?.startAnalysis(folderUrl: folderUrl)
    }

    public func showGroups(records newRecords: [photoItem]) {
        coordinator?.showGroups()
    }

    public func showGroup(group: photoGroup) {
        coordinator?.navigateToGroup(group)
    }

    public func showError(message: String) {
        coordinator?.showError(message: message)
    }
}
