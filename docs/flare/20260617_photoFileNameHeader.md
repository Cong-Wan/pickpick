# 照片文件名顶部栏实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 在普通浏览页和 Duplicate 左右对比页的图片显示区域顶部显示无后缀文件名，并且不挤占现有 toolbar。

**架构：** 在复用的 `photoMetalViewController` 内增加文件名顶部栏和公开设置接口；在 `photoItem` 上提供稳定的无后缀文件名辅助属性；Browser 与 Duplicate 控制器只负责把当前照片的显示名传给对应图片控制器。

**技术栈：** Swift、AppKit、NSView/Auto Layout、现有 Xcode macOS app target `pickpick`

---

## 打印/日志策略

用户已选择不需要详细打印输出。本功能不新增任何打印或日志输出；保留现有 `appDebugLogger` / `appFileLogger` 调用不变。若后续调试需要新增输出，必须另行引入 `--debug` 控制后再添加。

## 文件结构

- `rawViewer/models/photoModels.swift` — `photoItem` 数据模型，新增稳定无后缀文件名辅助属性。
- `rawViewer/views/photoMetalViewController.swift` — 图片显示控制器，新增顶部文件名栏 UI 与 `setDisplayName(_:)` API。
- `rawViewer/browser/photoBrowserViewController.swift` — 普通浏览页，当前照片变化时设置主图文件名。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — Duplicate 对比页，左右照片变化时分别设置左右图文件名。

## 已确认 UI 规则

- 使用视觉伴侣确认的方案 A：图片区域顶部独立文件名栏。
- 普通浏览页：主图区域顶部显示当前照片文件名。
- Duplicate 页：左右图片区域顶部各自显示对应照片文件名。
- 文件名不显示后缀。
- 文件名不随 JPG/RAW 展示源切换而变化。
- 长文件名保持单行，超出区域省略。
- 不把文件名放进顶部 toolbar。

---

### Task 1: 为 photoItem 增加稳定无后缀显示名

**目标：** 任意 `photoItem` 都能产出一个稳定、无后缀、与 JPG/RAW 切换无关的显示文件名。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 新增 `displayFileName` 辅助属性。

------

#### Step 1 — 实现

- [ ] 打开 `rawViewer/models/photoModels.swift`。
- [ ] 将文件头版本从 `1.10` 更新为 `1.11`。
- [ ] 将 Description 更新为：

```text
固定生成 Normal 工作流分组，并让 duplicate 中已保留且分析未失败的 kept 照片按展示语义归入 Normal；新增无后缀稳定展示文件名辅助逻辑
```

- [ ] 在第一个 `nonisolated public extension photoItem` 中，放在 `hasExistingJpgFile` 之前，加入以下完整代码：

```swift
    var displayFileName: String {
        let name = URL(fileURLWithPath: stableDisplayPath).deletingPathExtension().lastPathComponent
        if !name.isEmpty { return name }
        let fallback = URL(fileURLWithPath: photoId).deletingPathExtension().lastPathComponent
        return fallback.isEmpty ? photoId : fallback
    }

    private var stableDisplayPath: String {
        if let rawPath, !rawPath.isEmpty { return rawPath }
        return jpgPath
    }
```

实现后的相关片段应是：

```swift
nonisolated public extension photoItem {
    var displayFileName: String {
        let name = URL(fileURLWithPath: stableDisplayPath).deletingPathExtension().lastPathComponent
        if !name.isEmpty { return name }
        let fallback = URL(fileURLWithPath: photoId).deletingPathExtension().lastPathComponent
        return fallback.isEmpty ? photoId : fallback
    }

    private var stableDisplayPath: String {
        if let rawPath, !rawPath.isEmpty { return rawPath }
        return jpgPath
    }

    func hasExistingJpgFile(fileManager: FileManager = .default) -> Bool {
        let ext = URL(fileURLWithPath: jpgPath).pathExtension.lowercased()
        guard ["jpg", "jpeg"].contains(ext) else { return false }
        return fileManager.fileExists(atPath: jpgPath)
    }

    func hasExistingRawFile(fileManager: FileManager = .default) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        let ext = URL(fileURLWithPath: rawPath).pathExtension.lowercased()
        guard ["rw2", "cr2"].contains(ext) else { return false }
        return fileManager.fileExists(atPath: rawPath)
    }
}
```

说明：

- 优先使用 `rawPath`，没有 RAW path 时使用 `jpgPath`。
- 只取 `lastPathComponent` 并去掉扩展名。
- 不读取当前 `displaySource`，确保 JPG/RAW 切换不改变文件名。
- 不新增日志。

------

#### Step 2 — 运行验证

运行构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过，终端输出包含 `BUILD SUCCEEDED`。
- 无 Swift 语法错误。
- 无新增运行时打印输出。

如果验证不通过，修复 `photoModels.swift` 后重复本步骤，直到通过。

------

✅ **完成的标志：** 构建通过，输出包含 `BUILD SUCCEEDED`。在满足此条件之前不要开始下一个任务。

------

### Task 2: 在 photoMetalViewController 中增加文件名顶部栏

**目标：** 图片显示区域具备可显示/隐藏的顶部文件名栏，名称为空时不占空间，名称非空时显示单行省略文本。

**涉及的文件：**

- `rawViewer/views/photoMetalViewController.swift` — 新增文件名栏 UI、约束和公开设置方法。

------

#### Step 1 — 实现

- [ ] 打开 `rawViewer/views/photoMetalViewController.swift`。
- [ ] 将文件头版本从 `1.2` 更新为 `1.3`。
- [ ] 将 Description 更新为：

```text
Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；新增图片区域顶部文件名栏
```

- [ ] 在 class 属性区，将：

```swift
    private let metalView = metalPhotoView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var panOffset: CGPoint = .zero
```

替换为：

```swift
    private let metalView = metalPhotoView()
    private let fileNameBar = NSView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var fileNameBarHeightConstraint: NSLayoutConstraint?
    private var panOffset: CGPoint = .zero
```

- [ ] 在 `loadView()` 中，替换当前从 `metalView.translatesAutoresizingMaskIntoConstraints = false` 到 `NSLayoutConstraint.activate([...])` 的布局代码。新的完整 `loadView()` 必须如下：

```swift
    public override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        fileNameBar.wantsLayer = true
        fileNameBar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        fileNameBar.isHidden = true
        fileNameBar.translatesAutoresizingMaskIntoConstraints = false

        fileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.alignment = .center
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.maximumNumberOfLines = 1
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        metalView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        fileNameBar.addSubview(fileNameLabel)
        container.addSubview(fileNameBar)
        container.addSubview(metalView)
        container.addSubview(errorLabel)

        let heightConstraint = fileNameBar.heightAnchor.constraint(equalToConstant: 0)
        fileNameBarHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            fileNameBar.topAnchor.constraint(equalTo: container.topAnchor),
            fileNameBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fileNameBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heightConstraint,

            fileNameLabel.centerYAnchor.constraint(equalTo: fileNameBar.centerYAnchor),
            fileNameLabel.leadingAnchor.constraint(equalTo: fileNameBar.leadingAnchor, constant: 12),
            fileNameLabel.trailingAnchor.constraint(equalTo: fileNameBar.trailingAnchor, constant: -12),

            metalView.topAnchor.constraint(equalTo: fileNameBar.bottomAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: metalView.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: metalView.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: metalView.trailingAnchor, constant: -24)
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        container.addGestureRecognizer(pan)

        view = container
    }
```

- [ ] 在 `// MARK: - 状态 API` 下方、`load(image:)` 之前，加入公开方法：

```swift
    public func setDisplayName(_ name: String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fileNameLabel.stringValue = trimmedName
        let shouldShowName = !trimmedName.isEmpty
        fileNameBar.isHidden = !shouldShowName
        fileNameBarHeightConstraint?.constant = shouldShowName ? 30 : 0
    }
```

- [ ] 在 `reset()` 中，将：

```swift
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        metalView.clearImage()
```

替换为：

```swift
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        setDisplayName(nil)
        metalView.clearImage()
```

说明：

- 顶部栏高度 30pt，符合视觉稿。
- 名称为空时高度为 0，不留下空白。
- `metalView` 从文件名栏下方开始，避免文件名栏遮挡图片。
- 不新增日志。

------

#### Step 2 — 运行验证

运行构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过，终端输出包含 `BUILD SUCCEEDED`。
- 无 Auto Layout API 编译错误。
- 无新增运行时打印输出。

如果验证不通过，修复 `photoMetalViewController.swift` 后重复本步骤，直到通过。

------

✅ **完成的标志：** 构建通过，输出包含 `BUILD SUCCEEDED`。在满足此条件之前不要开始下一个任务。

------

### Task 3: 将普通浏览页与 Duplicate 页接入文件名栏

**目标：** 普通浏览页显示当前照片文件名；Duplicate 页左右两侧分别显示对应照片文件名；文件名随照片变化更新且无残留。

**涉及的文件：**

- `rawViewer/browser/photoBrowserViewController.swift` — 当前照片变化时设置主图文件名。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 左右照片变化时设置左右图文件名。

------

#### Step 1 — 实现普通浏览页接入

- [ ] 打开 `rawViewer/browser/photoBrowserViewController.swift`。
- [ ] 将文件头版本从 `3.5` 更新为 `3.6`。
- [ ] 将 Description 更新为：

```text
浏览器控制器，按当前照片 JPG/RAW 文件存在性禁用对应 segment，新增 Restore Normal、旋转按钮与主图无后缀文件名栏
```

- [ ] 在 `loadCurrentPhoto()` 中，找到：

```swift
        let requestId = viewModel.currentRequestId
        let photoId = photo.photoId
        let selectedSource = viewModel.displaySource
```

替换为：

```swift
        mainPhotoController.setDisplayName(photo.displayFileName)
        let requestId = viewModel.currentRequestId
        let photoId = photo.photoId
        let selectedSource = viewModel.displaySource
```

说明：

- `mainPhotoController.reset()` 已经先清空旧文件名。
- guard 取到当前照片后立即设置新文件名，不等待异步图片加载。
- 切换 JPG/RAW 会重新进入 `loadCurrentPhoto()`，但 `displayFileName` 不依赖 source，所以文件名保持不变。

------

#### Step 2 — 实现 Duplicate 页接入

- [ ] 打开 `rawViewer/duplicate/duplicateCompareViewController.swift`。
- [ ] 将文件头版本从 `3.7` 更新为 `3.8`。
- [ ] 将 Description 更新为：

```text
重复照片双图比较界面，按左右任意一侧 JPG/RAW 文件存在性控制对应 segment；旋转按钮改为旋转当前 duplicate 组剩余照片；左右图新增无后缀文件名栏
```

- [ ] 在 `loadPhotos()` 中，找到左侧照片分支：

```swift
        if let left = viewModel.mainPhoto {
            let photoId = left.photoId
```

替换为：

```swift
        if let left = viewModel.mainPhoto {
            leftPhotoController.setDisplayName(left.displayFileName)
            let photoId = left.photoId
```

- [ ] 在 `loadPhotos()` 中，找到右侧照片分支：

```swift
        if let right = viewModel.candidatePhoto {
            let photoId = right.photoId
```

替换为：

```swift
        if let right = viewModel.candidatePhoto {
            rightPhotoController.setDisplayName(right.displayFileName)
            let photoId = right.photoId
```

说明：

- `leftPhotoController.reset()` 和 `rightPhotoController.reset()` 已经先清空旧文件名。
- 当某一侧没有照片时，由 reset 保持隐藏，不需要额外调用。
- 文件名设置在异步加载前完成，不会因为图片加载慢而错位。
- 现有 Keep / source change / rotate 流程会调用 `loadPhotos()`，文件名随 viewModel 当前左右照片同步。

------

#### Step 3 — 运行验证

运行构建：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

- 构建通过，终端输出包含 `BUILD SUCCEEDED`。
- 无 `displayFileName` 未找到错误。
- 无 `setDisplayName` 未找到错误。
- 无新增运行时打印输出。

随后做手动运行检查。先用 Xcode 构建设置定位 Debug app 产物，再打开它：

```bash
appPath=$(xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -showBuildSettings \
  | awk -F'= ' '/TARGET_BUILD_DIR/ {target=$2} /FULL_PRODUCT_NAME/ {name=$2} END {print target "/" name}')
open "$appPath"
```

如果命令没有定位到 app，可从 Xcode 直接运行 `pickpick` scheme，或在 Finder 中打开最新 Debug 产物 `pickpick.app`。

手动预期：

1. 选择一个包含照片的目录。
2. 进入 Normal 或其他普通分组，主图顶部显示文件名，且没有扩展名。
3. 在普通浏览页切换 JPG/RAW，文件名不变化。
4. 切换上一张/下一张，文件名同步变化。
5. 进入 Duplicate 分组，左图顶部显示左侧照片文件名，右图顶部显示右侧照片文件名，均无扩展名。
6. 在 Duplicate 页执行 Keep 操作后，剩余左右文件名无旧值残留、无左右错位。
7. 长文件名在单行内以省略号截断，不挤压 toolbar。

如果验证不通过，修复对应控制器后重复本步骤，直到通过。

------

✅ **完成的标志：** 构建通过，输出包含 `BUILD SUCCEEDED`，并且手动检查确认 Browser 与 Duplicate 文件名显示符合预期。

------

## 自我复审

### 1. 规范覆盖

- 普通浏览页顶部显示文件名：Task 2 提供 UI，Task 3 Browser 接入。
- Duplicate 左右各自显示文件名：Task 2 提供 UI，Task 3 Duplicate 接入。
- 不显示后缀：Task 1 `deletingPathExtension()`。
- 不随 JPG/RAW 切换变化：Task 1 不读取 `displaySource`，Task 3 使用 `displayFileName`。
- 长文件名省略：Task 2 `lineBreakMode = .byTruncatingTail` 与单行 label。
- 不挤压 toolbar：Task 2 在图片控制器内布局，不修改 toolbar。

### 2. 占位符扫描

计划中没有 TBD、TODO、稍后实现、与某任务类似等占位符。每处代码改动均给出精确文件、替换位置和完整代码片段。

### 3. 类型一致性

- Task 1 定义 `photoItem.displayFileName`。
- Task 2 定义 `photoMetalViewController.setDisplayName(_:)`。
- Task 3 调用的方法名与 Task 1/2 一致。
- 所有新增变量使用小驼峰：`fileNameBar`、`fileNameLabel`、`fileNameBarHeightConstraint`、`trimmedName`、`shouldShowName`。

### 4. 验证完整性

- 每个任务都有 `xcodebuild` 命令。
- 每个任务的关键输出均要求 `BUILD SUCCEEDED`。
- 最终任务包含手动运行检查，覆盖 Browser 与 Duplicate 的核心 UI 行为。
- 未安排任何测试框架。
- 未安排任何 Git 操作。

---

## 执行交接

计划已完成并保存到 `docs/flare/20260617_photoFileNameHeader.md`。两种执行选项：

**1. 子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代

**2. 内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理

选择哪种方式？
