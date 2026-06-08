# 真实删除到废纸篓 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前仅修改 JSON 状态的"删除/抛弃"操作，改为先将原始 JPG+RAW 文件移入 macOS 废纸篓，再标记 JSON 状态；文件已不存在则静默跳过，文件存在但移入失败则抛错且不回滚 JSON。

**Architecture:** 提取 `photoTrashService` 统一负责文件系统层面的移入废纸篓操作；`photoBrowserViewModel` 和 `duplicateCompareViewModel` 在 mark JSON 之前先调用 trashService，确保"先删文件、后改状态"的顺序；`appCoordinator` 负责注入依赖。

**Tech Stack:** Swift, AppKit (FileManager.trashItem), XCTest

---

### 文件结构

| 文件 | 职责 |
|------|------|
| `rawViewer/photoTrashService.swift` | 新建：协议 `photoTrashServicing` + 实现 `photoTrashService`，负责把 `photoItem` 的 jpgPath/rawPath 移入废纸篓 |
| `rawViewer/photoBrowserViewModel.swift` | 修改：注入 trashService，`confirmDelete()` 先 trash 全部 targets，全部成功后再 mark JSON |
| `rawViewer/duplicateCompareViewModel.swift` | 修改：注入 trashService，`keepLeft()` / `keepRight()` 先 trash 被抛弃的照片，成功后再 mark JSON |
| `rawViewer/appCoordinator.swift` | 修改：持有 `photoTrashService` 实例，创建 ViewModel 时注入 |
| `rawViewerTests/photoTrashServiceTests.swift` | 新建：Task 1 测试 |
| `rawViewerTests/photoBrowserViewModelTests.swift` | 新建：Task 2 测试 |
| `rawViewerTests/duplicateCompareViewModelTests.swift` | 新建：Task 3 测试 |

---

### Task 1: photoTrashService

**Goal:** `photoTrashService.trash(photoItem)` 能把 JPG 和 RAW 文件移入系统废纸篓；文件已不存在则静默成功；任一文件移入失败则抛 `photoTrashError`。

**Files touched:**

- `rawViewer/photoTrashService.swift` — 协议 + 实现 + 错误类型
- `rawViewerTests/photoTrashServiceTests.swift` — 文件系统级测试

------

#### Step 1 — Implement

```swift
// rawViewer/photoTrashService.swift

import Foundation

public enum photoTrashError: Error {
    case trashFailed(path: String, underlying: Error)
}

public protocol photoTrashServicing {
    /// 将照片的 JPG 与 RAW（如有）移到系统废纸篓。
    /// 文件已不存在 → 静默返回。
    /// 任一文件移入废纸篓失败 → 抛 photoTrashError，已移入的不回滚。
    func trash(_ photo: photoItem) throws
}

public final class photoTrashService: photoTrashServicing {
    public init() {}

    public func trash(_ photo: photoItem) throws {
        let paths = [photo.jpgPath, photo.rawPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw photoTrashError.trashFailed(path: path, underlying: error)
            }
        }
    }
}
```

------

#### Step 2 — Write tests

```swift
// rawViewerTests/photoTrashServiceTests.swift

import XCTest
@testable import rawViewer

final class photoTrashServiceTests: XCTestCase {
    private var service: photoTrashService!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        service = photoTrashService()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testTrash_existingJpgAndRaw_movesBothToTrash() throws {
        let jpgPath = tempDir.appendingPathComponent("test.jpg").path
        let rawPath = tempDir.appendingPathComponent("test.raw").path
        try "jpgdata".write(toFile: jpgPath, atomically: true, encoding: .utf8)
        try "rawdata".write(toFile: rawPath, atomically: true, encoding: .utf8)

        let photo = photoItem(photoId: "1", jpgPath: jpgPath, rawPath: rawPath)
        try service.trash(photo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: jpgPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawPath))
    }

    func testTrash_missingFiles_silentlySucceeds() throws {
        let photo = photoItem(
            photoId: "1",
            jpgPath: "/nonexistent/path.jpg",
            rawPath: "/nonexistent/path.raw"
        )
        XCTAssertNoThrow(try service.trash(photo))
    }

    func testTrash_onlyJpgExist_trashesJpgOnly() throws {
        let jpgPath = tempDir.appendingPathComponent("only.jpg").path
        try "data".write(toFile: jpgPath, atomically: true, encoding: .utf8)

        let photo = photoItem(photoId: "1", jpgPath: jpgPath, rawPath: nil)
        try service.trash(photo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: jpgPath))
    }
}
```

------

#### Step 3 — Run tests

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing rawViewerTests/photoTrashServiceTests
# Expected output contains:
# Test Suite 'photoTrashServiceTests' passed
# Executed 3 tests, with 0 failures
```

✅ **Done when:** 3 个测试全部通过。

---

### Task 2: photoBrowserViewModel

**Goal:** `confirmDelete()` 先调用 `trashService.trash()` 处理所有 targets，全部成功后再逐个 `store.mark(..., .trashed)`；任一 trash 失败则抛错，且没有任何 JSON 状态被修改。

**Files touched:**

- `rawViewer/photoBrowserViewModel.swift` — 注入 trashService，调整 confirmDelete 顺序
- `rawViewerTests/photoBrowserViewModelTests.swift` — mock 测试

------

#### Step 1 — Implement

```swift
// rawViewer/photoBrowserViewModel.swift

import Foundation

public final class photoBrowserViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public private(set) var checkedPhotoIds: Set<String> = []
    public private(set) var displaySource: displaySource
    public private(set) var currentRequestId: Int = 0
    private let store: jsonReviewStateStoring
    private let trashService: photoTrashServicing

    public init(
        photos: [photoItem],
        store: jsonReviewStateStoring,
        trashService: photoTrashServicing,
        displaySource: displaySource = .jpg
    ) {
        self.photos = photos
        self.store = store
        self.trashService = trashService
        self.displaySource = displaySource
    }

    public var currentPhoto: photoItem? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
        currentRequestId += 1
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        currentRequestId += 1
    }

    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        currentRequestId += 1
    }

    public func setDisplaySource(_ source: displaySource) {
        displaySource = source
        currentRequestId += 1
    }

    public func isCurrentRequest(_ requestId: Int, photoId: String) -> Bool {
        currentRequestId == requestId && currentPhoto?.photoId == photoId
    }

    public func toggleCheck(photoId: String, isChecked: Bool) {
        if isChecked {
            checkedPhotoIds.insert(photoId)
        } else {
            checkedPhotoIds.remove(photoId)
        }
    }

    public func toggleAll(isChecked: Bool) {
        checkedPhotoIds = isChecked ? Set(photos.map(\.photoId)) : []
    }

    public func deleteTargets() -> [photoItem] {
        if checkedPhotoIds.isEmpty {
            return currentPhoto.map { [$0] } ?? []
        }
        return photos.filter { checkedPhotoIds.contains($0.photoId) }
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        // 先全部 trash，全部成功后再 mark JSON
        for photo in targets {
            try trashService.trash(photo)
        }
        for photo in targets {
            try store.mark(photoId: photo.photoId, status: .trashed)
        }
        let ids = Set(targets.map(\.photoId))
        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }
}
```

------

#### Step 2 — Write tests

```swift
// rawViewerTests/photoBrowserViewModelTests.swift

import XCTest
@testable import rawViewer

final class mockTrashService: photoTrashServicing {
    var trashedPhotos: [photoItem] = []
    var shouldFailOn: String? = nil

    func trash(_ photo: photoItem) throws {
        if let shouldFailOn, photo.photoId == shouldFailOn {
            throw photoTrashError.trashFailed(path: photo.jpgPath, underlying: NSError(domain: "test", code: 1))
        }
        trashedPhotos.append(photo)
    }
}

final class mockReviewStateStore: jsonReviewStateStoring {
    var markedPhotos: [(String, reviewStatus)] = []

    func mark(photoId: String, status: reviewStatus) throws {
        markedPhotos.append((photoId, status))
    }

    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {}
    func clearReviewGroupId(photoId: String) throws {}
}

final class photoBrowserViewModelTests: XCTestCase {
    private var store: mockReviewStateStore!
    private var trash: mockTrashService!

    override func setUp() {
        super.setUp()
        store = mockReviewStateStore()
        trash = mockTrashService()
    }

    func testConfirmDelete_allSucceed_trashesThenMarks() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = photoBrowserViewModel(photos: [p1, p2], store: store, trashService: trash)
        vm.toggleCheck(photoId: "a", isChecked: true)
        vm.toggleCheck(photoId: "b", isChecked: true)

        try vm.confirmDelete()

        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["a", "b"])
        XCTAssertEqual(store.markedPhotos.map(\.0), ["a", "b"])
        XCTAssertEqual(store.markedPhotos.map(\.1), [.trashed, .trashed])
        XCTAssertTrue(vm.photos.isEmpty)
    }

    func testConfirmDelete_trashFails_noJsonMarked() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = photoBrowserViewModel(photos: [p1, p2], store: store, trashService: trash)
        vm.toggleCheck(photoId: "a", isChecked: true)
        vm.toggleCheck(photoId: "b", isChecked: true)
        trash.shouldFailOn = "b"

        XCTAssertThrowsError(try vm.confirmDelete())

        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["a"])
        XCTAssertTrue(store.markedPhotos.isEmpty)
        XCTAssertEqual(vm.photos.count, 2)
    }

    func testConfirmDelete_noChecked_deletesCurrentOnly() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = photoBrowserViewModel(photos: [p1, p2], store: store, trashService: trash)
        vm.setCurrentIndex(0)

        try vm.confirmDelete()

        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["a"])
        XCTAssertEqual(store.markedPhotos.map(\.0), ["a"])
        XCTAssertEqual(vm.photos.count, 1)
    }
}
```

------

#### Step 3 — Run tests

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing rawViewerTests/photoBrowserViewModelTests
# Expected output contains:
# Test Suite 'photoBrowserViewModelTests' passed
# Executed 3 tests, with 0 failures
```

✅ **Done when:** 3 个测试全部通过。

---

### Task 3: duplicateCompareViewModel

**Goal:** `keepLeft()` / `keepRight()` 先 `trashService.trash()` 被抛弃的照片，成功后再 `store.mark(..., .trashed)`；trash 失败则抛错且 JSON 不被修改。

**Files touched:**

- `rawViewer/duplicateCompareViewModel.swift` — 注入 trashService，调整 keepLeft/keepRight 顺序
- `rawViewerTests/duplicateCompareViewModelTests.swift` — mock 测试

------

#### Step 1 — Implement

```swift
// rawViewer/duplicateCompareViewModel.swift

import Foundation

public enum duplicateCompareActionResult: Equatable {
    case continueComparing
    case finished
}

public final class duplicateCompareViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var mainIndex: Int = 0
    public private(set) var candidateIndex: Int = 1
    private let store: jsonReviewStateStoring
    private let trashService: photoTrashServicing

    public init(photos: [photoItem], store: jsonReviewStateStoring, trashService: photoTrashServicing) {
        self.photos = photos
        self.store = store
        self.trashService = trashService
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try trashService.trash(right)
        try store.mark(photoId: right.photoId, status: .trashed)
        photos.removeAll { $0.photoId == right.photoId }
        if photos.count == 1 {
            try markFinalKept(left)
            return .finished
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepRight() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try trashService.trash(left)
        try store.mark(photoId: left.photoId, status: .trashed)
        photos.removeAll { $0.photoId == left.photoId }
        if photos.count == 1 {
            try markFinalKept(right)
            return .finished
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
        if let left = mainPhoto {
            try store.mark(photoId: left.photoId, status: .kept)
            try store.clearReviewGroupId(photoId: left.photoId)
        }
        if let right = candidatePhoto {
            try store.mark(photoId: right.photoId, status: .kept)
            try store.clearReviewGroupId(photoId: right.photoId)
        }

        let keptIds = Set([mainPhoto, candidatePhoto].compactMap { $0?.photoId })
        photos.removeAll { keptIds.contains($0.photoId) }

        switch photos.count {
        case 0:
            return .finished
        case 1:
            if let last = photos.first {
                try markFinalKept(last)
            }
            return .finished
        default:
            if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
                try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
            }
            mainIndex = 0
            candidateIndex = min(1, photos.count - 1)
            return .continueComparing
        }
    }

    private func markFinalKept(_ photo: photoItem) throws {
        try store.mark(photoId: photo.photoId, status: .kept)
        if !photo.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
            try store.clearReviewGroupId(photoId: photo.photoId)
        }
    }
}
```

------

#### Step 2 — Write tests

```swift
// rawViewerTests/duplicateCompareViewModelTests.swift

import XCTest
@testable import rawViewer

final class duplicateCompareViewModelTests: XCTestCase {
    private var store: mockReviewStateStore!
    private var trash: mockTrashService!

    override func setUp() {
        super.setUp()
        store = mockReviewStateStore()
        trash = mockTrashService()
    }

    func testKeepLeft_success_trashesRightThenMarksTrashed() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = duplicateCompareViewModel(photos: [p1, p2], store: store, trashService: trash)

        let result = try vm.keepLeft()

        XCTAssertEqual(result, .continueComparing)
        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["b"])
        XCTAssertEqual(store.markedPhotos, [("b", .trashed)])
    }

    func testKeepLeft_trashFails_doesNotMarkJson() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = duplicateCompareViewModel(photos: [p1, p2], store: store, trashService: trash)
        trash.shouldFailOn = "b"

        XCTAssertThrowsError(try vm.keepLeft())
        XCTAssertTrue(store.markedPhotos.isEmpty)
        XCTAssertEqual(vm.photos.count, 2)
    }

    func testKeepRight_success_trashesLeftThenMarksTrashed() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = duplicateCompareViewModel(photos: [p1, p2], store: store, trashService: trash)

        let result = try vm.keepRight()

        XCTAssertEqual(result, .continueComparing)
        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["a"])
        XCTAssertEqual(store.markedPhotos, [("a", .trashed)])
    }

    func testKeepRight_trashFails_doesNotMarkJson() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = duplicateCompareViewModel(photos: [p1, p2], store: store, trashService: trash)
        trash.shouldFailOn = "a"

        XCTAssertThrowsError(try vm.keepRight())
        XCTAssertTrue(store.markedPhotos.isEmpty)
    }

    func testKeepLeft_lastTwoPhotos_marksRemainingKeptAndFinishes() throws {
        let p1 = photoItem(photoId: "a", jpgPath: "/a.jpg")
        let p2 = photoItem(photoId: "b", jpgPath: "/b.jpg")
        let vm = duplicateCompareViewModel(photos: [p1, p2], store: store, trashService: trash)

        let result = try vm.keepLeft()

        // keepLeft removes p2 (trashed), then sees only p1 left -> markFinalKept
        XCTAssertEqual(result, .finished)
        XCTAssertEqual(trash.trashedPhotos.map(\.photoId), ["b"])
        XCTAssertEqual(store.markedPhotos, [("b", .trashed), ("a", .kept)])
    }
}
```

> **Note:** `mockTrashService` 和 `mockReviewStateStore` 已在 Task 2 的测试文件中定义。如果 Xcode 测试 target 中多个测试文件共享类型会导致重复定义，将 mock 提取到 `rawViewerTests/TestHelpers.swift` 中：

```swift
// rawViewerTests/TestHelpers.swift

import Foundation
@testable import rawViewer

final class mockTrashService: photoTrashServicing { ... }
final class mockReviewStateStore: jsonReviewStateStoring { ... }
```

然后从 Task 2 和 Task 3 的测试文件中删除 mock 定义。

------

#### Step 3 — Run tests

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing rawViewerTests/duplicateCompareViewModelTests
# Expected output contains:
# Test Suite 'duplicateCompareViewModelTests' passed
# Executed 5 tests, with 0 failures
```

✅ **Done when:** 5 个测试全部通过。

---

### Task 4: appCoordinator + 编译验证

**Goal:** `appCoordinator` 持有 `photoTrashService` 并在创建 `photoBrowserViewModel` / `duplicateCompareViewModel` 时注入；项目编译通过无报错。

**Files touched:**

- `rawViewer/appCoordinator.swift` — 注入 trashService
- `rawViewer/photoBrowserViewController.swift` — 更新 convenience init 以传递 trashService

------

#### Step 1 — Implement

```swift
// rawViewer/appCoordinator.swift

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
    private let trashService: photoTrashServicing
    public private(set) var currentFolderUrl: URL?

    public init(
        window: NSWindow,
        analyzer: photoAnalyzerBridge,
        imageService: photoImageService = photoImageService(),
        trashService: photoTrashServicing = photoTrashService()
    ) {
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
            trashService: trashService,
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
        let viewModel = duplicateCompareViewModel(photos: group.photos, store: store, trashService: trashService)
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

    func navigateToGroup(_ group: photoGroup) {
        if group.kind.isDuplicate {
            showDuplicate(group: group)
        } else {
            showBrowser(group: group)
        }
    }
}
```

同时更新 `photoBrowserViewController` 的 convenience init（若存在）以传递 trashService：

```swift
// rawViewer/photoBrowserViewController.swift
// 只修改 convenience init 这一处

public convenience init(
    group: photoGroup,
    store: jsonReviewStateStoring,
    trashService: photoTrashServicing,
    imageService: photoImageService = photoImageService()
) {
    let initialSource = displaySourceStore().current
    let viewModel = photoBrowserViewModel(
        photos: group.photos,
        store: store,
        trashService: trashService,
        displaySource: initialSource
    )
    self.init(viewModel: viewModel, imageService: imageService)
    self.groupTitle = group.kind.title
}
```

> 若 `photoBrowserViewController` 的 convenience init 未被其他调用方使用（当前代码中 `appCoordinator` 直接调用指定 init），此 convenience init 的修改仅为完整性考虑；即使不修改也不会影响编译。

------

#### Step 2 — Compile

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
# Expected output:
# ** BUILD SUCCEEDED **
```

✅ **Done when:** Build Succeeded，无任何编译错误。

---

## Self-Review

**1. Spec coverage:**
- [x] 新增 photoTrashService 统一处理文件移入废纸篓 → Task 1
- [x] photoBrowserViewModel 先 trash 后 mark JSON → Task 2
- [x] duplicateCompareViewModel keepLeft/keepRight 先 trash 后 mark → Task 3
- [x] appCoordinator 注入 trashService → Task 4
- [x] 文件不存在时静默跳过 → Task 1 测试 `testTrash_missingFiles_silentlySucceeds`
- [x] trash 失败时抛错、JSON 不修改 → Task 2/3 测试

**2. Placeholder scan:**
- [x] 无 TBD / TODO / "... rest of function"
- [x] 所有代码块完整可运行

**3. Type consistency:**
- [x] `photoTrashServicing` 协议在 Task 1 定义，Task 2/3/4 使用一致
- [x] `photoBrowserViewModel.init` 参数顺序在所有调用点一致
- [x] `duplicateCompareViewModel.init` 参数顺序在所有调用点一致

**4. Test completeness:**
- [x] Task 1: 成功、文件不存在、只有 JPG 三个场景
- [x] Task 2: 全部成功、部分失败 trash 抛错、未勾选时只删当前三张场景
- [x] Task 3: keepLeft 成功、keepLeft 失败、keepRight 成功、keepRight 失败、只剩两张时收尾五个场景
- [x] Task 4: 编译通过即验证

---

## Execution Handoff

Plan complete and saved to `docs/flare/20260608_realDeleteTrash.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
