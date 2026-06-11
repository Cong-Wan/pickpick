# Restore Normal 与照片旋转持久化实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 让用户能把过曝、欠曝、虚焦照片放回 normal 分组，并在普通浏览页与 duplicate 对比页持久化显示旋转状态。

**架构：** 将人工展示状态落在 `photoItem.rotationDegrees`，由 `analysis.json` 持久化；Restore Normal 与 Rotate 通过 ViewModel 调用 `jsonReviewStateStore` 写回，再同步内存列表。展示层只读取角度渲染，不修改 JPG/RAW 原文件。

**技术栈：** Swift、AppKit、CoreImage、MetalKit、现有 `analysisStore` / `jsonReviewStateStore` / `appFileLogger`。

---

## 前置决策

用户选择日志策略 B：计划中只安排关键失败路径日志。所有调试打印仍通过现有 `appDebugLogger` 受 `--debug` 参数控制；本计划不新增普通 `print` 或 `NSLog`。失败排查信息写入现有 `appFileLogger`，这是文件日志，不是控制台打印。

## 文件结构

将修改以下文件：

- `rawViewer/models/photoModels.swift` — 新增 `rotationDegrees`、旋转方向与旧 JSON 解码兼容。
- `rawViewer/models/jsonReviewStateStore.swift` — 新增 Restore Normal 与批量旋转写回接口，失败时抛出可读错误。
- `rawViewer/views/photoMetalViewController.swift` — 暴露 `load(image:rotationDegrees:)`，把旋转角度传给 Metal 视图。
- `rawViewer/views/metalPhotoView.swift` — 保存旋转角度，绘制时对 `CIImage` 做展示层旋转。
- `rawViewer/browser/photoBrowserViewModel.swift` — 支持当前/勾选目标还原 normal，以及当前照片旋转并同步内存列表。
- `rawViewer/browser/photoBrowserViewController.swift` — 添加左侧 Restore Normal 按钮、顶部旋转按钮、失败日志和 group kind 可见性控制。
- `rawViewer/appCoordinator.swift` — 打开普通浏览页时传入当前 `photoGroupKind`。
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 支持左右当前照片一起旋转并同步内存列表。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 添加 duplicate 页旋转按钮、失败日志和刷新逻辑。

不创建新文件，避免为一次功能引入额外抽象。

---

### Task 1: 数据模型与持久化接口

**目标：** App 能读取旧 `analysis.json`，所有照片默认旋转为 0，并能通过 store 持久化 Restore Normal 与旋转角度。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 新增旋转字段、方向枚举、Codable 兼容。
- `rawViewer/models/jsonReviewStateStore.swift` — 新增批量还原和批量旋转写回方法。

------

#### Step 1 — 实现

1. 修改 `rawViewer/models/photoModels.swift` 文件头版本到 `1.7`，Description 说明新增旋转持久化与旧 JSON 兼容。

2. 在 `displaySource` 后加入旋转方向与角度归一化工具：

```swift
public enum photoRotationDirection: Equatable {
    case left
    case right

    public var deltaDegrees: Int {
        switch self {
        case .left: return 270
        case .right: return 90
        }
    }
}

public func normalizedRotationDegrees(_ value: Int) -> Int {
    let normalized = value % 360
    let positive = normalized < 0 ? normalized + 360 : normalized
    switch positive {
    case 90, 180, 270:
        return positive
    default:
        return 0
    }
}

public func rotatedDegrees(_ current: Int, direction: photoRotationDirection) -> Int {
    normalizedRotationDegrees(current + direction.deltaDegrees)
}
```

3. 在 `photoItem` 中新增字段：

```swift
public var rotationDegrees: Int
```

4. 更新 `photoItem` 的 public initializer，在参数列表末尾增加默认参数，并在 body 里归一化赋值：

```swift
rotationDegrees: Int = 0
```

```swift
self.rotationDegrees = normalizedRotationDegrees(rotationDegrees)
```

5. 因为旧 JSON 没有该字段，给 `photoItem` 添加显式 `Codable`。将以下代码放在 `photoItem` struct 内、默认 init 后面：

```swift
private enum codingKeys: String, CodingKey {
    case photoId
    case jpgPath
    case rawPath
    case isBlurry
    case exposureStatus
    case reviewStatus
    case reviewGroupId
    case templatePhotoId
    case analysisSource
    case dynamicRange
    case rotationDegrees
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: codingKeys.self)
    self.photoId = try container.decode(String.self, forKey: .photoId)
    self.jpgPath = try container.decode(String.self, forKey: .jpgPath)
    self.rawPath = try container.decodeIfPresent(String.self, forKey: .rawPath)
    self.isBlurry = try container.decode(Bool.self, forKey: .isBlurry)
    self.exposureStatus = try container.decode(String.self, forKey: .exposureStatus)
    self.reviewStatus = try container.decode(reviewStatus.self, forKey: .reviewStatus)
    self.reviewGroupId = try container.decode(String.self, forKey: .reviewGroupId)
    self.templatePhotoId = try container.decode(String.self, forKey: .templatePhotoId)
    self.analysisSource = try container.decode(String.self, forKey: .analysisSource)
    self.dynamicRange = try container.decodeIfPresent(dynamicRangeData.self, forKey: .dynamicRange)
    self.rotationDegrees = normalizedRotationDegrees(try container.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0)
}

public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: codingKeys.self)
    try container.encode(photoId, forKey: .photoId)
    try container.encode(jpgPath, forKey: .jpgPath)
    try container.encodeIfPresent(rawPath, forKey: .rawPath)
    try container.encode(isBlurry, forKey: .isBlurry)
    try container.encode(exposureStatus, forKey: .exposureStatus)
    try container.encode(reviewStatus, forKey: .reviewStatus)
    try container.encode(reviewGroupId, forKey: .reviewGroupId)
    try container.encode(templatePhotoId, forKey: .templatePhotoId)
    try container.encode(analysisSource, forKey: .analysisSource)
    try container.encodeIfPresent(dynamicRange, forKey: .dynamicRange)
    try container.encode(normalizedRotationDegrees(rotationDegrees), forKey: .rotationDegrees)
}
```

6. 修改 `rawViewer/models/jsonReviewStateStore.swift` 文件头版本到 `1.6`，Description 说明新增 Restore Normal 和旋转持久化接口。

7. 在 `reviewOperation` 中增加两个 case：

```swift
case restoreNormal(photoIds: Set<String>)
case rotations([String: Int])
```

8. 在 `jsonReviewStateStoring` protocol 中增加方法：

```swift
func restoreNormal(photoIds: Set<String>) throws
func setRotations(_ rotationsByPhotoId: [String: Int]) throws
```

9. 在 protocol 前新增错误类型：

```swift
public enum reviewStateStoreError: LocalizedError, Equatable {
    case emptyPhotoIds
    case missingPhotoIds([String])

    public var errorDescription: String? {
        switch self {
        case .emptyPhotoIds:
            return "No photo ids were provided"
        case .missingPhotoIds(let ids):
            return "Photo ids were not found in analysis store: \(ids.joined(separator: ","))"
        }
    }
}
```

10. 在 `jsonReviewStateStore` 中实现两个新方法：

```swift
public func restoreNormal(photoIds: Set<String>) throws {
    guard !photoIds.isEmpty else { throw reviewStateStoreError.emptyPhotoIds }
    try updateThrowing { items in
        var missingIds = photoIds
        for index in items.indices where photoIds.contains(items[index].photoId) {
            items[index].exposureStatus = "normal"
            items[index].isBlurry = false
            missingIds.remove(items[index].photoId)
        }
        guard missingIds.isEmpty else {
            throw reviewStateStoreError.missingPhotoIds(missingIds.sorted())
        }
    }
    operations.append(.restoreNormal(photoIds: photoIds))
}

public func setRotations(_ rotationsByPhotoId: [String: Int]) throws {
    let photoIds = Set(rotationsByPhotoId.keys)
    guard !photoIds.isEmpty else { throw reviewStateStoreError.emptyPhotoIds }
    try updateThrowing { items in
        var missingIds = photoIds
        for index in items.indices {
            let photoId = items[index].photoId
            guard let rotation = rotationsByPhotoId[photoId] else { continue }
            items[index].rotationDegrees = normalizedRotationDegrees(rotation)
            missingIds.remove(photoId)
        }
        guard missingIds.isEmpty else {
            throw reviewStateStoreError.missingPhotoIds(missingIds.sorted())
        }
    }
    operations.append(.rotations(rotationsByPhotoId.mapValues { normalizedRotationDegrees($0) }))
}
```

11. 在 `jsonReviewStateStore` 中增加私有 throwing update helper，放在现有 `update(_:)` 后面：

```swift
private func updateThrowing(_ mutate: (inout [photoItem]) throws -> Void) throws {
    guard let folderUrl else { return }
    var records = try analysisStore.shared.load(for: folderUrl)
    try mutate(&records)
    try analysisStore.shared.save(folderUrl: folderUrl, records: records)
}
```

注意：不要删除现有 `update(_:)`，旧调用还需要它。

------

#### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：编译通过，末尾出现 ** BUILD SUCCEEDED **，无 Codable 相关编译错误。
```

如果构建失败，优先检查：

- `photoItem` 的 `codingKeys` 是否在 struct 内。
- `jsonReviewStateStoring` 新增方法是否由 `jsonReviewStateStore` 全部实现。
- `reviewOperation` 新增关联值是否符合 `Equatable`。

✅ **完成的标志：** 构建通过，旧调用点没有协议缺口。

------

### Task 2: 展示层支持旋转渲染

**目标：** 任意调用方传入 `rotationDegrees` 后，图片能以 0/90/180/270 度正确显示，且不修改原始 CIImage 缓存和文件。

**涉及的文件：**

- `rawViewer/views/photoMetalViewController.swift` — 转发旋转角度。
- `rawViewer/views/metalPhotoView.swift` — 绘制时应用旋转。

------

#### Step 1 — 实现

1. 修改 `rawViewer/views/photoMetalViewController.swift` 文件头版本到 `1.2`，Description 说明新增展示旋转角度传递。

2. 将 `load(image:)` 替换为：

```swift
public func load(image: CIImage?, rotationDegrees: Int = 0) {
    errorLabel.isHidden = true
    errorLabel.stringValue = ""
    if let image {
        metalView.setImage(image, rotationDegrees: rotationDegrees)
        hasImage = true
    } else {
        metalView.clearImage()
        hasImage = false
    }
}
```

现有调用 `load(image:)` 因默认参数继续可用。

3. 修改 `rawViewer/views/metalPhotoView.swift` 文件头版本到 `3.2`，Description 说明新增展示层 90 度步进旋转。

4. 在 `metalPhotoView` 的状态区加入：

```swift
private var rotationDegrees: Int = 0
```

5. 将 `setImage(_:)` 替换为：

```swift
public func setImage(_ image: CIImage?, rotationDegrees: Int = 0) {
    currentImage = image
    self.rotationDegrees = normalizedRotationDegrees(rotationDegrees)
    errorMessage = nil
    isShowingError = false
    needsDisplay = true
}
```

6. 在 `clearImage()` 中加入重置旋转：

```swift
rotationDegrees = 0
```

完整方法应为：

```swift
public func clearImage() {
    currentImage = nil
    rotationDegrees = 0
    errorMessage = nil
    isShowingError = false
    needsDisplay = true
}
```

7. 在 `showError(_:)` 中也加入重置旋转：

```swift
rotationDegrees = 0
```

完整方法应为：

```swift
public func showError(_ message: String) {
    currentImage = nil
    rotationDegrees = 0
    errorMessage = message
    isShowingError = true
    needsDisplay = true
}
```

8. 在 `metalPhotoView` 中新增私有方法：

```swift
private func displayImage(from image: CIImage) -> CIImage {
    switch normalizedRotationDegrees(rotationDegrees) {
    case 90:
        return image.oriented(forExifOrientation: 6)
    case 180:
        return image.oriented(forExifOrientation: 3)
    case 270:
        return image.oriented(forExifOrientation: 8)
    default:
        return image
    }
}
```

9. 在 `draw(_:)` 中找到 `if let image = currentImage {` 分支，并将该分支内部的绘制逻辑替换为：

```swift
if let image = currentImage {
    let imageToRender = displayImage(from: image)
    let extent = imageToRender.extent
    guard extent.width > 0, extent.height > 0,
          extent.width.isFinite, extent.height.isFinite else {
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return
    }

    let fitScale = min(Double(target.width) / extent.width, Double(target.height) / extent.height)
    let effectiveScale = fitScale * userZoom
    let width = extent.width * effectiveScale
    let height = extent.height * effectiveScale
    let x = (Double(target.width) - width) / 2 + panOffset.x - extent.minX * effectiveScale
    let y = (Double(target.height) - height) / 2 + panOffset.y - extent.minY * effectiveScale
    let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: effectiveScale, y: effectiveScale)
    ciContext.render(imageToRender.transformed(by: transform), to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
}
```

不要改变缩放、平移和清屏逻辑。

------

#### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：编译通过，末尾出现 ** BUILD SUCCEEDED **，无 CoreImage orientation 或方法签名错误。
```

手工运行 App 后，在尚未添加按钮前现有图片显示应与之前一致，因为默认 `rotationDegrees` 是 0。

✅ **完成的标志：** 构建通过，现有浏览页仍能显示图片。

------

### Task 3: 普通浏览 ViewModel 支持还原与旋转

**目标：** 普通浏览页 ViewModel 能计算 Restore Normal 目标，成功写回后更新列表；能旋转当前照片并返回新角度。

**涉及的文件：**

- `rawViewer/browser/photoBrowserViewModel.swift` — 添加 Restore Normal 与 Rotate 业务方法。

------

#### Step 1 — 实现

1. 修改文件头版本到 `1.2`，Description 说明新增 Restore Normal 和展示旋转状态同步。

2. 在 `photoBrowserViewModel` 中新增目标计算方法，放在 `deleteTargets()` 后面：

```swift
public func restoreNormalTargets() -> [photoItem] {
    if checkedPhotoIds.isEmpty {
        return currentPhoto.map { [$0] } ?? []
    }
    return photos.filter { checkedPhotoIds.contains($0.photoId) }
}
```

3. 在 `photoBrowserViewModel` 中新增 Restore Normal 方法：

```swift
public func restoreNormalTargetsAndUpdateList() throws {
    let targets = restoreNormalTargets()
    let ids = Set(targets.map(\.photoId))
    guard !ids.isEmpty else { return }

    try store.restoreNormal(photoIds: ids)

    photos.removeAll { ids.contains($0.photoId) }
    checkedPhotoIds.subtract(ids)
    currentIndex = min(currentIndex, max(photos.count - 1, 0))
    currentRequestId += 1
}
```

4. 在 `photoBrowserViewModel` 中新增旋转方法：

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

------

#### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：编译通过，末尾出现 ** BUILD SUCCEEDED **，无 protocol 方法缺失或 key path 语法错误。
```

✅ **完成的标志：** 构建通过，ViewModel 新方法不影响现有删除与选择逻辑。

------

### Task 4: 普通浏览页 UI 接入 Restore Normal 与旋转

**目标：** 过曝、欠曝、虚焦普通浏览页显示 Restore Normal；所有普通浏览页显示旋转按钮，并在失败时写 app log。

**涉及的文件：**

- `rawViewer/appCoordinator.swift` — 传入当前分组 kind。
- `rawViewer/browser/photoBrowserViewController.swift` — 添加按钮、布局、动作和日志。

------

#### Step 1 — 实现

1. 修改 `photoBrowserViewController.swift` 文件头版本到 `3.3`，Description 说明新增 Restore Normal 与显示旋转按钮。

2. 在属性区加入：

```swift
private let groupKind: photoGroupKind?
private var restoreNormalButton: NSButton?
private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
```

3. 将 designated initializer 改为：

```swift
public init(viewModel: photoBrowserViewModel, imageService: photoImageService, groupKind: photoGroupKind? = nil) {
    self.viewModel = viewModel
    self.imageService = imageService
    self.groupKind = groupKind
    self.groupTitle = groupKind?.title ?? "Browser"
    super.init(nibName: nil, bundle: nil)
}
```

4. 更新 convenience initializer 调用：

```swift
self.init(viewModel: viewModel, imageService: imageService, groupKind: group.kind)
```

5. 更新 `required init?(coder:)`，在 `super.init(coder:)` 前加入：

```swift
self.groupKind = nil
```

6. 在类中新增 computed property：

```swift
private var canRestoreNormal: Bool {
    switch groupKind {
    case .overexposed, .underexposed, .blurry:
        return true
    default:
        return false
    }
}
```

7. 在 `loadView()` 中配置旋转按钮。放在 `deleteButton` 创建后：

```swift
rotateLeftButton.target = self
rotateLeftButton.action = #selector(rotateLeftClicked)
rotateLeftButton.bezelStyle = .rounded
rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false

rotateRightButton.target = self
rotateRightButton.action = #selector(rotateRightClicked)
rotateRightButton.bezelStyle = .rounded
rotateRightButton.translatesAutoresizingMaskIntoConstraints = false
```

8. 将旋转按钮加入 toolbar，顺序放在 sourceControl 与 deleteButton 之间：

```swift
toolbarView.addSubview(rotateLeftButton)
toolbarView.addSubview(rotateRightButton)
```

9. 替换 toolbar 约束中 source/delete 的相邻约束为：

```swift
sourceControl.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
sourceControl.trailingAnchor.constraint(equalTo: rotateLeftButton.leadingAnchor, constant: -8),
rotateLeftButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
rotateLeftButton.trailingAnchor.constraint(equalTo: rotateRightButton.leadingAnchor, constant: -6),
rotateRightButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
rotateRightButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
deleteButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
deleteButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
```

保留其它 toolbar 约束。

10. 将左侧布局从直接添加 `thumbnailView` 改为 `leftPanel`。在创建 `thumbnailView` 后，新增：

```swift
let leftPanel = NSStackView()
leftPanel.orientation = .vertical
leftPanel.spacing = 6
leftPanel.translatesAutoresizingMaskIntoConstraints = false
leftPanel.widthAnchor.constraint(equalToConstant: 150).isActive = true

if canRestoreNormal {
    let button = NSButton(title: "Restore Normal", target: self, action: #selector(restoreNormalClicked))
    button.bezelStyle = .rounded
    button.translatesAutoresizingMaskIntoConstraints = false
    restoreNormalButton = button
    leftPanel.addArrangedSubview(button)
}
leftPanel.addArrangedSubview(thumbnailView)
```

11. 将 root 中的 `thumbnailView` 替换为 `leftPanel`：

```swift
root.addSubview(leftPanel)
```

并把相关约束替换为：

```swift
leftPanel.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 6),
leftPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
leftPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

mainPhotoController.view.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
mainPhotoController.view.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
mainPhotoController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
mainPhotoController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
```

删除原来的 `thumbnailView.widthAnchor.constraint(equalToConstant: 150)` 和直接对 `thumbnailView` 的 top/leading/bottom 约束。

12. 在 `show(pair:source:)` 中，将所有 `mainPhotoController.load(image: image)` 改为带旋转角度。先在方法开始处加入：

```swift
let rotationDegrees = viewModel.currentPhoto?.rotationDegrees ?? 0
```

然后将三处 load 调用改为：

```swift
mainPhotoController.load(image: image, rotationDegrees: rotationDegrees)
```

fallback JPG 的 `jpgImage` 调用也同样传入 `rotationDegrees`。

13. 在 `loadCurrentPhoto()` 中更新按钮可用性。`guard let photo = viewModel.currentPhoto else { return }` 前加入：

```swift
updateActionButtons()
```

并新增方法：

```swift
private func updateActionButtons() {
    let hasPhoto = viewModel.currentPhoto != nil
    restoreNormalButton?.isEnabled = hasPhoto && canRestoreNormal
    rotateLeftButton.isEnabled = hasPhoto
    rotateRightButton.isEnabled = hasPhoto
}
```

14. 新增 Restore Normal action：

```swift
@objc private func restoreNormalClicked() {
    let targets = viewModel.restoreNormalTargets()
    guard !targets.isEmpty else { return }
    let ids = targets.map(\.photoId)
    do {
        try viewModel.restoreNormalTargetsAndUpdateList()
        thumbnailView.updatePhotos(viewModel.photos)
        thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
        if viewModel.photos.isEmpty {
            onBack?()
        } else {
            thumbnailView.setCurrentIndex(viewModel.currentIndex)
            loadCurrentPhoto()
        }
    } catch {
        appFileLogger.log("operation failed page=browser action=restoreNormal targetCount=\(targets.count) photoIds=\(ids.joined(separator: ",")) error=\(error.localizedDescription)", level: .error)
        showErrorAlert(message: error.localizedDescription)
    }
}
```

15. 新增旋转 actions：

```swift
@objc private func rotateLeftClicked() {
    rotateCurrent(direction: .left, actionName: "rotateLeft")
}

@objc private func rotateRightClicked() {
    rotateCurrent(direction: .right, actionName: "rotateRight")
}

private func rotateCurrent(direction: photoRotationDirection, actionName: String) {
    guard let photo = viewModel.currentPhoto else { return }
    let oldRotation = photo.rotationDegrees
    let targetRotation = rotatedDegrees(oldRotation, direction: direction)
    do {
        _ = try viewModel.rotateCurrentPhoto(direction: direction)
        loadCurrentPhoto()
    } catch {
        appFileLogger.log("operation failed page=browser action=\(actionName) photoId=\(photo.photoId) oldRotation=\(oldRotation) targetRotation=\(targetRotation) error=\(error.localizedDescription)", level: .error)
        showErrorAlert(message: error.localizedDescription)
    }
}
```

16. 修改 `rawViewer/appCoordinator.swift` 文件头版本到 `1.5`，Description 说明普通浏览页传递 group kind。

17. 在 `showBrowser(group:)` 中修改浏览页创建：

```swift
let browser = photoBrowserViewController(viewModel: viewModel, imageService: imageService, groupKind: group.kind)
```

------

#### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：编译通过，末尾出现 ** BUILD SUCCEEDED **，无 Auto Layout 变量未定义或 initializer 参数错误。
```

手工运行 App 验证：

1. 打开 overexposed、underexposed 或 blurry 普通分组，左侧出现 `Restore Normal`。
2. 打开 normal 分组，左侧不出现 `Restore Normal`。
3. 普通分组顶部出现 `⟲ 90°` 和 `⟳ 90°`。
4. 点击旋转按钮后当前图旋转；切换 JPG/RAW 后角度保持。
5. 在问题分组中无勾选点击 `Restore Normal`，当前图从列表移除。
6. 勾选多张后点击 `Restore Normal`，勾选图从列表移除。

✅ **完成的标志：** 构建通过，普通浏览页 Restore Normal 与旋转手工验证符合预期。

------

### Task 5: Duplicate 对比页支持左右一起旋转

**目标：** Duplicate 页顶部出现旋转按钮，点击后左右当前照片一起旋转并持久化，失败时写 app log。

**涉及的文件：**

- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 添加左右照片一起旋转方法。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 添加按钮、渲染角度和失败日志。

------

#### Step 1 — 实现

1. 修改 `duplicateCompareViewModel.swift` 文件头版本到 `1.5`，Description 说明新增 duplicate 当前对比照片共同旋转。

2. 在 `duplicateCompareViewModel` 中新增方法，放在 `keepBoth` 后、`markFinalKept` 前：

```swift
@discardableResult
public func rotateCurrentPair(direction: photoRotationDirection) throws -> [String: Int] {
    var rotations: [String: Int] = [:]
    if let left = mainPhoto {
        rotations[left.photoId] = rotatedDegrees(left.rotationDegrees, direction: direction)
    }
    if let right = candidatePhoto {
        rotations[right.photoId] = rotatedDegrees(right.rotationDegrees, direction: direction)
    }
    guard !rotations.isEmpty else { return [:] }

    try store.setRotations(rotations)

    for index in photos.indices {
        let photoId = photos[index].photoId
        if let rotation = rotations[photoId] {
            photos[index].rotationDegrees = rotation
        }
    }
    return rotations
}
```

3. 修改 `duplicateCompareViewController.swift` 文件头版本到 `3.4`，Description 说明新增左右一起旋转。

4. 在属性区加入：

```swift
private var rotateLeftButton = NSButton(title: "⟲ 90°", target: nil, action: nil)
private var rotateRightButton = NSButton(title: "⟳ 90°", target: nil, action: nil)
```

5. 在 `loadView()` 中 `keepBothBtn` 与 `sourceControl` 创建后配置旋转按钮：

```swift
rotateLeftButton.target = self
rotateLeftButton.action = #selector(rotateLeftClicked)
rotateLeftButton.bezelStyle = .rounded
rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false

rotateRightButton.target = self
rotateRightButton.action = #selector(rotateRightClicked)
rotateRightButton.bezelStyle = .rounded
rotateRightButton.translatesAutoresizingMaskIntoConstraints = false
```

6. 将按钮加入 toolbar：

```swift
toolbar.addSubview(rotateLeftButton)
toolbar.addSubview(rotateRightButton)
```

7. 替换 toolbar 中 sourceControl 和 keepBoth 的相邻约束为：

```swift
sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
sourceControl.trailingAnchor.constraint(equalTo: rotateLeftButton.leadingAnchor, constant: -8),
rotateLeftButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
rotateLeftButton.trailingAnchor.constraint(equalTo: rotateRightButton.leadingAnchor, constant: -6),
rotateRightButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
rotateRightButton.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
keepBothBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
keepBothBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
```

保留其它约束。

8. 在 `loadPhotos()` 中 `let selectedSource = sourceStore.current` 后加入：

```swift
updateActionButtons()
```

并新增方法：

```swift
private func updateActionButtons() {
    let hasPhoto = viewModel.mainPhoto != nil || viewModel.candidatePhoto != nil
    rotateLeftButton.isEnabled = hasPhoto
    rotateRightButton.isEnabled = hasPhoto
}
```

9. 在 `show(pair:source:isLeft:)` 中，在 controller 定义后加入：

```swift
let rotationDegrees = isLeft
    ? (viewModel.mainPhoto?.rotationDegrees ?? 0)
    : (viewModel.candidatePhoto?.rotationDegrees ?? 0)
```

将所有 `controller.load(image: image)` 改为：

```swift
controller.load(image: image, rotationDegrees: rotationDegrees)
```

包括 RAW 成功、RAW fallback JPG、普通 JPG fallback。

10. 新增旋转 action：

```swift
@objc private func rotateLeftClicked() {
    rotateCurrentPair(direction: .left, actionName: "rotateLeft")
}

@objc private func rotateRightClicked() {
    rotateCurrentPair(direction: .right, actionName: "rotateRight")
}

private func rotateCurrentPair(direction: photoRotationDirection, actionName: String) {
    let left = viewModel.mainPhoto
    let right = viewModel.candidatePhoto
    guard left != nil || right != nil else { return }

    let oldLeftRotation = left?.rotationDegrees
    let oldRightRotation = right?.rotationDegrees
    let targetLeftRotation = oldLeftRotation.map { rotatedDegrees($0, direction: direction) }
    let targetRightRotation = oldRightRotation.map { rotatedDegrees($0, direction: direction) }

    do {
        _ = try viewModel.rotateCurrentPair(direction: direction)
        loadPhotos()
    } catch {
        let leftId = left?.photoId ?? ""
        let rightId = right?.photoId ?? ""
        let oldLeft = oldLeftRotation.map(String.init) ?? ""
        let targetLeft = targetLeftRotation.map(String.init) ?? ""
        let oldRight = oldRightRotation.map(String.init) ?? ""
        let targetRight = targetRightRotation.map(String.init) ?? ""
        appFileLogger.log("operation failed page=duplicate action=\(actionName) leftPhotoId=\(leftId) rightPhotoId=\(rightId) oldLeftRotation=\(oldLeft) targetLeftRotation=\(targetLeft) oldRightRotation=\(oldRight) targetRightRotation=\(targetRight) error=\(error.localizedDescription)", level: .error)
        showErrorAlert(message: error.localizedDescription)
    }
}
```

------

#### Step 2 — 运行验证

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：编译通过，末尾出现 ** BUILD SUCCEEDED **，无 duplicate controller 约束或方法签名错误。
```

手工运行 App 验证：

1. 打开 duplicate 分组，顶部出现 `⟲ 90°` 和 `⟳ 90°`。
2. 点击右旋，左右两张图一起顺时针旋转 90°。
3. 点击左旋，左右两张图一起逆时针旋转 90°。
4. 切换 JPG/RAW 后左右角度保持。
5. 返回分组页再进入 duplicate，角度保持。
6. Keep Left / Keep Right / Keep Both 后，保留下来的照片在其它分组继续保持旋转。

✅ **完成的标志：** 构建通过，duplicate 页左右一起旋转并持久化。

------

### Task 6: 全量验证与日志确认

**目标：** 确认 Restore Normal、普通旋转、duplicate 旋转、旧 JSON 兼容和错误日志均符合规范。

**涉及的文件：**

- 无新增实现文件；本任务只运行构建和手工验证。

------

#### Step 1 — 实现

本任务不修改代码。使用前 5 个任务完成的实现进行全量验证。

------

#### Step 2 — 运行验证

1. 清理并构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug clean build
# 预期：构建通过，末尾出现 ** BUILD SUCCEEDED **。
```

2. 手工验证普通分组：

```text
准备 overexposed、underexposed、blurry、normal 分组各至少 1 张照片。
打开 overexposed / underexposed / blurry：左侧显示 Restore Normal。
打开 normal：左侧不显示 Restore Normal。
在问题分组中无勾选点击 Restore Normal：当前照片进入 normal，当前列表减少。
在问题分组中勾选多张点击 Restore Normal：勾选照片进入 normal，当前列表减少。
当前组清空后自动返回分组页。
```

预期：运行无异常，UI 状态与描述一致。

3. 手工验证普通旋转：

```text
打开普通分组任意照片。
点击右旋 4 次。
在 JPG 与 RAW 之间切换。
返回分组页再进入。
重启 App 后再进入同一照片。
```

预期：每次右旋增加 90°，4 次回到原角度；JPG/RAW、返回页面和重启后角度保持。

4. 手工验证 duplicate 旋转：

```text
打开 duplicate 分组。
点击右旋一次。
切换 JPG/RAW。
点击左旋一次。
执行 Keep Left、Keep Right 或 Keep Both。
在保留照片进入其它分组后再次查看。
```

预期：左右两张图一起旋转；JPG/RAW 切换保持；保留照片在其它分组中继续保持旋转。

5. 手工验证旧 JSON 兼容：

```text
使用没有 rotationDegrees 字段的 analysis.json 打开 App。
查看任意照片。
旋转一次后退出 App。
重新打开对应 analysis.json。
```

预期：旧 JSON 能打开；首次角度默认为 0；旋转后 JSON 中出现 `rotationDegrees`。

6. 手工验证错误日志：

```text
临时让 analysis.json 所在目录不可写，或用只读副本模拟写入失败。
在普通页点击 Restore Normal。
在普通页点击旋转。
在 duplicate 页点击旋转。
查看 ~/Library/Application Support/rawViewer/logs/ 当天日志。
```

预期：UI 弹出 `Operation failed`；当天日志包含 `page=browser action=restoreNormal`、`page=browser action=rotate`、`page=duplicate action=rotate` 相关 `.error` 记录。恢复目录权限后重新验证正常操作。

✅ **完成的标志：** 全量构建通过，手工验证没有 crash，关键 UI 行为和日志输出符合预期。

---

## 自我复审记录

### 规范覆盖

- Restore Normal 当前图 / 多选批量：Task 3、Task 4 覆盖。
- Restore Normal 直接写 `normal` 与 `isBlurry=false`：Task 1 覆盖。
- 普通浏览页旋转：Task 2、Task 3、Task 4 覆盖。
- Duplicate 页左右一起旋转：Task 5 覆盖。
- JPG/RAW 切换保持旋转：Task 2、Task 4、Task 5 覆盖。
- App 重启保持旋转：Task 1 持久化，Task 6 验证。
- 失败写 app log：Task 4、Task 5、Task 6 覆盖。
- 不修改原始文件：Task 2 展示层旋转覆盖。

### 红色信号扫描

计划不包含待补充内容；所有任务都有具体文件、代码片段、命令和预期结果。

### 类型一致性

- `photoRotationDirection`、`normalizedRotationDegrees`、`rotatedDegrees` 在 Task 1 定义，Task 3/4/5 使用。
- `jsonReviewStateStoring.restoreNormal` 与 `setRotations` 在 Task 1 定义，Task 3/5 使用。
- `photoMetalViewController.load(image:rotationDegrees:)` 在 Task 2 定义，Task 4/5 使用。

### 验证完整性

每个任务都包含 `xcodebuild` 验证命令；Task 4、Task 5、Task 6 包含手工运行验证，能确认关键输出与 UI 行为。
