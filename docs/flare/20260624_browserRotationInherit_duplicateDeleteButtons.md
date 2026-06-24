# 浏览器旋转继承（已处理集合方案）+ duplicate 双侧删除按钮 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 让浏览器分组旋转某张后翻页时角度逐张继承并持久化，但已处理过的照片回翻时不被再次覆盖；给 duplicate 对比页左右各加一个「点哪删哪」的删除按钮。

**架构：** 两个独立需求，拆为三个单文件任务。Task 1 改 `photoBrowserViewModel`，用 `carriedRotation`（惯性角度）+ `handledPhotoIds`（已处理集合）实现「带过去落盘 + 回翻不覆盖」。Task 2 给 `photoMetalViewController` 暴露只读布局锚点 `contentTopAnchor`。Task 3 在 `duplicateCompareViewController` 加左右删除按钮，复用既有 `keepLeft`/`keepRight`。Task 1 与 Task 2 无依赖可并行；Task 3 依赖 Task 2（用到 `contentTopAnchor`）。

**技术栈：** Swift / AppKit / Xcode（macOS GUI app，scheme `pickpick`）

**日志策略（最小日志）：** 沿用既有基础设施，不新增日志输出。`appDebugLogger` 已受 `--debug` 命令行参数控制（`appDebugLogger.isEnabled` 检查 `CommandLine.arguments.contains("--debug")`），手动验证时可带 `--debug` 启动以查看控制台输出；失败路径用既有 `appFileLogger.log(_:level:.error)` 写文件日志。

---

## 文件结构

| 文件 | 任务 | 职责 / 改动 |
| --- | --- | --- |
| `rawViewer/browser/photoBrowserViewModel.swift` | Task 1 | 新增 `carriedRotation` 惯性 + `handledPhotoIds` 已处理集合；旋转设惯性+入集；导航切换时只对未入集照片继承落盘+入集 |
| `rawViewer/views/photoMetalViewController.swift` | Task 2 | 新增只读 `contentTopAnchor` 锚点（= fileNameBar.bottomAnchor），供外部按钮紧贴文件名栏下方布局 |
| `rawViewer/duplicate/duplicateCompareViewController.swift` | Task 3 | 新增左右删除按钮（点哪删哪）、action、启用状态、布局约束 |

**依赖关系：** Task 1 ⟂ Task 2（可并行）；Task 3 → 依赖 Task 2。

**版本号（按项目约定小版本递增并更新文件头 Description）：**
- `photoBrowserViewModel.swift`：v1.2 → v1.3
- `photoMetalViewController.swift`：v1.4 → v1.5
- `duplicateCompareViewController.swift`：v3.8 → v3.9

**构建命令（全部任务统一使用）：**
```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
# 预期末行：** BUILD SUCCEEDED **
```

---

## Task 1: 浏览器旋转带过去（已处理集合方案，`photoBrowserViewModel.swift`）

**目标：** 在任意分组浏览照片时，旋转某张后，上/下翻页切到的每张照片都继承该旋转角度并落盘；但已处理过的照片（手动转过或已被惯性带过）回翻时不被再次覆盖，保留各自已存角度；不旋转直接浏览则不破坏各张已有角度。

**涉及的文件：**
- `rawViewer/browser/photoBrowserViewModel.swift` — 浏览器视图模型，新增惯性角度 + 已处理集合

### Step 1 — 实现

本任务对该文件有 8 处改动，逐一精确替换。

- [ ] **1.1 更新文件头（v1.2 → v1.3）**

找到：
```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 浏览器视图模型：封装 photos/currentIndex/checkedPhotoIds/displaySource 状态，支持 Restore Normal 和展示旋转状态同步；
并通过单调递增的 currentRequestId 让控制器在异步预加载完成时识别请求是否已被新的导航覆盖，
避免在快速上下切换时把陈旧的 JPG/RAW 结果渲染到当前主图上；
集成 photoTrashService，删除时先移入废纸篓再标记 JSON 状态
*/
```
替换为：
```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-24
Description: 浏览器视图模型：封装 photos/currentIndex/checkedPhotoIds/displaySource 状态，支持 Restore Normal 和展示旋转状态同步；
并通过单调递增的 currentRequestId 让控制器在异步预加载完成时识别请求是否已被新的导航覆盖，
避免在快速上下切换时把陈旧的 JPG/RAW 结果渲染到当前主图上；
集成 photoTrashService，删除时先移入废纸篓再标记 JSON 状态；
新增 carriedRotation 惯性角度 + handledPhotoIds 已处理集合：旋转某张后翻页逐张继承并落盘，已处理照片回翻不覆盖
*/
```

- [ ] **1.2 新增 `carriedRotation` 与 `handledPhotoIds` 属性**

找到：
```swift
    public private(set) var currentRequestId: Int = 0
    private let store: jsonReviewStateStoring
```
替换为：
```swift
    public private(set) var currentRequestId: Int = 0
    public private(set) var carriedRotation: Int?  // nil = 尚未开始带旋转
    public private(set) var handledPhotoIds: Set<String> = []  // 已处理照片（手动转过或已被惯性带过），回翻不再覆盖
    private let store: jsonReviewStateStoring
```

- [ ] **1.3 改造 `movePrevious()`**

找到：
```swift
    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
        currentRequestId += 1
    }
```
替换为：
```swift
    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

- [ ] **1.4 改造 `moveNext()`**

找到：
```swift
    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        currentRequestId += 1
    }
```
替换为：
```swift
    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

- [ ] **1.5 改造 `setCurrentIndex(_:)`**

找到：
```swift
    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        currentRequestId += 1
    }
```
替换为：
```swift
    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

- [ ] **1.6 改造 `rotateCurrentPhoto` 并新增 `applyCarriedRotationIfNeeded`**

找到：
```swift
    @discardableResult
    public func rotateCurrentPhoto(direction: photoRotationDirection) throws -> Int? {
        guard let photo = currentPhoto else { return nil }
        let newRotation = rotatedDegrees(photo.rotationDegrees, direction: direction)
        try store.setRotations([photo.photoId: newRotation])
        photos[currentIndex].rotationDegrees = newRotation
        currentRequestId += 1
        return newRotation
    }
```
替换为：
```swift
    @discardableResult
    public func rotateCurrentPhoto(direction: photoRotationDirection) throws -> Int? {
        guard let photo = currentPhoto else { return nil }
        let base = carriedRotation ?? photo.rotationDegrees
        let newRotation = rotatedDegrees(base, direction: direction)
        try store.setRotations([photo.photoId: newRotation])
        carriedRotation = newRotation
        handledPhotoIds.insert(photo.photoId)
        photos[currentIndex].rotationDegrees = newRotation
        currentRequestId += 1
        return newRotation
    }

    /// 导航切到新当前照片时，若已开始带旋转且该照片未被处理过，则把 carriedRotation 继承到该照片并落盘。
    /// 已处理照片（手动转过或已被惯性带过）跳过，保留用户为它设定的角度——这是回翻不覆盖的关键。
    /// 失败只记日志、不阻断导航；此时内存角度未更新、该照片未入 handledPhotoIds，下次切换会再尝试，可自愈。
    private func applyCarriedRotationIfNeeded() {
        guard let carried = carriedRotation else { return }
        guard photos.indices.contains(currentIndex) else { return }
        let photo = photos[currentIndex]
        guard !handledPhotoIds.contains(photo.photoId) else { return }
        do {
            try store.setRotations([photo.photoId: carried])
            photos[currentIndex].rotationDegrees = carried
            handledPhotoIds.insert(photo.photoId)
        } catch {
            appFileLogger.log("carry rotation failed photoId=\(photo.photoId) rotation=\(carried) error=\(error.localizedDescription)", level: .error)
        }
    }
```

- [ ] **1.7 改造 `restoreNormalTargetsAndUpdateList()`**

> 消歧说明：`restoreNormalTargetsAndUpdateList` 与 `confirmDelete` 的尾部代码（`photos.removeAll { ids.contains($0.photoId) }` … `currentRequestId += 1`）完全相同，单独匹配会不唯一。因此本步 oldText 包含上方独有的 `try store.restoreNormal(photoIds: ids)` 一行来唯一锁定 `restoreNormalTargetsAndUpdateList`（1.8 则用整块含方法签名消歧）。

找到：
```swift
        try store.restoreNormal(photoIds: ids)

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }
```
替换为：
```swift
        try store.restoreNormal(photoIds: ids)

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

- [ ] **1.8 改造 `confirmDelete()`**

找到（整块，含方法签名，唯一）：
```swift
    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets {
            try trashService.trash(photo)
        }

        let ids = Set(targets.map(\.photoId))
        try store.update { items in
            for index in items.indices where ids.contains(items[index].photoId) {
                items[index].reviewStatus = .trashed
            }
        }

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }
```
替换为：
```swift
    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets {
            try trashService.trash(photo)
        }

        let ids = Set(targets.map(\.photoId))
        try store.update { items in
            for index in items.indices where ids.contains(items[index].photoId) {
                items[index].reviewStatus = .trashed
            }
        }

        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        applyCarriedRotationIfNeeded()
        currentRequestId += 1
    }
```

### Step 2 — 运行验证

- [ ] **2.1 构建通过**

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
# 预期：** BUILD SUCCEEDED **
```

- [ ] **2.2 手动 GUI 验证（关键输出符合预期）**

启动 app（任选其一）：
```bash
# 方式 A：直接带 --debug 启动，可在终端看到 appDebugLogger 输出
/Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-*/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
# 方式 B：在 Xcode 打开 rawViewer.xcodeproj 按 ⌘R 运行
```
操作与预期（建议用一个含横竖混合的分组）：
1. **不旋转直接浏览**：进任意分组（如 Overexposed），不上/下翻前不旋转 → 直接按 ↓ 翻几张 → 预期：各张显示各自原有角度，未被改动（carriedRotation 为 nil，全程不写盘）。
2. **旋转后继承落盘**：回到第 1 张，点 ⟲ 90° → 按 ↓ 翻 2~3 张 → 预期：翻到的每张都显示 90°（继承惯性并落盘）。
3. **中途再转更新惯性**：翻到某张再点 ⟲ 90°（累计 180°）→ 继续下翻 → 预期：之后翻到的继承 180°。
4. **回翻不覆盖（核心）**：在步骤 3 之后，按 ↑ 回翻到之前翻过的照片 → 预期：它们保持各自已存角度（步骤2 翻过的=90°、步骤3 起翻过的=180°），**不被当前惯性再次覆盖**。
5. **横竖手动纠正且持久**：若某张是竖图被带成 90° 显歪，手动右转回正 → 预期：该张存 0°；继续翻页再回翻到它，仍是 0°（已处理，不覆盖）。
6. **旋转后删除**：旋转后按 Backspace 弹窗点 Delete → 预期：新当前照片继承当前惯性角度（若未处理过）。
7. 失败路径（正常不会触发）：若日志目录 `~/Library/Application Support/rawViewer/logs/` 当天日志出现 `carry rotation failed ... level=error`，说明某次继承写盘失败（中间态可自愈，不阻断）。

✅ **完成标志：** 构建出现 `** BUILD SUCCEEDED **`；app 启动无崩溃；上述操作 1~6 的观察与预期一致，尤其操作 4 的回翻不覆盖行为。

---

## Task 2: `photoMetalViewController` 暴露 `contentTopAnchor` 锚点

**目标：** 在 `photoMetalViewController` 上暴露一个只读布局锚点 `contentTopAnchor`（指向 fileNameBar 底部），供 Task 3 的删除按钮紧贴动态高度的文件名栏下方布局，不改变任何渲染行为。

**涉及的文件：**
- `rawViewer/views/photoMetalViewController.swift` — Metal 图片视图控制器，新增只读锚点

### Step 1 — 实现

- [ ] **1.1 更新文件头（v1.4 → v1.5）**

找到：
```swift
/*
Author: wilbur
Version: 1.4
Date: 2026-06-18
Description: Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；修正顶部坐标渲染下的向上拖拽方向；新增图片区域顶部文件名栏
*/
```
替换为：
```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-24
Description: Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；修正顶部坐标渲染下的向上拖拽方向；新增图片区域顶部文件名栏；新增 contentTopAnchor 锚点供外部按钮紧贴文件名栏下方布局
*/
```

- [ ] **1.2 新增 `contentTopAnchor` 计算属性**

找到：
```swift
    public var currentZoom: Double { metalView.currentZoom }

    public var onZoomChanged: ((Double) -> Void)? {
```
替换为：
```swift
    public var currentZoom: Double { metalView.currentZoom }

    /// 图片区顶部锚点（fileNameBar 底部），供外部按钮紧贴文件名栏下方布局。
    /// fileNameBar 高度随 setDisplayName 动态变化（有名字 30、无名字 0），用此锚点可避免固定偏移导致悬空。
    public var contentTopAnchor: NSLayoutYAxisAnchor { fileNameBar.bottomAnchor }

    public var onZoomChanged: ((Double) -> Void)? {
```

### Step 2 — 运行验证

- [ ] **2.1 构建通过**

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
# 预期：** BUILD SUCCEEDED **
```

> 本任务仅暴露一个只读锚点，无可独立观察的运行时行为；构建通过即证明 API 正确存在且 `fileNameBar`（private）可在类内访问。该锚点将在 Task 3 被删除按钮约束使用。

✅ **完成标志：** 构建出现 `** BUILD SUCCEEDED **`。

---

## Task 3: duplicate 对比页双侧删除按钮（`duplicateCompareViewController.swift`）

**目标：** 在 duplicate 对比页左右各加一个删除按钮，点左删除按钮删左图、点右删除按钮删右图（「点哪删哪」）；底层复用既有 `keepLeft`/`keepRight`，删除后流转与 ←/→ 方向键一致。

**涉及的文件：**
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 重复照片双图比较界面，新增双侧删除按钮

> **语义提醒（务必区分）：** 删除按钮是「点哪删哪」——`deleteLeftClicked` 调 `keepRight()`（删左留右）、`deleteRightClicked` 调 `keepLeft()`（删右留左）。这与 ←/→ 方向键「按哪留哪」（← 调 `keepLeft`、→ 调 `keepRight`）**语义相反**。不要按字面把「删左」对到 `keepLeft`，那会删错方向。

**前置依赖：** Task 2 已完成（`photoMetalViewController.contentTopAnchor` 已存在）。

### Step 1 — 实现

- [ ] **1.1 更新文件头（v3.8 → v3.9）**

找到：
```swift
/*
Author: wilbur
Version: 3.8
Date: 2026-06-17
Description: 重复照片双图比较界面，按左右任意一侧 JPG/RAW 文件存在性控制对应 segment；旋转按钮改为旋转当前 duplicate 组剩余照片，确保新顶替照片继承旋转状态；左右图无后缀文件名栏
*/
```
替换为：
```swift
/*
Author: wilbur
Version: 3.9
Date: 2026-06-24
Description: 重复照片双图比较界面，按左右任意一侧 JPG/RAW 文件存在性控制对应 segment；旋转按钮改为旋转当前 duplicate 组剩余照片，确保新顶替照片继承旋转状态；左右图无后缀文件名栏；新增左右双侧删除按钮（点哪删哪，复用 keepLeft/keepRight）
*/
```

- [ ] **1.2 新增两个删除按钮属性**

找到：
```swift
    private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
    private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
    private var leftPhotoController: photoMetalViewController!
```
替换为：
```swift
    private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
    private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
    private var leftDeleteButton = NSButton(title: "🗑", target: nil, action: nil)
    private var rightDeleteButton = NSButton(title: "🗑", target: nil, action: nil)
    private var leftPhotoController: photoMetalViewController!
```

- [ ] **1.3 在 `loadView` 中创建并布局删除按钮**

找到（`root.addSubview(splitView)` 到 `view = root` 之间的约束块）：
```swift
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
    }
```
替换为：
```swift
        root.addSubview(toolbar)
        root.addSubview(splitView)

        // 双侧删除按钮：点哪删哪（左按钮删左图、右按钮删右图），与 ←/→ 方向键「按哪留哪」相反
        leftDeleteButton.target = self
        leftDeleteButton.action = #selector(deleteLeftClicked)
        leftDeleteButton.bezelStyle = .rounded
        leftDeleteButton.toolTip = "Delete left photo"
        leftDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        rightDeleteButton.target = self
        rightDeleteButton.action = #selector(deleteRightClicked)
        rightDeleteButton.bezelStyle = .rounded
        rightDeleteButton.toolTip = "Delete right photo"
        rightDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(leftDeleteButton)
        root.addSubview(rightDeleteButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            leftDeleteButton.topAnchor.constraint(equalTo: leftPhotoController.contentTopAnchor, constant: 8),
            leftDeleteButton.leadingAnchor.constraint(equalTo: leftPhotoController.view.leadingAnchor, constant: 12),
            rightDeleteButton.topAnchor.constraint(equalTo: rightPhotoController.contentTopAnchor, constant: 8),
            rightDeleteButton.trailingAnchor.constraint(equalTo: rightPhotoController.view.trailingAnchor, constant: -12)
        ])

        view = root
    }
```

- [ ] **1.4 扩展 `updateActionButtons()` 启用/禁用删除按钮**

找到：
```swift
    private func updateActionButtons() {
        let hasPhoto = viewModel.mainPhoto != nil || viewModel.candidatePhoto != nil
        rotateLeftButton.isEnabled = hasPhoto
        rotateRightButton.isEnabled = hasPhoto
    }
```
替换为：
```swift
    private func updateActionButtons() {
        let hasLeft = viewModel.mainPhoto != nil
        let hasRight = viewModel.candidatePhoto != nil
        let hasPhoto = hasLeft || hasRight
        rotateLeftButton.isEnabled = hasPhoto
        rotateRightButton.isEnabled = hasPhoto
        leftDeleteButton.isEnabled = hasLeft
        rightDeleteButton.isEnabled = hasRight
    }
```

- [ ] **1.5 新增两个删除 action**

找到（`rotateCurrentPair` 方法结束到 `keepBothClicked` 之间）：
```swift
        }
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
```
替换为：
```swift
        }
    }

    @objc private func deleteLeftClicked() {
        do {
            let result = try viewModel.keepRight()   // 点左 → 删左留右
            handleActionResult(result)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func deleteRightClicked() {
        do {
            let result = try viewModel.keepLeft()    // 点右 → 删右留左
            handleActionResult(result)
        } catch {
            showErrorAlert(message: error.localizedDescription)
        }
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
```

> ⚠️ 1.5 的 oldText（`        }\n    }\n\n    @objc private func keepBothClicked(_ sender: NSButton) {`）需确认唯一。`rotateCurrentPair` 是其上方紧邻方法，`}` 收尾后紧接 `keepBothClicked`，该三行组合在文件中唯一。若编辑器提示不唯一，把 oldText 向上扩展包含 `rotateCurrentPair` 的 `do { ... } catch { ... }` 收尾行以保证唯一。

### Step 2 — 运行验证

- [ ] **2.1 构建通过**

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
# 预期：** BUILD SUCCEEDED **
```

- [ ] **2.2 手动 GUI 验证（关键输出符合预期）**

启动 app（任选其一）：
```bash
# 方式 A：带 --debug 启动
/Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-*/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
# 方式 B：Xcode 中 ⌘R 运行
```
操作与预期（需有含 ≥2 张的 duplicate 分组）：
1. **点左删除按钮删左图**：进一个 >2 张的 duplicate 分组对比页 → 点左上角 🗑 → 预期：左图被删，原右图前移到左、加载新右图，继续比较。
2. **点右删除按钮删右图**：点右上角 🗑 → 预期：右图被删，左图保留，新右图顶替，继续比较。
3. **方向相反确认**：对比 ←/→ 方向键——按 ← 是「删右留左」、按 → 是「删左留右」，与按钮「点左删左 / 点右删右」相反，验证二者各自方向正确。
4. **==2 张边界**：进一个恰好 2 张的 duplicate 分组 → 点任一删除按钮 → 预期：剩余一张标记 kept、回到分组页（`.finished`）。
5. **禁用态**：若某侧无照片（如 ==1 张的异常组），对应删除按钮灰显不可点。

✅ **完成标志：** 构建出现 `** BUILD SUCCEEDED **`；app 启动无崩溃；操作 1~4 的观察与预期一致，按钮方向「点哪删哪」正确。

---

## 自我复审

**1. 规范覆盖：**
- recipe 需求 1（浏览器旋转带过去，已处理集合方案）→ Task 1（carriedRotation + handledPhotoIds + applyCarriedRotationIfNeeded + 5 个导航接线点：movePrevious/moveNext/setCurrentIndex/confirmDelete/restoreNormalTargetsAndUpdateList）。✅
- recipe 需求 2（duplicate 双侧删除按钮）→ Task 2（contentTopAnchor 锚点）+ Task 3（按钮/action/布局/启用状态）。✅
- recipe「不改 duplicate 旋转逻辑 / 不加二次确认 / 不改删除弹窗」→ 计划未触碰这些，符合非目标。✅
- recipe 版本号 → Task 1/2/3 文件头分别 v1.3 / v1.5 / v1.9，已写入。✅

**2. 占位符扫描：** 无 TODO/TBD/「类似 Task N」/省略号；每处改动均给出完整 oldText/newText 代码块。✅

**3. 类型一致性：**
- `carriedRotation: Int?`（Task 1.2 定义）→ Task 1.6 `rotateCurrentPhoto` 用 `carriedRotation ?? photo.rotationDegrees`、`applyCarriedRotationIfNeeded` 用 `guard let carried = carriedRotation`。类型一致。✅
- `handledPhotoIds: Set<String>`（Task 1.2 定义）→ Task 1.6 旋转方法 `handledPhotoIds.insert`、`applyCarriedRotationIfNeeded` 用 `!handledPhotoIds.contains`。类型一致。✅
- `applyCarriedRotationIfNeeded()`（Task 1.6 定义，private）→ Task 1.3/1.4/1.5/1.7/1.8 五处调用，方法名拼写一致。✅
- `contentTopAnchor`（Task 2.2 定义，`NSLayoutYAxisAnchor`）→ Task 3.3 约束用 `leftPhotoController.contentTopAnchor`（`photoMetalViewController` 实例）、`constraint(equalTo:constant:)`。类型与 API 一致。✅
- `leftDeleteButton`/`rightDeleteButton`（Task 3.2 定义）→ Task 3.3 布局、3.4 启用、3.5 action 引用一致。✅
- `deleteLeftClicked`/`deleteRightClicked`（Task 3.5 定义）→ Task 3.3 的 `#selector(deleteLeftClicked)`/`#selector(deleteRightClicked)` 一致。✅
- `keepRight`/`keepLeft`（既有 `duplicateCompareViewModel` 方法）→ Task 3.5 调用，签名 `throws -> duplicateCompareActionResult`，与 `handleActionResult(_:)` 入参一致。✅

**4. 验证完整性：**
- Task 1：构建命令 + BUILD SUCCEEDED 预期 + 7 步手动 GUI 观察点（含核心的回翻不覆盖、横竖手动纠正、失败日志检查路径）。完成标志明确。✅
- Task 2：构建命令 + BUILD SUCCEEDED 预期 + 说明无可独立观察行为。完成标志明确。✅
- Task 3：构建命令 + BUILD SUCCEEDED 预期 + 5 步手动 GUI 观察点（含方向相反确认、边界、禁用态）。完成标志明确。✅

**复审结论：** 计划完整，无遗漏，无占位符，类型/方法名跨任务一致，每个任务有构建验证 + 明确完成标志。
