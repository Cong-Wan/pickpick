# pickpick 三大 High 问题修复 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复代码审查报告（`docs/codeReview/260625_full_module_review.md`）中的 Top 3 High 问题：删除流程不原子产生幽灵照片、主线程同步磁盘 JSON 解码导致卡顿、RAW 分析并发内存峰值过高。

**架构：** 三个任务相互独立、可顺序执行。Task 1 收口"文件删除与状态落盘"的顺序（状态先于文件动作）。Task 2 给磁盘读取增加异步入口，让 UI 路径不再在主线程同步阻塞。Task 3 通过降低默认并发数 + 把 CPU 不读的 GPU 缓冲改为私有内存，降低分析期瞬时内存峰值。三者改动的文件互不重叠。

**技术栈：** Swift 5.9+ / AppKit / Metal / Swift Concurrency（async-await）。项目为 Xcode 工程（`rawViewer.xcodeproj`，scheme = `pickpick`）。

**日志约定（精简模式）：** 所有新增日志一律走项目已有的 `appDebugLogger`（仅 `--debug` 启动时输出）或 `appFileLogger`（写本地文件，用于关键失败）。不在关键节点之外加冗余打印。`--debug` 解析逻辑已在 `services/appDebugLogger.swift` 实现（`appDebugLogger.isEnabled` 检测 `CommandLine.arguments.contains("--debug")`），本计划复用，不重复实现。

**构建/运行命令（全文统一）：**

```bash
# 在项目根目录 /Users/wilbur/project/rawViewer 下执行
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期最后一行：** BUILD SUCCEEDED **

# 运行（带调试日志）—— 在 Xcode 里 Run，或命令行：
$ open build/derived/Build/Products/Debug/pickpick.app --args --debug
# 或直接 open .app 后用 lldb/Console 看日志
```

---

## 涉及的文件结构

| 文件 | 任务 | 职责 | 改动性质 |
|------|------|------|----------|
| `rawViewer/services/photoTrashService.swift` | T1 | 照片文件移入废纸篓 | 修改 `trash(_:)` 为尽力删两文件 |
| `rawViewer/browser/photoBrowserViewModel.swift` | T1 | 浏览器删除 | 修改 `confirmDelete()` 顺序 |
| `rawViewer/duplicate/duplicateCompareViewModel.swift` | T1 | 重复对比删除 | 修改 `keepLeft()` / `keepRight()` 顺序 |
| `rawViewer/services/analysisStore.swift` | T2 | JSON 持久化 | 新增 `loadAsync(for:expectedConfig:)` |
| `rawViewer/services/photoAnalysisService.swift` | T2 | 分析编排 | 新增 `loadRecordsAsync(folderUrl:)`（协议+实现） |
| `rawViewer/appCoordinator.swift` | T2 | 导航协调 | 新增 `reloadFromDiskThenShowGroups()`，改 3 处 UI 路径 |
| `rawViewer/services/analysisConfig.swift` | T3 | 分析配置 | `defaults.metalConcurrency` 6→3 |
| `rawViewer/services/configLoader.swift` | T3 | 配置解析 | 并发 clamp 上限 8→4 |
| `rawViewer/config.yaml` | T3 | 打包配置 | `metal_concurrency` 6→3 |
| `rawViewer/services/rawBayerAnalyzer.swift` | T3 | RAW 分析 | `greenBuffer`/`lapBuffer` → `.private` |
| `rawViewer/services/jpgAnalyzer.swift` | T3 | JPG 分析 | `grayBuffer`/`lapBuffer` → `.private` |

---

## Task 1: 删除流程原子化，消除幽灵照片

**目标：** 让"删除照片"在批量失败或单文件失败时，磁盘文件状态与 `analysis.json` 状态始终一致——即 JSON 里标成 `trashed` 的照片一定不会在分组里以"正常照片"形式出现却加载不出图。核心原则：**状态先于文件动作落盘**。

**涉及的文件：**

- `rawViewer/services/photoTrashService.swift` — `trash(_:)` 改为对单张照片的 jpg/raw 两个文件都尽力尝试删除，最后再统一抛错，避免"删了 jpg 没删 raw 就 throw 打断"
- `rawViewer/browser/photoBrowserViewModel.swift` — `confirmDelete()` 改为先把目标状态落盘为 `trashed`，再逐张删文件（尽力），失败不阻断已成功者
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — `keepLeft()` / `keepRight()` 同样改为状态先落盘、文件后删

---

### Step 1 — 实现

#### 1.1 修改 `rawViewer/services/photoTrashService.swift`

把 `trash(_:)` 当前的"遇错即 throw、剩余文件不再尝试"改为"两文件都尝试、收集失败路径、最后统一抛错"。`photoTrashError` / 协议签名 / `cleanupTrashedPhotos` 不变。

定位现有 `trash(_ photo: photoItem) throws` 整个函数（当前从 `public func trash(_ photo: photoItem) throws {` 到对应的 `}`），整段替换为：

```swift
    public func trash(_ photo: photoItem) throws {
        let paths = [photo.jpgPath, photo.rawPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let fm = FileManager.default
        var failedPaths: [String] = []
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                var resultUrl: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
            } catch {
                // 尽力删：记录失败路径，继续尝试同照片的其它文件，
                // 避免删了 jpg、raw 因权限失败就立刻 throw 把 jpg 留在半删状态。
                failedPaths.append(path)
                appFileLogger.log("trashItem failed path=\(path) error=\(error.localizedDescription)", level: .error)
            }
        }
        if !failedPaths.isEmpty {
            throw photoTrashError.trashFailed(
                path: failedPaths.joined(separator: ", "),
                underlying: NSError(
                    domain: "rawViewer.photoTrashService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to trash file(s): \(failedPaths.joined(separator: ", "))"]
                )
            )
        }
    }
```

> 说明：`photoTrashError.trashFailed(path:underlying:)` 的 `path` 参数本来就是描述性字符串（调用方只用 `error.localizedDescription`），这里把多个失败路径拼进去不影响现有错误处理。

#### 1.2 修改 `rawViewer/browser/photoBrowserViewModel.swift`

定位 `confirmDelete()` 整个函数（当前从 `public func confirmDelete() throws {` 到对应 `}`），整段替换为：

```swift
    public func confirmDelete() throws {
        let targets = deleteTargets()
        let ids = Set(targets.map(\.photoId))
        guard !ids.isEmpty else { return }

        // 1. 先把目标状态落盘为 trashed —— 保证 JSON 永不落后于磁盘。
        //    即便后续文件删除失败，状态已是 trashed，下次启动 cleanupTrashedPhotos 会兜底删文件，
        //    不会出现"文件已删但状态还是 active"的幽灵照片。
        //    注意：只有这步会抛错（磁盘 IO 失败），届时 photos 尚未变更，VC catch 不刷新 UI 也安全。
        try store.update { items in
            for index in items.indices where ids.contains(items[index].photoId) {
                items[index].reviewStatus = .trashed
            }
        }

        // 2. 逐张删文件，尽力而为：失败只记日志，不抛错。
        //    状态已 trashed，文件若未删成功，下次启动 cleanupTrashedPhotos 会兜底。
        //    刻意不抛错——与 duplicateCompareViewModel.keepLeft/keepRight 行为一致，
        //    让 photoBrowserViewController.deleteClicked 始终走 do 成功路径刷新 UI，
        //    避免"部分成功时抛错进 catch、列表不刷新"导致 UI/内存不一致。
        for photo in targets {
            do {
                try trashService.trash(photo)
            } catch {
                appFileLogger.log("delete photo failed photoId=\(photo.photoId) error=\(error.localizedDescription)", level: .error)
            }
        }

        // 3. 从内存列表移除全部目标（状态已正确落盘，缺失文件由启动时 cleanup 兜底，不会产生幽灵照片）
        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

#### 1.3 修改 `rawViewer/duplicate/duplicateCompareViewModel.swift`

`keepBoth()` 和 `markFinalKept(_:)` 不删文件，无需改动。只改 `keepLeft()` 和 `keepRight()`。

**注意一个语义点：** 原代码在 `photos.removeAll` **之后**才计算 `let shouldFinish = photos.count == 1`。新代码要把状态落盘提到 `removeAll` **之前**，因此 `shouldFinish` 要在删之前算：删掉一张后剩 `photos.count - 1` 张，`shouldFinish` 等价于 `photos.count - 1 == 1`，即 `photos.count == 2`。

定位 `keepLeft()` 整个函数，替换为：

```swift
    public func keepLeft() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        let shouldFinish = photos.count == 2

        // 1. 先落盘状态（right→trashed；若为组内最后一张，left→kept + 写 template）
        try store.update { items in
            if let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
                items[rightIndex].reviewStatus = .trashed
            }
            if shouldFinish, let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
                items[leftIndex].reviewStatus = .kept
                if !left.reviewGroupId.isEmpty {
                    for index in items.indices where items[index].reviewGroupId == left.reviewGroupId {
                        items[index].templatePhotoId = left.photoId
                    }
                    items[leftIndex].reviewGroupId = ""
                }
            }
        }

        // 2. 再删文件（尽力删，失败记日志；状态已落盘不会幽灵）
        do {
            try trashService.trash(right)
        } catch {
            appFileLogger.log("keepLeft trash failed photoId=\(right.photoId) error=\(error.localizedDescription)", level: .error)
        }

        // 3. 更新内存
        photos.removeAll { $0.photoId == right.photoId }
        if shouldFinish { return .finished }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
```

定位 `keepRight()` 整个函数，替换为（与 keepLeft 对称）：

```swift
    public func keepRight() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        let shouldFinish = photos.count == 2

        // 1. 先落盘状态（left→trashed；若为组内最后一张，right→kept + 写 template）
        try store.update { items in
            if let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
                items[leftIndex].reviewStatus = .trashed
            }
            if shouldFinish, let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
                items[rightIndex].reviewStatus = .kept
                if !right.reviewGroupId.isEmpty {
                    for index in items.indices where items[index].reviewGroupId == right.reviewGroupId {
                        items[index].templatePhotoId = right.photoId
                    }
                    items[rightIndex].reviewGroupId = ""
                }
            }
        }

        // 2. 再删文件（尽力删，失败记日志；状态已落盘不会幽灵）
        do {
            try trashService.trash(left)
        } catch {
            appFileLogger.log("keepRight trash failed photoId=\(left.photoId) error=\(error.localizedDescription)", level: .error)
        }

        // 3. 更新内存
        photos.removeAll { $0.photoId == left.photoId }
        if shouldFinish { return .finished }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
```

---

### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
```

构建通过后，做一次行为验证（精简日志已就位，用 `--debug` 启动可观察顺序）：

1. 用 `--debug` 启动 app，加载一个含照片的文件夹。
2. 进入任意分组，勾选 2 张照片，按 Backspace 删除 → 在弹窗里确认。
3. 观察 Console 日志：应能看到删除流程不再"先删文件后标状态"。删除成功后照片从列表消失。
4. 重复照片组里：按 ←（保留左侧，删右侧）/→（保留右侧，删左侧），确认被删一侧消失、流程继续或结束。

**关键预期：** 构建通过；删除操作正常生效；日志中失败路径（若有）走 `appFileLogger` 记录而不再让整批回滚。即便人工难以构造"中间失败"，状态先落盘的顺序已能从代码静态确认（步骤 1 在前、步骤 2 在后）。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`trash` / `confirmDelete` / `keepLeft` / `keepRight` 四个函数均为"状态先落盘、文件后删、失败尽力收集"的结构；删除与重复对比的常规操作行为正常。

---

## Task 2: 主线程 JSON 解码异步化，消除导航卡顿

**目标：** 让"返回分组页 / 处理完重复组 / 启动时命中缓存"这三条 UI 路径在读取 `analysis.json` 时不再在主线程（`MainActor`）上同步阻塞 `ioQueue.sync`，避免大目录下 UI 冻结。读盘放到后台 `Task.detached`，回主线程后再刷新数据与界面。

**涉及的文件：**

- `rawViewer/services/analysisStore.swift` — 新增 `loadAsync(for:expectedConfig:)`，把同步 `load` 包进 `Task.detached`
- `rawViewer/services/photoAnalysisService.swift` — 协议 `photoAnalyzing` 与实现各加一个 `loadRecordsAsync(folderUrl:)`
- `rawViewer/appCoordinator.swift` — 新增私有异步入口 `reloadFromDiskThenShowGroups()`，替换 3 处会阻塞主线程的读盘调用

---

### Step 1 — 实现

#### 2.1 修改 `rawViewer/services/analysisStore.swift`

在现有 `load(for folderUrl: URL) throws` 和 `load(for folderUrl: URL, expectedConfig: analysisConfig) throws` 之后，新增一个异步入口。定位 `public func load(for folderUrl: URL, expectedConfig: analysisConfig) throws -> [photoItem] { ... }` 整个函数**结束之后**，插入：

```swift
    /// 异步读取：把磁盘解码放到后台，避免在 MainActor 上同步阻塞 ioQueue
    public func loadAsync(for folderUrl: URL, expectedConfig: analysisConfig? = nil) async throws -> [photoItem] {
        try await Task.detached(priority: .userInitiated) { [self] in
            if let expectedConfig {
                return try self.load(for: folderUrl, expectedConfig: expectedConfig)
            }
            return try self.load(for: folderUrl)
        }.value
    }
```

> 说明：`analysisStore` 是 `@unchecked Sendable`，所有读路径经 `ioQueue.sync` 串行化，`self` 在 `Task.detached` 中捕获是安全的。`expectedConfig` 为可选，对应两种已有同步重载。

#### 2.2 修改 `rawViewer/services/photoAnalysisService.swift`

**协议**：在 `public protocol photoAnalyzing: AnyObject {` 内，`func loadRecords(folderUrl: URL) throws -> [photoItem]` 这一行**之后**，新增一行：

```swift
    func loadRecordsAsync(folderUrl: URL) async throws -> [photoItem]
```

**实现**：在 `public func loadRecords(folderUrl: URL) throws -> [photoItem] { ... }` 整个函数**之后**，新增实现。直接复用 Task 2.1 在 store 层新增的 `loadAsync(for:expectedConfig:)`（store 层独占异步读盘，本层只负责先算 config 再委托），避免再包一个 `Task.detached` 造成重复与死代码：

```swift
    public func loadRecordsAsync(folderUrl: URL) async throws -> [photoItem] {
        let config = try cfgLoader.load(for: folderUrl)
        return try await store.loadAsync(for: folderUrl, expectedConfig: config)
    }
```

> 说明：`cfgLoader.load(for:)` 只读 bundle yaml 或返回默认值，很轻，留在调用线程；重的 `store.load` 解码在 `loadAsync` 内部用 `Task.detached` 跑到后台。`store`（`analysisStore.shared`）是 `@unchecked Sendable`，`config` 是 `Sendable` 值类型。

#### 2.3 修改 `rawViewer/appCoordinator.swift`

**2.3.1 新增异步读盘入口。** 定位现有 `private func reloadDataIgnoringError() { ... }` 整个函数，替换为下面两个函数（一个异步读盘入口 + 保留 `reloadDataIgnoringError` 供未来非 UI 路径，但内部不再被 UI 路径调用）：

```swift
    /// UI 路径统一入口：后台读取 analysis.json，回主线程后刷新 records 并进入分组页。
    /// 读盘放 Task.detached，避免在 MainActor 上同步阻塞 ioQueue 导致卡顿。
    private func reloadFromDiskThenShowGroups() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let folderUrl = self.currentFolderUrl else {
                self.showGroups()
                return
            }
            let loadedRecords: [photoItem]
            do {
                loadedRecords = try await self.analyzer.loadRecordsAsync(folderUrl: folderUrl)
            } catch {
                appDebugLogger.log("reloadData failed: \(error.localizedDescription)")
                loadedRecords = self.records
            }
            self.records = loadedRecords
            self.showGroups()
        }
    }

    private func reloadDataIgnoringError() {
        // 保留给非 UI 同步路径；当前 UI 路径已改用 reloadFromDiskThenShowGroups。
        do {
            try reloadData()
        } catch {
            appDebugLogger.log("reloadData failed: \(error.localizedDescription)")
        }
    }
```

**2.3.2 替换 `showBrowser` 的 onBack。** 定位 `showBrowser(group:)` 内：

```swift
        browser.onBack = { [weak self] in
            guard let self else { return }
            self.reloadDataIgnoringError()
            self.showGroups()
        }
```

替换为：

```swift
        browser.onBack = { [weak self] in
            self?.reloadFromDiskThenShowGroups()
        }
```

**2.3.3 替换 `showDuplicate` 的两个回调。** 定位 `showDuplicate(group:)` 内：

```swift
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
```

替换为：

```swift
        duplicate.onBack = { [weak self] in
            self?.reloadFromDiskThenShowGroups()
        }
        duplicate.onFinished = { [weak self] in
            self?.reloadFromDiskThenShowGroups()
        }
```

**2.3.4 替换 `startAnalysis` 缓存路径里两处同步读盘。** 定位 `startAnalysis(folderUrl:)` 内 `Task { @MainActor in do { ... }` 块。当前缓存命中分支：

```swift
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
```

替换为（把 `loadRecords` 改成 `loadRecordsAsync`）：

```swift
                if analysisStore.shared.hasResults(for: folderUrl) {
                    do {
                        let loadedRecords = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
                        self.records = loadedRecords
                        self.trashService.cleanupTrashedPhotos(self.records)
                        self.showGroups()
                        return
                    } catch {
                        appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
                    }
                }
```

同函数内，分析完成后的读盘：

```swift
                self.records = try analyzer.loadRecords(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
```

替换为：

```swift
                self.records = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
```

> 说明：`reloadData() throws` 与 `appCoordinating.reloadData()` 协议方法保留不动（外部无调用方，且保留向后兼容）。本任务只把 3 条 UI 路径切到异步入口。`startAnalysis` 本身已在 `Task { @MainActor }` 内，`await` 合法。

---

### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
```

构建通过后行为验证（`--debug` 启动）：

1. 加载一个照片较多的文件夹（几百张），完成分析进入分组页。
2. 点进任意分组，再点 `← Back` 返回分组页 → 返回应当即时响应，主线程不再被 JSON 解码阻塞。
3. 进入重复组，按 ← 处理完所有照片触发 `onFinished` 自动回分组页 → 同样即时。
4. 退出 app 重新打开同一文件夹（命中缓存）→ 进分组页的过程不卡顿。

**关键预期：** 构建通过；返回/完成回调即时返回分组页；大目录下不再出现明显卡顿。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`appCoordinator` 中 `showBrowser.onBack` / `showDuplicate.onBack` / `showDuplicate.onFinished` / `startAnalysis` 两处读盘均走 `loadRecordsAsync`（或 `reloadFromDiskThenShowGroups`），主线程不再出现对 `analyzer.loadRecords` 的同步调用；返回分组页即时响应。

---

## Task 3: 降低 RAW 分析并发内存峰值

**目标：** 把分析阶段（尤其是大目录 RAW 分析）的瞬时内存峰值从约 300–600 MB 降到约 150 MB 以内。手段：(a) 默认并发数 6→3，并把配置上限收紧到 4（GPU 在单 command queue 上 commit 本就串行，高并发 CPU 线程的内存放大收益有限）；(b) 把 CPU 不读取的 GPU 中间缓冲（green/lap/gray plane）从 `.storageModeShared` 改为 `.storageModePrivate`，减少常驻可映射内存、提升 GPU 访问效率。

**涉及的文件：**

> ⚠️ **两个副作用，实现前须知：**
>
> 1. **会让所有现有分析缓存失效、触发重新分析。** `metalConcurrency` 是 `analysisConfig` 的一部分，被写入每个文件夹的 `configSnapshot`（见 `analysisStore` 的 `load(for:expectedConfig:)`）。把它从 6 改为 3 后，所有已分析过的文件夹 `configSnapshot != 当前 config` → 抛 `staleConfigSnapshot` → `appCoordinator.startAnalysis` 走重新分析分支。这是 configSnapshot 机制的正确行为（配置变了就该重算，以保证结果与新配置一致），不是 bug，但需提前告知：用户下次打开旧文件夹会重新等一次分析。
>
> 2. **分析会变慢一点（内存换速度的权衡）。** 并发 6→3 会拖慢分析 wall-clock。由于 GPU commandBuffer 在单个 queue 上实际是串行 commit 的，CPU 并发减半的拖慢幅度通常小于 2×，但不会是 0。若实测后发现某机器分析明显变慢，可在照片文件夹内的 `config.yaml` 把 `metal_concurrency` 调到 **4**（Task 3.2 把上限收到 4）在内存与速度间取平衡。

- `rawViewer/services/analysisConfig.swift` — 默认并发数
- `rawViewer/services/configLoader.swift` — 并发 clamp 上限
- `rawViewer/config.yaml` — 打包进 bundle 的配置
- `rawViewer/services/rawBayerAnalyzer.swift` — `greenBuffer` / `lapBuffer` 改私有
- `rawViewer/services/jpgAnalyzer.swift` — `grayBuffer` / `lapBuffer` 改私有

---

### Step 1 — 实现

#### 3.1 修改 `rawViewer/services/analysisConfig.swift`

定位 `defaults` 静态属性里的 `metalConcurrency: 6,`，改为：

```swift
        metalConcurrency: 3,
```

#### 3.2 修改 `rawViewer/services/configLoader.swift`

定位 `let concurrency = min(max(rawConcurrency, 1), 8)`，改为：

```swift
        let concurrency = min(max(rawConcurrency, 1), 4)
```

#### 3.3 修改 `rawViewer/config.yaml`

定位 `metal_concurrency: 6`，改为：

```yaml
  metal_concurrency: 3
```

#### 3.4 修改 `rawViewer/services/rawBayerAnalyzer.swift`

把 `greenBuffer` 与 `lapBuffer` 两个 `makeBuffer` 的 `options: .storageModeShared` 改为 `.storageModePrivate`。这两块缓冲：`greenBuffer` 由 `bayerToGreenPlaneKernel` 写、被 `greenLaplacianKernel` 与 `rawGridHistogramKernel` 读（全部 GPU）；`lapBuffer` 由 `greenLaplacianKernel` 写、被 `reduceLaplacianPerTileKernel` 读（全部 GPU）。CPU 后处理只读 `histBuffer` / `gridHistBuffer` / `gridCountBuffer` / `perTileStatsBuffer`，不读这两块，改私有安全。

定位 `greenBuffer` 的创建：

```swift
        guard let greenBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc greenBuffer") }
```

改为：

```swift
        guard let greenBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModePrivate
        ) else { throw makeError("alloc greenBuffer") }
```

定位 `lapBuffer` 的创建：

```swift
        guard let lapBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }
```

改为：

```swift
        guard let lapBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModePrivate
        ) else { throw makeError("alloc lapBuffer") }
```

> 注意：`greenBuffer` / `lapBuffer` 当前都没有 `memset(...)` 调用（只有 `histBuffer` / `exposureBuffer` / `gridHistBuffer` / `gridCountBuffer` 有 memset，那几个保持 `.shared` 不变）。`.private` 缓冲无 `contents()`，本就不该 memset，所以无需删除任何 memset。

#### 3.5 修改 `rawViewer/services/jpgAnalyzer.swift`

同样把 `grayBuffer` 与 `lapBuffer` 改私有。`grayBuffer` 由 `rgbToGrayKernel` 写、被 `jpgHistogramKernel` / `jpgLaplacianKernel` / `jpgGridHistogramKernel` 读（全部 GPU）；`lapBuffer` 由 `jpgLaplacianKernel` 写、被 `reduceLaplacianPerTileKernel` 读（全部 GPU）。CPU 不读这两块。

定位 `grayBuffer` 的创建：

```swift
        guard let grayBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<UInt8>.size, options: .storageModeShared) else { throw makeError("alloc grayBuffer") }
```

改为：

```swift
        guard let grayBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<UInt8>.size, options: .storageModePrivate) else { throw makeError("alloc grayBuffer") }
```

定位 `lapBuffer` 的创建：

```swift
        guard let lapBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<Float>.size, options: .storageModeShared) else { throw makeError("alloc lapBuffer") }
```

改为：

```swift
        guard let lapBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<Float>.size, options: .storageModePrivate) else { throw makeError("alloc lapBuffer") }
```

> 注意：`jpgAnalyzer` 里 `grayBuffer` / `lapBuffer` 也没有 memset（memset 只在 `histBuffer` / `exposureBuffer` / `gridHistBuffer` / `gridCountBuffer`，保持 `.shared`）。

---

### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
```

构建通过后行为验证（`--debug` 启动）：

1. 准备一个含较多 RAW（如 50–200 张 rw2/cr2）的文件夹，用 `--debug` 启动 app 加载它。
2. 分析过程中打开"活动监视器"，选中 pickpick 进程，观察"内存"栏的峰值。
3. 分析完成后进入分组页，确认照片分组与曝光/虚焦判定与改动前一致（仅内存行为变化，分析结果不应改变——因为 kernel 读写逻辑未变，仅缓冲存储模式变了）。

**关键预期：** 构建通过；分析结果（分组数量、过曝/欠曝/虚焦判定）与改动前一致；分析期内存峰值较改动前明显下降（并发 6→3 约把瞬时驻留砍半，叠加 private 缓冲进一步减少可映射内存）。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`analysisConfig.defaults.metalConcurrency` == 3、`configLoader` clamp 上限 == 4、`config.yaml` metal_concurrency == 3；`rawBayerAnalyzer` 的 `greenBuffer`/`lapBuffer` 与 `jpgAnalyzer` 的 `grayBuffer`/`lapBuffer` 均为 `.storageModePrivate`；分析结果与改动前一致。

---

## 自我复审

**1. 规范覆盖（对照 review 报告 Top 3 High）：**
- 🟠 删除流程不原子 → Task 1（trash 尽力删 + confirmDelete/keepLeft/keepRight 状态先落盘）。✅
- 🟠 主线程同步 JSON 解码 → Task 2（loadAsync + loadRecordsAsync + reloadFromDiskThenShowGroups，覆盖 reloadData/onBack/onFinished/startAnalysis 缓存路径全部读盘点）。✅
- 🟠 RAW 内存峰值 → Task 3（降并发 6→3 + clamp 8→4 + green/lap/gray 改 private）。✅

**2. 占位符扫描：** 全文无 TODO / "稍后实现" / "类似 Task N"。每个 Step 1 都给出完整可粘贴代码块。✅

**3. 类型一致性：**
- `analysisStore.loadAsync(for:expectedConfig:)` 签名 → `photoAnalysisService.loadRecordsAsync` 复用 `store.loadAsync(for:expectedConfig:)`（已修正：初稿里 service 另包了一个 `Task.detached` 没复用，会造成 `loadAsync` 成死代码；现已统一走 store 层）。✅
- `photoAnalyzing.loadRecordsAsync(folderUrl:)` 协议方法与实现签名一致。✅
- `appCoordinator.reloadFromDiskThenShowGroups()` 内部调用 `analyzer.loadRecordsAsync(folderUrl:)` 一致。✅
- `photoTrashService.trash(_:)` 签名不变（仍 `throws`，无返回值），`photoTrashError.trashFailed(path:underlying:)` 枚举不变，三个调用方 do-catch 无需改类型。✅
- `confirmDelete` / `keepLeft` / `keepRight` 返回类型不变（`throws` / `duplicateCompareActionResult`），VC 调用方无需改。✅

**4. 验证完整性：** 每个任务都有 `xcodebuild ... build` 命令 + `** BUILD SUCCEEDED **` 预期 + 行为验证步骤 + 明确完成标志。✅

**5. 顺序独立性：** Task 1/2/3 改动文件互不重叠，可顺序执行也可独立执行。Task 2 与 Task 1 不冲突（不同文件）。Task 3 与前两者不同文件。✅

**6. 二次深度审核（对照真实源码逐行核对 anchor / 改动顺序 / 调用链副作用）：**
- [已修正] Task 2 DRY：初稿 `loadRecordsAsync` 自包 `Task.detached { store.load }`，未复用 `analysisStore.loadAsync`，后者沦为死代码。已改为复用 `store.loadAsync(for:expectedConfig:)`，store 层独占异步读盘。
- [已修正] Task 1 部分-成功 UI 不刷新：`photoBrowserViewController.deleteClicked` 的 catch 分支不调用 `thumbnailView.updatePhotos`；初稿 `confirmDelete` 在部分文件删除成功时改 `VM.photos` 又抛错 → 进 catch 不刷新 → UI/内存不一致。已改为 trash 失败只记日志不抛错（与 `keepLeft/keepRight` 一致），`confirmDelete` 仅 `store.update` 可能抛错（此时 photos 尚未变更，catch 不刷新也安全），VC 始终走 do 成功路径刷新。
- [已补说明] Task 3 副作用：改 `metalConcurrency` 6→3 会让所有 `configSnapshot` 失效触发重新分析；并发减半会拖慢分析。已在 Task 3 开头加「⚠️ 两个副作用」提示。
- [核对通过] `trash` / `confirmDelete` / `keepLeft` / `keepRight` / `reloadDataIgnoringError` / `showBrowser.onBack` / `showDuplicate.onBack`+`onFinished` / `startAnalysis` 两处读盘 / `greenBuffer`+`lapBuffer`+`grayBuffer` 的 anchor 文本与当前源码逐字匹配。✅
- [核对通过] `keepLeft` 语义转换：原 `shouldFinish = photos.count == 1`（removeAll 后）⟺ 新 `photos.count == 2`（removeAll 前）。✅
- [核对通过] Task 3 改 `.private` 的 4 个缓冲均无 `memset`（memset 只在 CPU 读回的 hist/grid/stats 缓冲，保持 `.shared`）；anchor 由变量名+error message 区分唯一。✅

---

## 执行交接

计划已完成并保存到 `docs/flare/20260625_top3_high_fixes.md`。两种执行选项：

1. **子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。
2. **内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

选择哪种方式？
