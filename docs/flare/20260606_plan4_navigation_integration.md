# Navigation + BUG 修复 + 集成 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]` syntax for tracking.

**Goal:** 新建 appCoordinator 作为数据和导航单一来源，修复 Duplicate 完成后分组不消失 (BUG4) 和切图全量刷新 (BUG2)，集成 photoMetalViewController 到浏览器和 Duplicate 对比页，删除 metalPhotoView 兼容方法

**Architecture:** appCoordinator 持有 records/groups，管理 screenState 状态机，Duplicate 完成后 reloadData() 重新从磁盘读取 JSON。photoBrowserViewController 和 duplicateCompareViewController 改用 photoMetalViewController 替代直接使用 metalPhotoView，loadCurrentPhoto 时调用 reset() 清空 zoom/pan。

**Tech Stack:** Swift, AppKit

**Depends on:** Plan 2（photoMetalViewController）+ Plan 3（photoThumbnailView 新接口）

---

### Task 1: Add clearReviewGroupId to jsonReviewStateStore

**Goal:** jsonReviewStateStore 新增 clearReviewGroupId(photoId:) 方法，将 JSON 中对应 photo 的 reviewGroupId 设为空字符串

**Files touched:**

- `rawViewer/jsonReviewStateStore.swift` — 新增 clearReviewGroupId 方法

------

#### Step 1 — Implement

在 `jsonReviewStateStore` 类中 `setTemplate` 方法之后新增：

```swift
    public func clearReviewGroupId(photoId: String) throws {
        try updateJson { photos in
            guard var photo = photos[photoId] as? [String: Any] else { return }
            photo["review_group_id"] = ""
            photos[photoId] = photo
        }
    }
```

同时在 `jsonReviewStateStoring` 协议中新增该方法声明：

```swift
public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
}
```

------

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 2: Fix duplicateCompareViewModel markFinalKept

**Goal:** markFinalKept 在 setTemplate 后调用 store.clearReviewGroupId，使 surviving 照片从 duplicate 分组中移出

**Files touched:**

- `rawViewer/duplicateCompareViewModel.swift` — markFinalKept 新增 clearReviewGroupId 调用

------

#### Step 1 — Implement

将 `markFinalKept` 方法改为：

```swift
    private func markFinalKept(_ photo: photoItem) throws {
        try store.mark(photoId: photo.photoId, status: .kept)
        if !photo.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
            try store.clearReviewGroupId(photoId: photo.photoId)
        }
    }
```

------

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 3: Fix makeVisiblePhotoGroups duplicate filter

**Goal:** makeVisiblePhotoGroups 中 duplicate 分组仅包含 reviewGroupId 非空的照片，由于 markFinalKept 已清空 surviving 照片的 reviewGroupId，它们自动落入 normal 过滤条件

**Files touched:**

- `rawViewer/photoModels.swift` — makeVisiblePhotoGroups 中 normal 过滤条件修改

------

#### Step 1 — Implement

当前 `normal` 过滤条件为：

```swift
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" }, into: &groups)
```

需修改为同时包含 reviewGroupId 为空的条件（确保已被清空的 surviving 照片正确归入 normal）：

```swift
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)
```

同时，duplicate 分组过滤也应确保只包含 reviewGroupId 仍非空的照片（已有此逻辑，因为 filter 条件是 `$0.reviewGroupId == reviewGroupId`，被清空的照片自然不在其中）。

但需要额外处理一种情况：reviewGroupId 非空但已被标记为 kept 且 reviewGroupId 清空的照片 — 它们已经通过 `clearReviewGroupId` 清空了 reviewGroupId，所以 `reviewGroupId.isEmpty` 为 true，会落入 normal。这是正确的行为。

然而，那些 `reviewGroupId` 非空、`reviewStatus` 仍为 `active` 的照片，同时 `exposureStatus == "normal"` 且 `!isBlurry` 的，不应该同时出现在 normal 分组和 duplicate 分组。当前逻辑中，如果一个照片 `reviewGroupId` 非空且 `exposureStatus == "normal"`，它会同时出现在 normal 和 duplicate 分组。

修复：normal 分组应排除 reviewGroupId 非空的照片：

```swift
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)
```

同样，overexposed/underexposed/blurry 分组也应排除 reviewGroupId 非空的照片（它们应该只出现在 duplicate 分组中）：

```swift
    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter { $0.isBlurry && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)
```

完整修改后的函数：

```swift
public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter { $0.isBlurry && $0.reviewGroupId.isEmpty }, into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)

    let duplicateGroupIds = Array(Set(visiblePhotos.map(\.reviewGroupId).filter { !$0.isEmpty })).sorted()
    for reviewGroupId in duplicateGroupIds {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}
```

------

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 4: Create appCoordinator + Refactor mainWindowController

**Goal:** 新建 appCoordinator 作为数据和导航单一来源，Duplicate 完成后 reloadData() 重新从磁盘读取 JSON。mainWindowController 将数据和路由逻辑全部转交 coordinator

**Files touched:**

- `rawViewer/appCoordinator.swift` — 导航协调器（新建）
- `rawViewer/mainWindowController.swift` — 数据逻辑移出，转交 coordinator

------

#### Step 1 — Implement appCoordinator

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC
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
    private let analyzer: photoAnalyzerBridge
    private let imageService: photoImageService
    public private(set) var currentFolderUrl: URL?

    public init(window: NSWindow, analyzer: photoAnalyzerBridge, imageService: photoImageService = photoImageService()) {
        self.window = window
        self.analyzer = analyzer
        self.imageService = imageService
    }

    public func startAnalysis(folderUrl: URL) {
        currentFolderUrl = folderUrl
        screenState = .progress

        let progressController = progressViewController()
        window?.contentViewController = progressController

        Task { @MainActor in
            do {
                if FileManager.default.fileExists(atPath: folderUrl.appendingPathComponent(".cache/analysis.json").path) {
                    let loadedRecords = try analyzer.loadAnalysisResult(folderUrl: folderUrl)
                    self.records = loadedRecords
                    self.showGroups()
                    return
                }
                _ = try await analyzer.startAnalysis(folderUrl: folderUrl, configUrl: folderUrl.appendingPathComponent("config.yaml")) { progress in
                    progressController.update(progress: progress)
                }
                self.records = try analyzer.loadAnalysisResult(folderUrl: folderUrl)
                self.showGroups()
            } catch {
                self.screenState = .error(error.localizedDescription)
                self.showError(message: error.localizedDescription)
            }
        }
    }

    public func reloadData() throws {
        guard let folderUrl = currentFolderUrl else { return }
        records = try analyzer.loadAnalysisResult(folderUrl: folderUrl)
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

    public func showBrowser(group: photoGroup) {
        screenState = .browser
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        let viewModel = photoBrowserViewModel(
            photos: group.photos,
            store: store,
            displaySource: displaySourceStore().current
        )
        let browser = photoBrowserViewController(viewModel: viewModel, imageService: imageService)
        browser.onBack = { [weak self] in
            self?.showGroups()
        }
        window?.contentViewController = browser
    }

    public func showDuplicate(group: photoGroup) {
        screenState = .duplicateCompare
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        let viewModel = duplicateCompareViewModel(photos: group.photos, store: store)
        let duplicate = duplicateCompareViewController(viewModel: viewModel, imageService: imageService)
        duplicate.onBack = { [weak self] in
            self?.showGroups()
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

    private func navigateToGroup(_ group: photoGroup) {
        if group.kind.isDuplicate {
            showDuplicate(group: group)
        } else {
            showBrowser(group: group)
        }
    }
}
```

------

#### Step 2 — Rewrite mainWindowController

```swift
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
```

------

#### Step 3 — Verify compilation

将 `appCoordinator.swift` 添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 5: Integrate photoMetalViewController into browser + duplicate VC

**Goal:** photoBrowserViewController 和 duplicateCompareViewController 改用 photoMetalViewController 替代直接使用 metalPhotoView；loadCurrentPhoto 时先调用 reset() 清空 zoom/pan；删除 metalPhotoView 中的兼容方法

**Files touched:**

- `rawViewer/photoBrowserViewController.swift` — 嵌入 photoMetalViewController
- `rawViewer/duplicateCompareViewController.swift` — 嵌入 photoMetalViewController
- `rawViewer/metalPhotoView.swift` — 删除 loadPhoto/loadJpgCompat/loadRawCompat/jpgFallbackUrl

------

#### Step 1 — Rewrite photoBrowserViewController

```swift
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

    public convenience init(group: photoGroup, store: jsonReviewStateStoring, imageService: photoImageService = photoImageService()) {
        let initialSource = displaySourceStore().current
        let viewModel = photoBrowserViewModel(photos: group.photos, store: store, displaySource: initialSource)
        self.init(viewModel: viewModel, imageService: imageService)
        self.groupTitle = group.kind.title
    }

    required init?(coder: NSCoder) {
        self.viewModel = photoBrowserViewModel(photos: [], store: jsonReviewStateStore())
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

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        let source: displaySource = (sender.selectedSegment == 0) ? .jpg : .raw
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
                print("Delete failed: \(error)")
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
```

------

#### Step 2 — Rewrite duplicateCompareViewController

```swift
/*
Author: wilbur
Version: 3.0
Date: 2026-06-06
Description: 重复照片双图比较界面，使用 photoMetalViewController 替代直接 metalPhotoView；loadPhotos 时先 reset() 两个 controller
*/

import AppKit
import CoreImage

public final class duplicateCompareViewController: NSViewController {
    public let viewModel: duplicateCompareViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public var onFinished: (() -> Void)?

    private let sourceStore = displaySourceStore()
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
        self.viewModel = duplicateCompareViewModel(photos: [], store: jsonReviewStateStore())
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

        let sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: self, action: #selector(sourceChanged(_:)))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(keepBothBtn)
        toolbar.addSubview(sourceControl)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
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

        if let left = viewModel.mainPhoto {
            let photoId = left.photoId
            leftLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: left)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.mainPhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: true)
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
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: false)
                }
            }
        }
    }

    private func show(pair: photoDisplayPair, source: displaySource, isLeft: Bool) {
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        let controller = isLeft ? leftPhotoController : rightPhotoController
        if case .image(let image) = selected {
            controller.load(image: image)
            return
        }
        if case .image(let jpgImage) = pair.jpg {
            controller.load(image: jpgImage)
            return
        }
        controller.showError("No image available")
    }

    @objc private func backClicked() {
        onBack?()
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        sourceStore.current = (sender.selectedSegment == 0) ? .jpg : .raw
        loadPhotos()
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = viewModel.mainPhoto else { return }
        let alert = NSAlert()
        alert.messageText = "Select template photo"
        alert.informativeText = "Which photo should be the template for this group?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Left")
        alert.addButton(withTitle: "Right")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = try? viewModel.keepBoth(templatePhotoId: left.photoId)
            handleActionResult(.finished)
        } else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
            _ = try? viewModel.keepBoth(templatePhotoId: right.photoId)
            handleActionResult(.finished)
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

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            if let result = try? viewModel.keepLeft() {
                handleActionResult(result)
            }
        case 124: // Right arrow
            if let result = try? viewModel.keepRight() {
                handleActionResult(result)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
```

------

#### Step 3 — Clean up metalPhotoView compat methods

在 `metalPhotoView.swift` 中删除以下方法和属性：

1. 删除 `loadPhoto(url:source:)` 方法
2. 删除 `jpgFallbackUrl(from:)` 方法
3. 删除 `loadJpgCompat(url:)` 方法
4. 删除 `loadRawCompat(url:)` 方法
5. 删除整个 `// MARK: - 兼容性 loadPhoto` 注释块

同时更新文件头版本和描述。

修改后的完整 `metalPhotoView.swift`：

```swift
/*
Author: wilbur
Version: 3.0
Date: 2026-06-06
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；每帧显式清空 drawable 防止残影
*/

import AppKit
import CoreImage
import MetalKit

public enum photoLoadError: Error, Equatable {
    case cannotLoadImage
    case missingDrawable
}

public enum photoSource {
    case jpg
    case raw
}

public final class metalPhotoView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?

    private var currentImage: CIImage?
    public private(set) var errorMessage: String?
    public private(set) var isShowingError: Bool = false

    private var userZoom: Double = 1.0
    private let minZoom: Double = 0.1
    private let maxZoom: Double = 10.0
    private let zoomStep: Double = 1.2
    private var pinchStartZoom: Double = 1.0
    private var panOffset: CGPoint = .zero

    public var onZoomChanged: ((Double) -> Void)?

    public init(frame frameRect: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(frame: frameRect, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        setupGestures()
    }

    required init(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(coder: coder)
        self.device = device
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        setupGestures()
    }

    private func setupGestures() {
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = userZoom
        case .changed, .ended:
            let newZoom = max(minZoom, min(maxZoom, pinchStartZoom * Double(gesture.magnification)))
            userZoom = newZoom
            needsDisplay = true
            onZoomChanged?(userZoom)
        default:
            break
        }
    }

    // MARK: - 状态只读属性

    public var hasImage: Bool { currentImage != nil }
    public var currentZoom: Double { userZoom }

    // MARK: - 状态切换 API

    public func setImage(_ image: CIImage?) {
        currentImage = image
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func clearImage() {
        currentImage = nil
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func showError(_ message: String) {
        currentImage = nil
        errorMessage = message
        isShowingError = true
        needsDisplay = true
    }

    // MARK: - 缩放

    public func zoomIn() {
        userZoom = max(minZoom, min(maxZoom, userZoom * zoomStep))
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    public func zoomOut() {
        userZoom = max(minZoom, min(maxZoom, userZoom / zoomStep))
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    public func resetZoom() {
        userZoom = 1.0
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    // MARK: - 平移

    public func setPanOffset(_ offset: CGPoint) {
        panOffset = offset
        needsDisplay = true
    }

    public func resetPan() {
        panOffset = .zero
        needsDisplay = true
    }

    // MARK: - 渲染

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }

        let target = drawable.texture
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)

        let clearPass = MTLRenderPassDescriptor()
        if let attachment = clearPass.colorAttachments[0] {
            attachment.texture = target
            attachment.loadAction = .clear
            attachment.storeAction = .store
            attachment.clearColor = clearColor
        }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) {
            encoder.endEncoding()
        }

        if let image = currentImage {
            let fitScale = min(Double(target.width) / image.extent.width, Double(target.height) / image.extent.height)
            let effectiveScale = fitScale * userZoom
            let width = image.extent.width * effectiveScale
            let height = image.extent.height * effectiveScale
            let x = (Double(target.width) - width) / 2 + panOffset.x
            let y = (Double(target.height) - height) / 2 + panOffset.y
            let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: effectiveScale, y: effectiveScale)
            ciContext.render(image.transformed(by: transform), to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "r", "R": resetZoom()
        default: super.keyDown(with: event)
        }
    }
}
```

------

#### Step 4 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过，app 可正常启动、选择文件夹、浏览分组、进入浏览器切图（zoom/pan 正常）、进入 Duplicate 对比（完成返回后分组消失）。
