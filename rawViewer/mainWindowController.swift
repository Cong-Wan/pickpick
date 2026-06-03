/*
Author: wilbur
Version: 1.2
Date: 2026-06-03
Description: 修复零参数初始化器继承歧义导致的 window 为 nil 问题
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
    public private(set) var records: [photoItem] = []
    public private(set) var selectedGroup: photoGroup?
    public private(set) var currentFolderUrl: URL?
    public var analyzer: photoAnalyzerBridge

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
        showStart()
    }

    public override init(window: NSWindow?) {
        self.analyzer = photoAnalyzerBridge()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.analyzer = photoAnalyzerBridge()
        super.init(coder: coder)
    }

    public func showStart() {
        screenState = .start
        selectedGroup = nil
        let controller = startViewController()
        controller.onFolderSelected = { [weak self] url in
            self?.startAnalysis(folderUrl: url)
        }
        window?.contentViewController = controller
        window?.makeKeyAndOrderFront(nil)
        NSLog("🔥 showStart done, window.isVisible=%@", window?.isVisible ?? false ? "YES" : "NO")
    }

    public func startAnalysis(folderUrl: URL) {
        currentFolderUrl = folderUrl
        screenState = .progress
        let progressController = progressViewController()
        window?.contentViewController = progressController
        Task { @MainActor in
            do {
                if FileManager.default.fileExists(atPath: folderUrl.appendingPathComponent(".cache/analysis.json").path) {
                    showGroups(records: try analyzer.loadAnalysisResult(folderUrl: folderUrl))
                    return
                }
                _ = try await analyzer.startAnalysis(folderUrl: folderUrl, configUrl: folderUrl.appendingPathComponent("config.yaml")) { progress in
                    progressController.update(progress: progress)
                }
                showGroups(records: try analyzer.loadAnalysisResult(folderUrl: folderUrl))
            } catch {
                showError(message: error.localizedDescription)
            }
        }
    }

    public func showGroups(records: [photoItem]) {
        self.records = records
        screenState = .groups
        let controller = groupGridViewController(groups: makeVisiblePhotoGroups(from: records))
        controller.onSelectGroup = { [weak self] group in
            self?.showGroup(group: group)
        }
        window?.contentViewController = controller
    }

    public func showGroup(group: photoGroup) {
        selectedGroup = group
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        if group.kind.isDuplicate {
            screenState = .duplicateCompare
            window?.contentViewController = duplicateCompareViewController(group: group, store: store)
        } else {
            screenState = .browser
            window?.contentViewController = photoBrowserViewController(group: group, store: store)
        }
    }

    public func showError(message: String) {
        screenState = .error(message)
        setContent(title: message)
    }

    private func setContent(title: String) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .center
        label.font = .systemFont(ofSize: 24, weight: .medium)

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        window?.contentViewController = NSViewController()
        window?.contentViewController?.view = view
    }
}
