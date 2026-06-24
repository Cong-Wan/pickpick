# 窗口尺寸跨页面切换保持 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 用户在任意主界面调整窗口尺寸后，进入分析进度页、分组展示页、普通分组预览页、重复分组对比页、错误页或返回起始页时，窗口尺寸和位置都不应被页面切换强制重置。

**架构：** 问题根源是 `appCoordinator` 在多处直接设置 `window.contentViewController`，AppKit 会依据新 controller 的 root view 尺寸重新适配窗口。修复方式是在 `appCoordinator` 内增加一个统一的 controller 安装入口：安装前记录当前 `window.frame` 和 content size，先让新 controller 的 root view 匹配当前 content size，再设置 `contentViewController`，如果 AppKit 仍改动窗口 frame，则立即恢复原 frame。所有主页面切换统一走这个入口。

**技术栈：** Swift、AppKit、NSWindow、NSViewController、现有 `appDebugLogger`。

---

## 文件结构

本计划只修改一个文件，不创建新源码文件。

- `appCoordinator.swift` — 负责所有主页面路由。新增统一安装 controller 的私有方法，并替换所有直接 `window?.contentViewController = ...` 调用。

不修改：

- `mainWindowController.swift` — 初始窗口尺寸和 `minSize` 保持不变。
- `startViewController.swift` — 起始页布局保持不变。
- `groupGridViewController.swift` — 分组页布局保持不变。
- `photoBrowserViewController.swift` — 普通预览页布局保持不变。
- `duplicateCompareViewController.swift` — 重复对比页布局保持不变。

---

### Task 1: 统一主页面安装入口

**目标：** `appCoordinator` 内所有主页面切换都通过同一个方法安装 `NSViewController`，并在安装前后保持用户当前窗口 frame。

**涉及的文件：**

- `appCoordinator.swift` — 新增 `installContentViewController(_:)`，替换 6 处直接设置 `contentViewController` 的代码。

------

#### Step 1 — 实现

用下面完整内容替换 `appCoordinator.swift`。

```swift
/*
Author: wilbur
Version: 1.6
Date: 2026-06-24
Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC；普通浏览页传递 group kind；持有 trashService 实例并注入到各 ViewModel；v1.6 统一通过 installContentViewController 安装主页面，避免 contentViewController 替换导致窗口尺寸回退
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
        installContentViewController(progressController)

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
        installContentViewController(controller)
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
        installContentViewController(controller)
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
        installContentViewController(browser)
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
        installContentViewController(duplicate)
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
        installContentViewController(controller)
    }

    func navigateToGroup(_ group: photoGroup) {
        if group.kind.isDuplicate {
            showDuplicate(group: group)
        } else {
            showBrowser(group: group)
        }
    }

    private func installContentViewController(_ controller: NSViewController) {
        guard let window else { return }

        let currentFrame = window.frame
        let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size

        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(origin: .zero, size: currentContentSize)

        window.contentViewController = controller

        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }

        if !NSEqualRects(window.frame, currentFrame) {
            appDebugLogger.log("restore window frame from=\(NSStringFromRect(window.frame)) to=\(NSStringFromRect(currentFrame)) screenState=\(screenState)")
            window.setFrame(currentFrame, display: true)
            let restoredContentSize = window.contentView?.bounds.size ?? currentContentSize
            controller.view.frame = NSRect(origin: .zero, size: restoredContentSize)
            controller.view.layoutSubtreeIfNeeded()
        }
    }
}
```

关键点：

- 不再只修 `showGroups()`。
- `startAnalysis()` 中的 progress 页面也走统一入口。
- `showStart()`、`showGroups()`、`showBrowser()`、`showDuplicate()`、`showError()` 全部走统一入口。
- 只有 `--debug` 存在时才输出恢复窗口 frame 的日志。
- full screen 和 minimized 状态下不强行 `setFrame`。

------

#### Step 2 — 运行验证

在项目根目录运行构建：

```bash
$ xcodebuild -scheme pickpick -configuration Debug build
# 预期：出现 ** BUILD SUCCEEDED **
```

如果构建失败：

1. 不进入下一个任务。
2. 只修复 `appCoordinator.swift` 中与本任务相关的编译错误。
3. 再次运行同一条 `xcodebuild` 命令，直到构建通过。

------

✅ **完成的标志：** 构建通过，且 `appCoordinator.swift` 中不再存在任何直接 `window?.contentViewController = ...` 或 `window.contentViewController = ...` 的主页面切换代码；唯一允许设置 `window.contentViewController` 的地方是 `installContentViewController(_:)`。

------

### Task 2: 手动验证所有窗口尺寸切换路径

**目标：** 用户在任意主界面调整窗口大小后，进入下一个主界面时窗口不回退到 `1100 x 760` 或其他默认尺寸。

**涉及的文件：**

- 无新增修改。只运行 App 手动验证。

------

#### Step 1 — 实现

本任务不改代码。使用 Task 1 的构建结果运行 App。

------

#### Step 2 — 运行验证

用 debug 模式运行 App，方便在发生 frame 恢复时看到日志。

```bash
$ xcodebuild -scheme pickpick -configuration Debug build
# 预期：出现 ** BUILD SUCCEEDED **
```

然后从 Xcode 或构建产物运行 App，并在启动参数中加入：

```bash
--debug
```

按下面顺序逐项验证。

#### 场景 A：起始页 → 分析进度页 → 分组展示页

1. 打开 App，停留在选择文件夹界面。
2. 手动把窗口拉大，例如拉到接近屏幕宽度。
3. 选择一个文件夹。
4. 等进入分组展示页。

预期：

```plain
窗口保持用户在选择文件夹界面调整后的尺寸，不回退到 1100 x 760。
```

#### 场景 B：分组展示页 → 普通分组预览页

1. 停留在分组展示页。
2. 手动把窗口拉大或拉小。
3. 点击任意非 Duplicate 分组卡片。

预期：

```plain
进入普通分组预览页后，窗口保持分组展示页上的用户调整尺寸。
```

#### 场景 C：普通分组预览页 → 分组展示页

1. 停留在普通分组预览页。
2. 手动调整窗口尺寸。
3. 点击 `← Back`。

预期：

```plain
返回分组展示页后，窗口保持普通分组预览页上的用户调整尺寸。
```

#### 场景 D：分组展示页 → Duplicate 对比页

1. 停留在分组展示页。
2. 手动调整窗口尺寸。
3. 点击 Duplicate 分组卡片。

预期：

```plain
进入 Duplicate 对比页后，窗口保持分组展示页上的用户调整尺寸。
```

#### 场景 E：Duplicate 对比页 → 分组展示页

1. 停留在 Duplicate 对比页。
2. 手动调整窗口尺寸。
3. 点击 `← Back`。

预期：

```plain
返回分组展示页后，窗口保持 Duplicate 对比页上的用户调整尺寸。
```

#### 场景 F：分组展示页 → 起始页

1. 停留在分组展示页。
2. 手动调整窗口尺寸。
3. 点击 `← Back` 返回选择文件夹界面。

预期：

```plain
返回选择文件夹界面后，窗口保持分组展示页上的用户调整尺寸。
```

#### 场景 G：全屏保护

1. 进入任意页面。
2. 切到 macOS 全屏模式。
3. 在全屏中切换页面。

预期：

```plain
页面正常切换；没有退出全屏；没有强行 setFrame 造成窗口跳动。
```

------

✅ **完成的标志：** 场景 A 到 G 全部通过；没有任何页面切换会把用户调整过的窗口尺寸强制缩回默认尺寸。

------

## 自我复审

### 1. 规范覆盖

已覆盖以下用户反馈路径：

- 选择文件夹界面调整窗口后，进入分组展示页不应缩回。
- 分组展示页调整窗口后，进入任意分组不应缩回。
- 任意分组返回分组展示页不应缩回。

### 2. 占位符扫描

本计划没有 `TBD`、`TODO`、`稍后实现`、省略号代码、未定义函数或未定义类型。

### 3. 类型一致性

新增方法名统一为：

```swift
private func installContentViewController(_ controller: NSViewController)
```

所有调用点均使用同一名称。

### 4. 验证完整性

每个任务均包含：

- 构建命令
- 手动运行步骤
- 明确预期结果
- 完成标志

没有使用任何测试框架。没有安排任何 Git 操作。

---

## 执行交接

计划已完成并保存到：

```plain
docs/flare/20260624_window_size_restore_v2.md
```

两种执行选项：

**1. 子代理驱动（推荐）** —— 为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。

**2. 内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

选择哪种方式？
