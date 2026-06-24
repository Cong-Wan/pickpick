# 返回分组页保持窗口尺寸 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复从任意分组预览/比较页返回分组卡片页时，macOS 窗口尺寸被强制缩回原始尺寸的问题。

**架构：** 只在 `appCoordinator.showGroups()` 这个返回分组页的公共落点保留并恢复当前 `NSWindow.frame`。在替换 `window.contentViewController` 前，把新建的 `groupGridViewController.view.frame` 预设为当前 content view 尺寸，替换后如果 AppKit 改动了窗口 frame，则在非全屏状态下恢复原 frame。

**技术栈：** Swift、AppKit、NSWindow、NSViewController、NSCollectionView。

---

## 执行前约束

- 本计划按“无需详细打印输出”处理。
- 只保留关键节点 debug 日志。
- 所有日志必须通过现有 `--debug` 参数控制；不传 `--debug` 时不得输出调试日志。
- 禁止使用测试框架。
- 禁止安排 Git 操作。
- 每个任务必须先完成运行验证，再进入下一个任务。
- 本次修复只处理“返回分组卡片页时窗口尺寸回退”问题，不处理图片内部缩放、不重构路由、不调整分组卡片布局算法。

---

## 文件结构

本计划涉及以下文件：

- `appDebugLogger.swift` — 已有调试日志基础设施。负责读取 `--debug` 参数，并控制调试日志是否输出。
- `appCoordinator.swift` — 唯一需要修改业务逻辑的文件。负责页面路由；本次只修改 `showGroups()`。
- `docs/flare/20260624_window_size_restore.md` — 本计划文档。

---

## Task 1: 确认 `--debug` 日志基础设施

**目标：** 确认项目已有受 `--debug` 控制的日志工具，后续任务可以使用 `appDebugLogger.log(...)` 输出关键验证信息。

**涉及的文件：**

- `appDebugLogger.swift` — 调试日志工具。

------

#### Step 1 — 实现

确认 `appDebugLogger.swift` 内容如下。如果本地文件不同，替换为下面的完整内容。

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 提供受 --debug 参数控制的轻量日志工具，用于关键路径调试输出
*/

import Foundation

public enum appDebugLogger {
    public static var isEnabled: Bool {
        CommandLine.arguments.contains("--debug")
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[pickpick debug] %@", message())
    }
}
```

------

#### Step 2 — 运行验证

从项目根目录执行：

```bash
grep -n "CommandLine.arguments.contains(\"--debug\")" appDebugLogger.swift
grep -n "NSLog(\"\[pickpick debug\] %@\"" appDebugLogger.swift
```

预期输出包含：

```plain
CommandLine.arguments.contains("--debug")
NSLog("[pickpick debug] %@", message())
```

然后执行构建：

```bash
xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build
```

预期：

```plain
** BUILD SUCCEEDED **
```

如果构建不通过，修复 `appDebugLogger.swift` 与当前项目语法不一致的问题，直到构建通过。不要进入 Task 2，直到本任务构建通过。

------

✅ **完成的标志：** `appDebugLogger.swift` 使用 `--debug` 控制日志，且 `xcodebuild` 构建通过。

------

## Task 2: 在返回分组页时保留窗口 frame

**目标：** 用户在分组预览/比较页手动放大窗口后，点击 Back 或完成重复分组流程返回分组卡片页时，窗口尺寸保持用户放大后的尺寸。

**涉及的文件：**

- `appCoordinator.swift` — 页面路由协调器；本任务只改 `showGroups()` 相关逻辑，并更新文件头版本说明。

------

#### Step 1 — 实现

用下面的完整内容替换 `appCoordinator.swift`。

```swift
/*
Author: wilbur
Version: 1.6
Date: 2026-06-24
Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC；普通浏览页传递 group kind；持有 trashService 实例并注入到各 ViewModel；v1.6 返回分组页时保留当前窗口 frame，避免 contentViewController 替换导致窗口尺寸回退
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

        guard let window else { return }
        let currentFrame = window.frame
        let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size

        appDebugLogger.log("showGroups preserveWindowFrame before=\(NSStringFromRect(currentFrame)) contentSize=\(NSStringFromSize(currentContentSize))")

        controller.view.frame = NSRect(origin: .zero, size: currentContentSize)
        window.contentViewController = controller

        if !window.styleMask.contains(.fullScreen), window.frame != currentFrame {
            appDebugLogger.log("showGroups restoreWindowFrame from=\(NSStringFromRect(window.frame)) to=\(NSStringFromRect(currentFrame))")
            window.setFrame(currentFrame, display: true)
        }

        appDebugLogger.log("showGroups finalWindowFrame=\(NSStringFromRect(window.frame))")
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
        let browser = photoBrowserViewController(viewModel: viewModel, imageService: imageService, groupKind: group.kind)
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
```

------

#### Step 2 — 运行验证

从项目根目录执行构建：

```bash
xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build
```

预期：

```plain
** BUILD SUCCEEDED **
```

然后运行 Debug 版本，并打开 `--debug` 日志：

```bash
.build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
```

手动执行以下流程：

```plain
1. 选择照片目录，等待进入分组卡片页。
2. 进入任意普通分组，例如 Normal / Overexposed / Underexposed / Blurry。
3. 手动把窗口明显放大。
4. 点击 Back。
5. 观察返回分组卡片页后窗口是否保持放大后的尺寸。
```

预期调试输出至少包含：

```plain
[pickpick debug] showGroups preserveWindowFrame before=
[pickpick debug] showGroups finalWindowFrame=
```

如果 AppKit 在 `contentViewController` 替换时改变了窗口尺寸，预期还会出现：

```plain
[pickpick debug] showGroups restoreWindowFrame from=
```

预期 UI 行为：

```plain
返回分组卡片页后，窗口尺寸保持用户刚才手动放大后的尺寸，不回退到 1100 x 760。
```

如果构建不通过，修复 `appCoordinator.swift` 中的语法问题，直到构建通过。如果 UI 行为不符合预期，保留 `--debug` 日志输出，检查 `before`、`from`、`to`、`finalWindowFrame` 四个 frame 值是否符合“最终 frame 等于返回前 frame”的目标。

------

✅ **完成的标志：** 构建通过；运行无异常；普通分组返回分组卡片页后，窗口尺寸保持用户放大后的尺寸。

------

## Task 3: 验证重复分组返回路径

**目标：** Duplicate 分组点击 Back 返回分组卡片页时，窗口尺寸保持用户放大后的尺寸。

**涉及的文件：**

- `appCoordinator.swift` — 不新增代码；验证 `showDuplicate(...).onBack` 汇入 `showGroups()` 后能复用 Task 2 的修复。

------

#### Step 1 — 实现

本任务不修改代码。确认 `appCoordinator.swift` 中 Duplicate 返回路径保持如下内容：

```swift
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
```

------

#### Step 2 — 运行验证

从项目根目录执行构建：

```bash
xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build
```

预期：

```plain
** BUILD SUCCEEDED **
```

运行 Debug 版本：

```bash
.build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
```

手动执行以下流程：

```plain
1. 选择包含重复照片的目录，等待进入分组卡片页。
2. 进入 Duplicate 分组。
3. 手动把窗口明显放大。
4. 点击 Back。
5. 观察返回分组卡片页后窗口是否保持放大后的尺寸。
```

预期调试输出至少包含：

```plain
[pickpick debug] showGroups preserveWindowFrame before=
[pickpick debug] showGroups finalWindowFrame=
```

预期 UI 行为：

```plain
Duplicate 分组点击 Back 返回分组卡片页后，窗口尺寸保持用户刚才手动放大后的尺寸。
```

如果 UI 行为不符合预期，不要进入 Task 4。先回到 Task 2 的 `showGroups()` 逻辑，确认 `currentFrame` 是在替换 `contentViewController` 之前读取的，并确认没有把 `window.setFrame(...)` 放到全屏状态下执行。

------

✅ **完成的标志：** 构建通过；运行无异常；Duplicate 分组 Back 返回后窗口尺寸保持不变。

------

## Task 4: 验证重复分组完成路径

**目标：** Duplicate 分组通过完成流程触发 `onFinished` 自动返回分组卡片页时，窗口尺寸保持用户放大后的尺寸。

**涉及的文件：**

- `appCoordinator.swift` — 不新增代码；验证 `showDuplicate(...).onFinished` 汇入 `showGroups()` 后能复用 Task 2 的修复。

------

#### Step 1 — 实现

本任务不修改代码。确认 `appCoordinator.swift` 中完成路径保持如下内容：

```swift
        duplicate.onFinished = { [weak self] in
            guard let self = self else { return }
            do {
                try self.reloadData()
            } catch {
                // reloadData 失败时仍尝试 showGroups，用内存中的旧数据
            }
            self.showGroups()
        }
```

------

#### Step 2 — 运行验证

从项目根目录执行构建：

```bash
xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build
```

预期：

```plain
** BUILD SUCCEEDED **
```

运行 Debug 版本：

```bash
.build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
```

手动执行以下流程：

```plain
1. 选择包含重复照片的目录，等待进入分组卡片页。
2. 进入 Duplicate 分组。
3. 手动把窗口明显放大。
4. 在重复比较流程中执行操作，直到触发完成并自动返回分组卡片页。
5. 观察返回分组卡片页后窗口是否保持放大后的尺寸。
```

预期调试输出至少包含：

```plain
[pickpick debug] showGroups preserveWindowFrame before=
[pickpick debug] showGroups finalWindowFrame=
```

预期 UI 行为：

```plain
Duplicate 完成流程自动返回分组卡片页后，窗口尺寸保持用户刚才手动放大后的尺寸。
```

如果 UI 行为不符合预期，停止执行计划。保留完整 `--debug` 日志，检查是否存在其它路径绕过了 `showGroups()`。

------

✅ **完成的标志：** 构建通过；运行无异常；Duplicate 完成流程返回后窗口尺寸保持不变。

------

## Task 5: 验证非目标路径没有被扩大影响

**目标：** 确认本次修改没有改变启动页、进度页、错误页、进入普通浏览页、进入重复比较页的窗口策略；本次修复只影响返回分组卡片页这一落点。

**涉及的文件：**

- `appCoordinator.swift` — 检查除 `showGroups()` 外，其它 `window?.contentViewController = ...` 调用保持原样。

------

#### Step 1 — 实现

本任务不修改代码。确认 `appCoordinator.swift` 中以下调用保持原样：

```swift
        window?.contentViewController = progressController
```

```swift
        window?.contentViewController = controller
```

```swift
        window?.contentViewController = browser
```

```swift
        window?.contentViewController = duplicate
```

```swift
        window?.contentViewController = controller
```

确认 `showGroups()` 中使用的是下面的收窄修复代码：

```swift
        guard let window else { return }
        let currentFrame = window.frame
        let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size

        appDebugLogger.log("showGroups preserveWindowFrame before=\(NSStringFromRect(currentFrame)) contentSize=\(NSStringFromSize(currentContentSize))")

        controller.view.frame = NSRect(origin: .zero, size: currentContentSize)
        window.contentViewController = controller

        if !window.styleMask.contains(.fullScreen), window.frame != currentFrame {
            appDebugLogger.log("showGroups restoreWindowFrame from=\(NSStringFromRect(window.frame)) to=\(NSStringFromRect(currentFrame))")
            window.setFrame(currentFrame, display: true)
        }

        appDebugLogger.log("showGroups finalWindowFrame=\(NSStringFromRect(window.frame))")
```

------

#### Step 2 — 运行验证

从项目根目录执行静态检查：

```bash
grep -n "contentViewController" appCoordinator.swift
```

预期输出包含 6 处 `contentViewController` 相关行：

```plain
window?.contentViewController = progressController
window?.contentViewController = controller
window.contentViewController = controller
window?.contentViewController = browser
window?.contentViewController = duplicate
window?.contentViewController = controller
```

然后执行构建：

```bash
xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build
```

预期：

```plain
** BUILD SUCCEEDED **
```

运行 Debug 版本：

```bash
.build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
```

手动执行以下流程：

```plain
1. 启动应用，确认启动页正常显示。
2. 选择目录，确认进度页正常显示。
3. 进入分组卡片页，确认卡片布局正常显示。
4. 进入普通分组，确认图片浏览页正常显示。
5. 返回分组卡片页，确认窗口尺寸不回退。
6. 进入 Duplicate 分组，确认重复比较页正常显示。
7. 返回分组卡片页，确认窗口尺寸不回退。
```

预期 UI 行为：

```plain
所有页面能正常显示；只有返回分组卡片页时执行窗口 frame 保护；其它页面切换不出现新的窗口跳动、空白页或布局异常。
```

如果出现空白页，优先确认 `controller.view.frame = NSRect(origin: .zero, size: currentContentSize)` 是否写在 `window.contentViewController = controller` 之前。如果出现全屏状态下窗口异常，确认 `window.setFrame(...)` 是否仍被 `!window.styleMask.contains(.fullScreen)` 保护。

------

✅ **完成的标志：** 构建通过；运行无异常；启动、分析、分组、普通浏览、重复比较路径均可使用；返回分组卡片页不再缩回原始尺寸。

------

## 最终验收清单

执行完所有任务后，逐项确认：

- [ ] `appDebugLogger.swift` 仍然通过 `--debug` 控制日志。
- [ ] `appCoordinator.swift` 文件头版本更新为 `1.6`。
- [ ] 只有 `showGroups()` 引入窗口 frame 保护逻辑。
- [ ] 没有全局替换所有 `contentViewController` 安装逻辑。
- [ ] `xcodebuild -scheme pickpick -configuration Debug -derivedDataPath .build build` 输出 `** BUILD SUCCEEDED **`。
- [ ] 普通分组 Back 返回后窗口尺寸保持不变。
- [ ] Duplicate 分组 Back 返回后窗口尺寸保持不变。
- [ ] Duplicate 完成流程返回后窗口尺寸保持不变。
- [ ] 不传 `--debug` 时没有新增调试日志输出。
- [ ] 传 `--debug` 时能看到 `showGroups preserveWindowFrame` 和 `showGroups finalWindowFrame`。

---

## 自我复审

### 1. 规范覆盖

- 已覆盖窗口尺寸回退问题。
- 已覆盖普通分组返回路径。
- 已覆盖 Duplicate Back 返回路径。
- 已覆盖 Duplicate onFinished 返回路径。
- 已限定修改范围到 `showGroups()`。
- 已遵守不使用测试框架。
- 已遵守不安排 Git 操作。
- 已使用 `--debug` 控制所有新增日志。

### 2. 占位符扫描

本计划没有使用 `TBD`、`TODO`、省略号代码、未定义类型、未定义函数或“稍后实现”。

### 3. 类型一致性

- `appDebugLogger.log(...)` 已存在于 `appDebugLogger.swift`。
- `NSStringFromRect(...)`、`NSStringFromSize(...)` 来自 AppKit/Foundation 环境，`appCoordinator.swift` 已 `import AppKit`。
- `window.frame` 类型为 `NSRect`，`currentFrame` 同类型。
- `window.setFrame(currentFrame, display: true)` 与 AppKit API 匹配。
- `controller.view.frame` 使用 `NSRect(origin:size:)`，与 AppKit view frame 类型匹配。

### 4. 验证完整性

每个任务均包含：

- 构建命令。
- 运行命令。
- 手动验证路径。
- 预期日志或 UI 行为。
- 明确完成标志。

---

## 执行交接

计划已完成并保存到 `docs/flare/20260624_window_size_restore.md`。两种执行选项：

**1. 子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。

**2. 内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

选择哪种方式？
