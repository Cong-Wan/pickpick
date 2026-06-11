/*
Author: wilbur
Version: 1.4
Date: 2026-06-10
Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC；持有 trashService 实例并注入到各 ViewModel；加载 records 后自动调用 trashService 清理已标记为 trash 的照片文件。v1.3: 迁移至 photoAnalyzing 协议，使用 analysisStore 替代直接文件操作
*/

import AppKit

public protocol appCoordinating: AnyObject {
    var records: [photoItem] { get }
    var groups: [photoGroup] { get }
    func reloadData() throws
    func showStart()
    func showGroups()
    func showBrowser(group: photoGroup)
    func showDuplicate(group: photoGroup)
}

public final class appCoordinator: appCoordinating {
    public private(set) var records: [photoItem] = []
    public private(set) var groups: [photoGroup] = []
    public private(set) var screenState: windowScreenState = .start

    private weak var window: NSWindow?
    private let analyzer: photoAnalyzing
    private let imageService: photoImageService
    private let trashService: photoTrashServicing
    public private(set) var currentFolderUrl: URL?

    public init(window: NSWindow, analyzer: photoAnalyzing, imageService: photoImageService = photoImageService(), trashService: photoTrashServicing = photoTrashService()) {
        self.window = window
        self.analyzer = analyzer
        self.imageService = imageService
        self.trashService = trashService
    }

    public func startAnalysis(folderUrl: URL) {
        currentFolderUrl = folderUrl
        screenState = .progress

        let progressController = progressViewController()
        window?.contentViewController = progressController

        Task { @MainActor in
            do {
                if analysisStore.shared.hasResults(for: folderUrl) {
                    do {
                        let loadedRecords = try analyzer.loadRecords(folderUrl: folderUrl)
                        self.records = loadedRecords
                        self.trashService.cleanupTrashedPhotos(self.records)
                        self.showGroups()
                        return
                    } catch {
                        appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
                    }
                }
                _ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
                    Task { @MainActor in
                        progressController.update(progress: progress)
                    }
                }
                self.records = try analyzer.loadRecords(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
            } catch {
                self.screenState = .error(error.localizedDescription)
                self.showError(message: error.localizedDescription)
            }
        }
    }

    public func reloadData() throws {
        guard let folderUrl = currentFolderUrl else { return }
        records = try analyzer.loadRecords(folderUrl: folderUrl)
        groups = makeVisiblePhotoGroups(from: records)
    }

    public func showStart() {
        screenState = .start
        records = []
        groups = []
        currentFolderUrl = nil

        let controller = startViewController()
        controller.onFolderSelected = { [weak self] url in
            self?.startAnalysis(folderUrl: url)
        }
        window?.contentViewController = controller
    }

    public func showGroups() {
        groups = makeVisiblePhotoGroups(from: records)
        screenState = .groups

        let viewModel = groupGridViewModel(groups: groups)
        let controller = groupGridViewController(viewModel: viewModel, imageService: imageService)
        controller.onBack = { [weak self] in
            self?.showStart()
        }
        controller.onSelectGroup = { [weak self] group in
            self?.navigateToGroup(group)
        }
        window?.contentViewController = controller
    }

    private func reloadDataIgnoringError() {
        do {
            try reloadData()
        } catch {
            appDebugLogger.log("reloadData failed: \(error.localizedDescription)")
        }
    }

    public func showBrowser(group: photoGroup) {
        screenState = .browser
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        let viewModel = photoBrowserViewModel(
            photos: group.photos,
            store: store,
            trashService: trashService,
            displaySource: displaySourceStore().current
        )
        let browser = photoBrowserViewController(viewModel: viewModel, imageService: imageService)
        browser.onBack = { [weak self] in
            guard let self else { return }
            self.reloadDataIgnoringError()
            self.showGroups()
        }
        window?.contentViewController = browser
    }

    public func showDuplicate(group: photoGroup) {
        screenState = .duplicateCompare
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        let viewModel = duplicateCompareViewModel(photos: group.photos, store: store, trashService: trashService)
        let duplicate = duplicateCompareViewController(viewModel: viewModel, imageService: imageService)
        duplicate.onBack = { [weak self] in
            guard let self else { return }
            self.reloadDataIgnoringError()
            self.showGroups()
        }
        duplicate.onFinished = { [weak self] in
            guard let self = self else { return }
            do {
                try self.reloadData()
            } catch {
                // reloadData 失败时仍尝试 showGroups，用内存中的旧数据
            }
            self.showGroups()
        }
        window?.contentViewController = duplicate
    }

    public func showError(message: String) {
        screenState = .error(message)
        let label = NSTextField(labelWithString: message)
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
        let controller = NSViewController()
        controller.view = view
        window?.contentViewController = controller
    }

    func navigateToGroup(_ group: photoGroup) {
        if group.kind.isDuplicate {
            showDuplicate(group: group)
        } else {
            showBrowser(group: group)
        }
    }
}
