# RAW 按钮可用性与本地日志修复实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复只有 JPG 或 RAW 文件缺失时 RAW 按钮仍可点击的问题，并为 RAW fallback 建立按天保存的本地文件日志。

**架构：** 增加一个独立的本地文件日志服务，在 `photoItem` 上集中定义 RAW 文件存在性判断，然后分别接入普通浏览器和重复对比页的 JPG/RAW segmented control。图片展示仍沿用现有 `photoImageService` 和静默 fallback 行为，只补充按钮可用性与日志记录。

**技术栈：** Swift、AppKit、Foundation、Xcode project file system synchronized root group、`xcodebuild`

---

## 前置约束

- 不使用任何测试框架。
- 不编排任何 Git 操作。
- 控制台调试输出只允许通过现有 `appDebugLogger` 的 `--debug` 参数控制。
- 本计划新增的 `appFileLogger` 是产品需要的本地文件日志，不属于控制台打印；它默认写文件，用于排查 RAW fallback。
- 计划执行期间每完成一个任务都必须运行对应验证命令，验证通过后才能进入下一个任务。

---

## 文件结构

将创建或修改以下文件：

- `rawViewer/services/appFileLogger.swift` — 新增本地文件日志服务，按天写入日志并保留最近 7 天。
- `rawViewer/models/photoModels.swift` — 增加 `photoItem.hasExistingRawFile(fileManager:)`，统一 RAW 文件存在性判断。
- `rawViewer/browser/photoBrowserViewController.swift` — 普通分组浏览器按当前照片 RAW 文件存在性禁用或启用 RAW segment，并在 RAW fallback 时写日志。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 重复图对比页按左右任意一侧 RAW 文件存在性禁用或启用 RAW segment，并在单侧 RAW fallback 时写日志。

无需修改 `rawViewer.xcodeproj/project.pbxproj`。当前工程使用 `PBXFileSystemSynchronizedRootGroup` 追踪 `rawViewer` 目录，新建 Swift 文件位于该目录下会被目标自动纳入编译。

---

### Task 1: 新增本地文件日志服务

**目标：** App 能把关键事件异步写入 `~/Library/Application Support/rawViewer/logs/YYYY-MM-DD.log`，并自动清理 7 天保留期之外的日志。

**涉及的文件：**

- `rawViewer/services/appFileLogger.swift` — 本地文件日志服务。

------

#### Step 1 — 实现

新建 `rawViewer/services/appFileLogger.swift`，写入完整内容：

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 通用本地文件日志服务，按天写入 Application Support/rawViewer/logs，并保留最近 7 天日志
*/

import Foundation

public enum appLogLevel: String {
    case info
    case warning
    case error
}

public enum appFileLogger {
    private static let queue = DispatchQueue(label: "rawViewer.appFileLogger")
    private static let fileManager = FileManager.default
    private static let retentionDays = 7
    private static var cleanupCompleted = false

    public static func log(_ message: String, level: appLogLevel = .info) {
        queue.async {
            write(message, level: level)
        }
    }

    private static func write(_ message: String, level: appLogLevel) {
        do {
            let directory = try logsDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !cleanupCompleted {
                cleanupOldLogs(in: directory)
                cleanupCompleted = true
            }

            let now = Date()
            let url = directory.appendingPathComponent(fileName(for: now))
            let line = "\(timestamp(for: now)) [\(level.rawValue)] \(message)\n"
            try append(line, to: url)
        } catch {
            appDebugLogger.log("appFileLogger failed: \(error.localizedDescription)")
        }
    }

    private static func logsDirectory() throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("rawViewer", isDirectory: true)
        .appendingPathComponent("logs", isDirectory: true)
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date)).log"
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func append(_ line: String, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func cleanupOldLogs(in directory: URL) {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            guard let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: todayStart) else {
                return
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"

            for url in urls where url.pathExtension == "log" {
                let baseName = url.deletingPathExtension().lastPathComponent
                guard let date = formatter.date(from: baseName), date < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        } catch {
            appDebugLogger.log("appFileLogger cleanup failed: \(error.localizedDescription)")
        }
    }
}
```

------

#### Step 2 — 运行验证

运行 Debug 构建，确认新增文件被 Xcode 目标自动编译：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过。
- 无 Swift 编译错误。
- 无 `appFileLogger` 相关符号缺失错误。

------

✅ **完成的标志：** Debug 构建通过，新增日志服务参与编译且没有异常。**在满足此条件之前不要开始下一个任务。**

------

### Task 2: 增加 RAW 文件存在性判断

**目标：** 任意 UI 层都可以通过同一个 `photoItem.hasExistingRawFile(fileManager:)` 判断 RAW 文件是否真实存在。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 增加 `photoItem` extension。

------

#### Step 1 — 实现

用下面完整内容替换 `rawViewer/models/photoModels.swift`：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-11
Description: 修复 makeVisiblePhotoGroups 中单张 orphan 重复分组的问题，让 photoItem 支持 Codable，并新增 RAW 文件存在性判断
*/

import Foundation

public enum displaySource: String, Codable, Equatable {
    case jpg
    case raw
}

public enum reviewStatus: String, Codable, Equatable {
    case active
    case kept
    case passed
    case trashed
}

public enum analysisPhase: String, Codable, Equatable {
    case scanning
    case exifReading
    case rawAnalysis
    case jpgAnalysis
    case duplicateGrouping
    case organizing
    case completed
}

public struct analysisProgress: Equatable {
    public var phase: analysisPhase
    public var completedCount: Int
    public var totalCount: Int
    public var overallProgress: Double

    public init(phase: analysisPhase, completedCount: Int, totalCount: Int, overallProgress: Double) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.overallProgress = overallProgress
    }
}

public struct dynamicRangeData: Codable, Equatable {
    public var sceneSpreadEv: Double
    public var codeRangeEv: Double
    public var blackLevel: Int
    public var whiteLevel: Int

    public init(sceneSpreadEv: Double, codeRangeEv: Double, blackLevel: Int, whiteLevel: Int) {
        self.sceneSpreadEv = sceneSpreadEv
        self.codeRangeEv = codeRangeEv
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
    }
}

public struct photoItem: Codable, Equatable, Identifiable {
    public var id: String { photoId }
    public var photoId: String
    public var jpgPath: String
    public var rawPath: String?
    public var isBlurry: Bool
    public var exposureStatus: String
    public var reviewStatus: reviewStatus
    public var reviewGroupId: String
    public var templatePhotoId: String
    public var analysisSource: String
    public var dynamicRange: dynamicRangeData?

    public init(
        photoId: String,
        jpgPath: String,
        rawPath: String? = nil,
        isBlurry: Bool = false,
        exposureStatus: String = "normal",
        reviewStatus: reviewStatus = .active,
        reviewGroupId: String = "",
        templatePhotoId: String = "",
        analysisSource: String = "",
        dynamicRange: dynamicRangeData? = nil
    ) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.reviewStatus = reviewStatus
        self.reviewGroupId = reviewGroupId
        self.templatePhotoId = templatePhotoId
        self.analysisSource = analysisSource
        self.dynamicRange = dynamicRange
    }
}

public extension photoItem {
    func hasExistingRawFile(fileManager: FileManager = .default) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        return fileManager.fileExists(atPath: rawPath)
    }
}

public enum photoGroupKind: Equatable {
    case overexposed
    case underexposed
    case blurry
    case normal
    case duplicate(reviewGroupId: String)

    public var title: String {
        switch self {
        case .overexposed: return "Overexposed"
        case .underexposed: return "Underexposed"
        case .blurry: return "Blurry"
        case .normal: return "Normal"
        case .duplicate(let reviewGroupId): return "Duplicate \(reviewGroupId)"
        }
    }

    public var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

public enum groupRoute: Equatable {
    case browser
    case duplicateCompare
}

public struct photoGroup: Equatable, Identifiable {
    public var id: String {
        switch kind {
        case .overexposed: return "overexposed"
        case .underexposed: return "underexposed"
        case .blurry: return "blurry"
        case .normal: return "normal"
        case .duplicate(let reviewGroupId): return "duplicate-\(reviewGroupId)"
        }
    }

    public var kind: photoGroupKind
    public var photos: [photoItem]

    public init(kind: photoGroupKind, photos: [photoItem]) {
        self.kind = kind
        self.photos = photos
    }
}

public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    let groupCounts = Dictionary(grouping: visiblePhotos, by: \.reviewGroupId)
        .filter { !$0.key.isEmpty }
        .mapValues { $0.count }
    let validDuplicateIds = Set(groupCounts.filter { $0.value >= 2 }.keys)

    func isInValidDuplicateGroup(_ photo: photoItem) -> Bool {
        !photo.reviewGroupId.isEmpty && validDuplicateIds.contains(photo.reviewGroupId)
    }

    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter { $0.isBlurry && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && !isInValidDuplicateGroup($0) }, into: &groups)

    for reviewGroupId in validDuplicateIds.sorted() {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}

private func appendGroup(_ kind: photoGroupKind, photos: [photoItem], into groups: inout [photoGroup]) {
    guard !photos.isEmpty else { return }
    groups.append(photoGroup(kind: kind, photos: photos))
}

public final class displaySourceStore {
    private let defaults: UserDefaults
    private let key = "rawViewer.displaySource"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var current: displaySource {
        get {
            guard let value = defaults.string(forKey: key), let source = displaySource(rawValue: value) else {
                return .jpg
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

public enum displayAvailability: Equatable {
    case available(URL)
    case unavailable
}

public func displayUrl(for photo: photoItem, source: displaySource) -> displayAvailability {
    switch source {
    case .jpg:
        return .available(URL(fileURLWithPath: photo.jpgPath))
    case .raw:
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else { return .unavailable }
        return .available(URL(fileURLWithPath: rawPath))
    }
}
```

------

#### Step 2 — 运行验证

运行 Debug 构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过。
- 无 `photoItem`、`FileManager`、`hasExistingRawFile` 相关编译错误。
- 现有调用 `makeVisiblePhotoGroups`、`displayUrl`、`displaySourceStore` 的代码仍能编译。

------

✅ **完成的标志：** Debug 构建通过，`photoItem.hasExistingRawFile(fileManager:)` 可被其他 Swift 文件引用。**在满足此条件之前不要开始下一个任务。**

------

### Task 3: 修复普通分组浏览器 RAW 按钮与 fallback 日志

**目标：** 普通浏览器中当前照片没有真实存在的 RAW 文件时，RAW segment 灰色；RAW 加载失败时静默回退 JPG 并写本地日志。

**涉及的文件：**

- `rawViewer/browser/photoBrowserViewController.swift` — 更新 RAW segment 可用性、source guard、fallback 日志。

------

#### Step 1 — 实现

用下面完整内容替换 `rawViewer/browser/photoBrowserViewController.swift`：

```swift
/*
Author: wilbur
Version: 3.1
Date: 2026-06-11
Description: 浏览器控制器，按当前照片 RAW 文件存在性禁用 RAW segment，并在 RAW fallback 时写入本地日志
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

    public convenience init(group: photoGroup, store: jsonReviewStateStoring, trashService: photoTrashServicing = photoTrashService(), imageService: photoImageService = photoImageService()) {
        let initialSource = displaySourceStore().current
        let viewModel = photoBrowserViewModel(photos: group.photos, store: store, trashService: trashService, displaySource: initialSource)
        self.init(viewModel: viewModel, imageService: imageService)
        self.groupTitle = group.kind.title
    }

    required init?(coder: NSCoder) {
        self.viewModel = photoBrowserViewModel(photos: [], store: jsonReviewStateStore(), trashService: photoTrashService())
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

        thumbnailView = photoThumbnailView(photos: viewModel.photos, imageService: imageService)
        thumbnailView.delegate = self
        thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
        thumbnailView.setCurrentIndex(viewModel.currentIndex)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 150)
        ])

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
        updateSourceControlAvailability()

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

    private func updateSourceControlAvailability() {
        guard let photo = viewModel.currentPhoto else {
            sourceControl.setEnabled(false, forSegment: 1)
            sourceControl.selectedSegment = 0
            return
        }

        let hasRaw = photo.hasExistingRawFile()
        sourceControl.setEnabled(hasRaw, forSegment: 1)

        if !hasRaw, viewModel.displaySource == .raw {
            appFileLogger.log("RAW source unavailable, switching to JPG page=browser photoId=\(photo.photoId)", level: .warning)
            displaySourceStore().current = .jpg
            viewModel.setDisplaySource(.jpg)
        }
        sourceControl.selectedSegment = viewModel.displaySource == .jpg ? 0 : 1
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

        if source == .raw, case .unavailable(let rawReason) = pair.raw {
            if case .image(let jpgImage) = pair.jpg {
                appFileLogger.log("RAW unavailable, fallback to JPG page=browser photoId=\(pair.photoId) reason=\(rawReason)", level: .warning)
                mainPhotoController.load(image: jpgImage)
                return
            }
            appFileLogger.log("RAW unavailable and JPG unavailable page=browser photoId=\(pair.photoId) rawReason=\(rawReason) jpgReason=\(unavailableReason(pair.jpg))", level: .error)
        }

        if case .image(let jpgImage) = pair.jpg {
            mainPhotoController.load(image: jpgImage)
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
        if source == .raw, viewModel.currentPhoto?.hasExistingRawFile() != true {
            let photoId = viewModel.currentPhoto?.photoId ?? "none"
            appFileLogger.log("RAW selection rejected page=browser photoId=\(photoId) reason=rawFileUnavailable", level: .warning)
            sender.selectedSegment = 0
            displaySourceStore().current = .jpg
            if viewModel.displaySource != .jpg {
                viewModel.setDisplaySource(.jpg)
            }
            return
        }
        displaySourceStore().current = source
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
                showErrorAlert(message: error.localizedDescription)
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            viewModel.moveNext()
            thumbnailView.setCurrentIndex(viewModel.currentIndex)
            loadCurrentPhoto()
        case 126:
            viewModel.movePrevious()
            thumbnailView.setCurrentIndex(viewModel.currentIndex)
            loadCurrentPhoto()
        case 51:
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

#### Step 2 — 运行验证

运行 Debug 构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过。
- 无 `sourceControl.setEnabled`、`hasExistingRawFile`、`appFileLogger` 相关编译错误。
- 普通浏览器仍能实例化并编译通过。

------

✅ **完成的标志：** Debug 构建通过，普通浏览器 RAW segment 逻辑编译通过。**在满足此条件之前不要开始下一个任务。**

------

### Task 4: 修复重复对比页 RAW 按钮与单侧 fallback 日志

**目标：** 重复对比页中左右任意一侧有真实存在的 RAW 文件时 RAW segment 可点击，两侧都没有 RAW 时灰色；单侧 RAW 加载失败时静默回退 JPG 并写本地日志。

**涉及的文件：**

- `rawViewer/duplicate/duplicateCompareViewController.swift` — 将 `sourceControl` 提升为属性，更新 RAW 可用性和 fallback 日志。

------

#### Step 1 — 实现

用下面完整内容替换 `rawViewer/duplicate/duplicateCompareViewController.swift`：

```swift
/*
Author: wilbur
Version: 3.2
Date: 2026-06-11
Description: 重复照片双图比较界面，按左右任意一侧 RAW 文件存在性控制 RAW segment，并在单侧 RAW fallback 时写入本地日志
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

    private func updateSourceControlAvailability() {
        let canSelectRaw = canSelectRawForCurrentPair()
        sourceControl.setEnabled(canSelectRaw, forSegment: 1)
        if !canSelectRaw, sourceStore.current == .raw {
            appFileLogger.log("RAW source unavailable, switching to JPG page=duplicate", level: .warning)
            sourceStore.current = .jpg
        }
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
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
        if case .image(let image) = selected {
            controller.load(image: image)
            return
        }

        if source == .raw, case .unavailable(let rawReason) = pair.raw {
            let side = isLeft ? "left" : "right"
            if case .image(let jpgImage) = pair.jpg {
                appFileLogger.log("RAW unavailable, fallback to JPG page=duplicate side=\(side) photoId=\(pair.photoId) reason=\(rawReason)", level: .warning)
                controller.load(image: jpgImage)
                return
            }
            appFileLogger.log("RAW unavailable and JPG unavailable page=duplicate side=\(side) photoId=\(pair.photoId) rawReason=\(rawReason) jpgReason=\(unavailableReason(pair.jpg))", level: .error)
        }

        if case .image(let jpgImage) = pair.jpg {
            controller.load(image: jpgImage)
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
        if source == .raw, !canSelectRawForCurrentPair() {
            appFileLogger.log("RAW selection rejected page=duplicate reason=noRawFileInPair", level: .warning)
            sender.selectedSegment = 0
            sourceStore.current = .jpg
            return
        }
        sourceStore.current = source
        loadPhotos()
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = viewModel.mainPhoto else { return }

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

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            do {
                let result = try viewModel.keepLeft()
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        case 124:
            do {
                let result = try viewModel.keepRight()
                handleActionResult(result)
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
```

------

#### Step 2 — 运行验证

运行 Debug 构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过。
- 无 `sourceControl` 属性、`canSelectRawForCurrentPair`、`appFileLogger` 相关编译错误。
- 重复对比页仍能实例化并编译通过。

------

✅ **完成的标志：** Debug 构建通过，重复对比页 RAW segment 逻辑编译通过。**在满足此条件之前不要开始下一个任务。**

------

### Task 5: 执行最终构建与手工验收

**目标：** 完整应用能构建通过，并能通过手工操作验证 RAW segment、fallback 和本地日志行为符合方案。

**涉及的文件：**

- `rawViewer/services/appFileLogger.swift` — 日志文件输出。
- `rawViewer/models/photoModels.swift` — RAW 文件存在性判断。
- `rawViewer/browser/photoBrowserViewController.swift` — 普通浏览器行为。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 重复对比页行为。

------

#### Step 1 — 实现

本任务不再修改代码。执行者必须按下面步骤准备手工验收素材并运行应用：

1. 准备一个照片目录，至少包含下列文件：

```text
A.jpg
B.jpg
B.cr2
C.jpg
C.cr2
D.jpg
D.cr2
```

2. 为模拟 RAW 解码失败，将 `C.cr2` 替换为一个存在但无法被 RAW 解码器解析的文件。可使用任意文本文件改名为 `C.cr2`。

3. 为模拟 `rawPath` 存在但文件丢失，先让 App 分析包含 `D.cr2` 的目录；分析完成后，在 Finder 或终端中删除 `D.cr2`，再重新打开同一分析结果。

4. 启动 App 后进入普通分组和重复分组进行人工观察。

------

#### Step 2 — 运行验证

先运行最终 Debug 构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过。
- 运行无编译阶段异常。

检查日志目录：

```bash
ls -la "$HOME/Library/Application Support/rawViewer/logs"
```

预期：

- 目录存在。
- 触发 RAW fallback 后出现当天日志文件，文件名格式为 `YYYY-MM-DD.log`。

查看当天日志内容。将命令中的日期替换为当天日期：

```bash
tail -n 50 "$HOME/Library/Application Support/rawViewer/logs/YYYY-MM-DD.log"
```

预期：

- RAW fallback 后能看到 `RAW unavailable, fallback to JPG`。
- RAW 和 JPG 都不可用时能看到 `RAW unavailable and JPG unavailable`。
- 普通浏览器日志包含 `page=browser` 和 `photoId=`。
- 重复对比页日志包含 `page=duplicate`、`side=left` 或 `side=right`、`photoId=`。

普通浏览器人工验收：

```text
A.jpg：RAW segment 灰色。
B.jpg：RAW segment 可点击，点击 RAW 后显示 RAW。
C.jpg：RAW segment 可点击，点击 RAW 后静默显示 JPG，并写 warning 日志。
D.jpg：RAW segment 灰色，因为 D.cr2 已被删除。
从 B.jpg 切到 A.jpg：RAW segment 从可点击变为灰色。
如果全局偏好之前是 RAW，打开 A.jpg 时自动切回 JPG。
```

重复对比页人工验收：

```text
左右都无 RAW：RAW segment 灰色。
左有 RAW、右无 RAW：RAW segment 可点击。
点击 RAW 后：左侧显示 RAW，右侧静默显示 JPG，并记录右侧 fallback 日志。
左右都有 RAW：RAW segment 可点击，两侧尽量显示 RAW。
某一侧 RAW 解码失败：该侧静默 fallback JPG，并记录 warning 日志。
```

------

✅ **完成的标志：** 最终 Debug 构建通过，普通浏览器、重复对比页和日志文件三类验收结果都符合预期。

------

## 自我复审记录

- 规范覆盖：recipe 中的 RAW 按钮灰色、文件存在判断、重复页单侧 RAW 规则、静默 fallback、本地日志、7 天保留期均已映射到 Task 1 至 Task 5。
- 占位符扫描：计划不包含未完成标记、占位语句或未定义步骤。
- 类型一致性：`appLogLevel`、`appFileLogger.log`、`photoItem.hasExistingRawFile(fileManager:)`、`updateSourceControlAvailability`、`canSelectRawForCurrentPair` 在任务间名称一致。
- 验证完整性：每个实现任务都有 `xcodebuild` 验证；最终任务包含构建、运行无异常和关键输出检查。

---

## 执行交接

计划已完成并保存到 `docs/flare/20260611_rawSegmentAvailabilityFix.md`。两种执行选项：

1. **子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。

2. **内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

选择哪种方式？
