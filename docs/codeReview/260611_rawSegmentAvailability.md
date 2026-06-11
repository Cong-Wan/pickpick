# 代码审核报告 — RAW 按钮可用性错误分析

### 总览
- **问题现象：** 随意进入一个分组查看图片，部分只有 JPG 的照片仍然可以点击 `RAW`。
- **审核范围：** 分组入口、图片浏览器、重复图对比页、图片数据模型、扫描/分析/持久化、JPG/RAW 图像加载服务。
- **关键文件：**
  - `rawViewer/services/fileScanner.swift`
  - `rawViewer/services/photoAnalysisService.swift`
  - `rawViewer/services/analysisStore.swift`
  - `rawViewer/models/photoModels.swift`
  - `rawViewer/appCoordinator.swift`
  - `rawViewer/groupGrid/groupGridViewController.swift`
  - `rawViewer/browser/photoBrowserViewController.swift`
  - `rawViewer/browser/photoBrowserViewModel.swift`
  - `rawViewer/duplicate/duplicateCompareViewController.swift`
  - `rawViewer/services/photoImageService.swift`
  - `rawViewer/services/photoDisplayService.swift`
- **发现问题：** 🔴 0 个 / 🟠 2 个 / 🟡 2 个 / 🔵 0 个
- **结论：** 数据层已经能正确表达“没有 RAW”（`photoItem.rawPath == nil`），加载层也能返回 `RAW missing`，但 UI 层没有根据当前照片的 RAW 可用性禁用 `NSSegmentedControl` 的 RAW segment。并且展示逻辑在 RAW 不可用时静默回退到 JPG，掩盖了错误，让用户看到“RAW 可点、点了也像能显示”的错觉。

---

## 责任链路

### 1. 扫描阶段：按同名 stem 配对 JPG / RAW

**位置：** `rawViewer/services/fileScanner.swift:10-22`、`rawViewer/services/fileScanner.swift:25-55`

`fileScanner` 扫描顶层目录后，以文件名 stem 作为 `photoId`，把 JPG 与 RAW 配到同一个 `photoFilePair`：

```swift
public struct photoFilePair {
    public let photoId: String
    public let jpgPath: String?
    public let rawPath: String?

    public var hasJpg: Bool { jpgPath != nil }
    public var hasRaw: Bool { rawPath != nil }
}
```

当只有 JPG 时，`rawPath` 会保持 `nil`，`hasRaw == false`。这里的数据结构本身没有问题。

> 注意：当前 RAW 扩展名只识别 `rw2`、`cr2`。如果真实图库里有 `nef`、`arw`、`dng` 等格式，它们会被当作“没有 RAW”。这不是本次 UI 可点击问题的直接根因，但可能造成“明明磁盘有 RAW，App 认为没有 RAW”的另一个问题。

### 2. 分析阶段：把 rawPath 写入 photoItem

**位置：** `rawViewer/services/photoAnalysisService.swift:112-119`

```swift
let item = photoItem(
    photoId: pair.photoId,
    jpgPath: pair.jpgPath ?? pair.rawPath ?? "",
    rawPath: pair.rawPath,
    analysisSource: ""
)
```

这里会把扫描得到的 `pair.rawPath` 原样写入 `photoItem.rawPath`。因此：

- 有 RAW：`photoItem.rawPath = "/path/to/file.cr2"`
- 无 RAW：`photoItem.rawPath = nil`

### 3. 分析选择：没有 RAW 时走 JPG 分析

**位置：** `rawViewer/services/photoAnalysisService.swift:154-164`

```swift
if pair.hasRaw, let rawPath = pair.rawPath {
    result = try self.rawAnalyzer.analyze(rawPath: rawPath, config: config)
} else if pair.hasJpg, let jpgPath = pair.jpgPath {
    result = try self.jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
}
```

分析链路也能区分 RAW/JPG。没有 RAW 的照片不会走 RAW 分析，而是走 JPG 分析。说明“RAW 按钮可点”不是分析阶段误判导致的。

### 4. 持久化阶段：photoItem 被直接保存到 analysis.json

**位置：** `rawViewer/services/analysisStore.swift:66-96`

`analysisStore` 直接编码/解码 `photoItem`：

```swift
let root = try JSONDecoder().decode(analysisFile.self, from: data)
return root.photos

existing.photos = records
let data = try JSONEncoder().encode(existing)
try data.write(to: url, options: .atomic)
```

`rawPath` 会随 `photoItem` 保存和加载。只要初次扫描正确，后续进入分组时仍可通过 `photo.rawPath` 判断 RAW 是否存在。

### 5. 分组入口：点击分组进入 Browser 或 Duplicate Compare

**位置：**
- `rawViewer/appCoordinator.swift:92-104`
- `rawViewer/appCoordinator.swift:115-152`
- `rawViewer/groupGrid/groupGridViewController.swift:148-160`

链路如下：

```text
showGroups()
  -> groupGridViewController
    -> card.onTap
      -> appCoordinator.navigateToGroup(group)
        -> 普通分组：showBrowser(group)
        -> 重复分组：showDuplicate(group)
```

普通分组会进入 `photoBrowserViewController`；重复分组会进入 `duplicateCompareViewController`。两个页面都有 `JPG / RAW` segmented control。

### 6. 普通分组图片浏览器：RAW segment 始终可点

**位置：** `rawViewer/browser/photoBrowserViewController.swift:20`、`rawViewer/browser/photoBrowserViewController.swift:72-75`

```swift
private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)

sourceControl.target = self
sourceControl.action = #selector(sourceChanged(_:))
sourceControl.selectedSegment = viewModel.displaySource == .jpg ? 0 : 1
sourceControl.translatesAutoresizingMaskIntoConstraints = false
```

这里只设置了：

- target
- action
- selectedSegment
- Auto Layout

没有任何代码调用：

```swift
sourceControl.setEnabled(false, forSegment: 1)
```

也没有根据 `viewModel.currentPhoto?.rawPath` 更新 segment 状态。因此，只要页面渲染出来，RAW segment 默认就是 enabled。

### 7. 切换照片时也没有更新 RAW 可用性

**位置：** `rawViewer/browser/photoBrowserViewController.swift:134-153`、`rawViewer/browser/photoBrowserViewController.swift:215-224`、`rawViewer/browser/photoBrowserViewController.swift:234-237`

`loadCurrentPhoto()` 负责加载当前照片，但只做了取消旧任务、reset、异步加载 JPG/RAW pair、展示图片。它没有同步 UI 控件状态：

```swift
private func loadCurrentPhoto() {
    loadTask?.cancel()
    mainPhotoController.reset()

    guard let photo = viewModel.currentPhoto else {
        return
    }
    ...
    let pair = await self.imageService.preloadDisplayPair(for: photo)
    ...
    self.show(pair: pair, source: selectedSource)
}
```

键盘上下切换、缩略图点击切换都会调用 `loadCurrentPhoto()`，但没有任何地方刷新 RAW segment enabled 状态。所以即使前一张有 RAW、后一张没有 RAW，按钮状态也不会随当前照片变化。

### 8. 点击 RAW 后：加载层返回 RAW missing，但展示层静默回退 JPG

**位置：**
- `rawViewer/browser/photoBrowserViewController.swift:155-169`
- `rawViewer/services/photoImageService.swift:70-73`
- `rawViewer/services/photoDisplayService.swift:47-68`
- `rawViewer/services/photoDisplayService.swift:90-93`

`photoImageService.preloadDisplayPair` 会同时加载 JPG 和 RAW：

```swift
async let jpgResult = displayService.loadDisplayJpg(for: photo)
async let rawResult = displayService.loadDisplayRaw(for: photo)
return await photoDisplayPair(photoId: photo.photoId, jpg: jpgResult, raw: rawResult)
```

如果 `photo.rawPath == nil`，`photoDisplayService.loadRaw` 会返回：

```swift
guard let rawPath, !rawPath.isEmpty else {
    return .unavailable("RAW missing")
}
```

但浏览器展示逻辑是：

```swift
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
```

所以当用户点 RAW 时：

1. `selected = pair.raw`
2. `pair.raw = .unavailable("RAW missing")`
3. 进入 fallback：如果 JPG 可用，直接加载 JPG
4. UI 不提示“RAW 不存在”，按钮也仍显示可选

这就是用户感知上“只有 JPG 的图还可以点 RAW”的核心原因。

---

## 问题清单

### 🟠 [High] 普通分组浏览器没有根据当前照片禁用 RAW segment

**位置：** `rawViewer/browser/photoBrowserViewController.swift:20`、`rawViewer/browser/photoBrowserViewController.swift:72-75`、`rawViewer/browser/photoBrowserViewController.swift:134-153`、`rawViewer/browser/photoBrowserViewController.swift:185-189`

**问题：** `sourceControl` 创建后默认两个 segment 都可点击。控制器只根据 `viewModel.displaySource` 设置选中项，没有读取 `currentPhoto.rawPath` 来控制 RAW segment 是否 enabled。

**直接后果：** 当前照片只有 JPG 时，用户仍然能点击 RAW。

**更深层后果：** 如果用户在只有 JPG 的照片上点击 RAW，`displaySourceStore().current` 会被写成 `.raw`。之后进入其他分组或重启 App 后，初始显示源仍可能是 RAW，遇到没有 RAW 的照片继续触发 fallback，形成持续的错误体验。

**建议修复：** 在浏览器控制器中增加一个最小函数，所有当前照片变化、视图初始化、删除后重载时都调用它。

```swift
private func updateSourceControlAvailability() {
    let hasRaw = viewModel.currentPhoto?.rawPath?.isEmpty == false
    sourceControl.setEnabled(hasRaw, forSegment: 1)

    if !hasRaw, viewModel.displaySource == .raw {
        sourceControl.selectedSegment = 0
        displaySourceStore().current = .jpg
        viewModel.setDisplaySource(.jpg)
    } else {
        sourceControl.selectedSegment = viewModel.displaySource == .jpg ? 0 : 1
    }
}
```

并在 `loadCurrentPhoto()` 开头调用：

```swift
private func loadCurrentPhoto() {
    loadTask?.cancel()
    mainPhotoController.reset()
    updateSourceControlAvailability()
    ...
}
```

`sourceChanged(_:)` 也建议增加防御式 guard，防止未来代码或快捷键绕过 disabled UI：

```swift
@objc private func sourceChanged(_ sender: NSSegmentedControl) {
    let source: displaySource = (sender.selectedSegment == 0) ? .jpg : .raw
    if source == .raw, viewModel.currentPhoto?.rawPath?.isEmpty != false {
        sender.selectedSegment = 0
        return
    }
    displaySourceStore().current = source
    viewModel.setDisplaySource(source)
    loadCurrentPhoto()
}
```

> 注意：上面的 `viewModel.setDisplaySource(.jpg)` 会增加 `currentRequestId`。如果直接放在 `loadCurrentPhoto()` 内，要注意 requestId 的读取顺序，避免异步请求被自己刚刚的状态修正判定为陈旧。更稳妥的写法是先修正 source，再读取 `requestId`。

---

### 🟠 [High] RAW 不可用时展示层静默回退 JPG，掩盖真实状态

**位置：** `rawViewer/browser/photoBrowserViewController.swift:155-169`、`rawViewer/duplicate/duplicateCompareViewController.swift:157-172`

**问题：** `show(pair:source:)` 在用户选择 RAW 时，如果 RAW 加载失败，会直接显示 JPG。这个 fallback 对容错有价值，但对“用户主动选择 RAW”的场景会误导用户。

**直接后果：** 用户点击 RAW 后仍看到图片，无法判断当前看到的是 JPG 还是 RAW。

**建议修复：** UI 禁用是第一优先级；同时建议展示层只在“当前 source 自动修正为 JPG”后显示 JPG，不要在用户选择 RAW 且 RAW 不存在时静默 fallback。至少应在开发日志或 UI 上提示：

```swift
if source == .raw, case .unavailable(let message) = pair.raw {
    mainPhotoController.showError(message)
    return
}
```

如果产品上仍希望 fallback，则需要明确标识当前显示的是 JPG，比如 toolbar 状态文案或 toast。否则用户会以为 RAW 成功加载。

---

### 🟡 [Medium] 重复图对比页存在同类 RAW segment 可用性问题

**位置：** `rawViewer/duplicate/duplicateCompareViewController.swift:68-70`、`rawViewer/duplicate/duplicateCompareViewController.swift:124-154`、`rawViewer/duplicate/duplicateCompareViewController.swift:188-190`

**问题：** 重复图对比页也创建了 `NSSegmentedControl(labels: ["JPG", "RAW"])`，并根据 `displaySourceStore` 设置选中项，但没有根据左右两张照片的 RAW 可用性禁用 RAW segment。

更麻烦的是，这里的 `sourceControl` 是 `loadView()` 内部局部变量，不是属性，后续 `keepLeft` / `keepRight` / `keepBoth` 导致比较对象变化后，控制器没有引用可更新 segment 状态。

**建议修复：**

1. 把 `sourceControl` 提升为属性。
2. 增加 `updateSourceControlAvailability()`。
3. 对重复比较页定义清晰产品规则：
   - 规则 A：左右两张都存在 RAW 时才允许选择 RAW。
   - 规则 B：任意一张存在 RAW 就允许选择 RAW，缺失的一侧显示“RAW missing”。

按当前用户诉求“没有 RAW 应该灰掉”，更建议规则 A：

```swift
private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)

private func updateSourceControlAvailability() {
    let leftHasRaw = viewModel.mainPhoto?.rawPath?.isEmpty == false
    let rightHasRaw = viewModel.candidatePhoto?.rawPath?.isEmpty == false
    let canShowRaw = leftHasRaw && rightHasRaw
    sourceControl.setEnabled(canShowRaw, forSegment: 1)

    if !canShowRaw, sourceStore.current == .raw {
        sourceStore.current = .jpg
        sourceControl.selectedSegment = 0
    } else {
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
    }
}
```

---

### 🟡 [Medium] RAW 可用性判断散落在 model/service/UI，缺少统一语义

**位置：** `rawViewer/models/photoModels.swift:202-209`、`rawViewer/services/photoDisplayService.swift:90-105`、浏览器/重复比较控制器

**问题：** 项目里已经有 `displayUrl(for:source:)` 可以表达 `.raw` 的 unavailable，但 UI 没使用；加载服务也用 `loadRaw(rawPath:)` 再判断一次。未来如果要判断“RAW 文件路径存在但文件已被移动/删除/无法解码”，各处判断标准容易不一致。

**建议修复：** 先不要做过度抽象，最小修复可只判断 `rawPath` 是否非空来满足当前需求。后续如要更准确，可在 model 增加只读属性：

```swift
public extension photoItem {
    var hasRawPath: Bool {
        rawPath?.isEmpty == false
    }
}
```

如果产品要求“路径存在但文件丢失时也灰掉”，则需要在 UI 层引入 `FileManager.fileExists` 或复用 display service 的 availability，但这会引入异步/IO 成本，需要单独设计。

---

## 根因总结

这不是扫描或分析链路无法识别“没有 RAW”。从代码看：

- `fileScanner` 能产生 `rawPath == nil`。
- `photoAnalysisService` 会把 `rawPath` 写入 `photoItem`。
- `analysisStore` 会持久化 `photoItem.rawPath`。
- `photoDisplayService` 在 `rawPath == nil` 时会返回 `RAW missing`。

真正缺失的是：

```text
photoItem.rawPath 是否存在
  -> 没有映射到 Browser / Duplicate Compare 的 RAW segment enabled 状态
```

同时，展示层 fallback：

```text
选择 RAW
  -> RAW missing
  -> 自动显示 JPG
```

进一步掩盖了错误，使用户无法从画面判断自己看到的是 JPG 还是 RAW。

---

## 推荐修复优先级

1. **优先修普通浏览器 `photoBrowserViewController`**
   - 这是用户当前直接反馈的路径。
   - 根据当前照片 `rawPath` 禁用 RAW segment。
   - 当前照片没有 RAW 且全局 source 是 RAW 时，自动切回 JPG。

2. **同步修重复图对比页 `duplicateCompareViewController`**
   - 同类控件同类问题。
   - 需要先把局部 `sourceControl` 提升为属性，否则无法在比较对象变化后更新状态。

3. **重新审视 RAW missing fallback 策略**
   - 若 RAW 按钮已灰掉，fallback 触发概率会降低。
   - 但路径丢失、解码失败、RAW 文件过大时仍可能发生。
   - 用户主动选择 RAW 时，建议不要静默显示 JPG，至少要提示或明确标识。

---

## 验证建议

### 手工验证

准备一个测试目录：

```text
A.jpg          # 无 RAW
B.jpg
B.cr2          # 有 RAW
C.jpg          # 无 RAW
```

验证普通分组：

1. 重新分析该目录。
2. 进入任意普通分组。
3. 选中 `A.jpg`：RAW segment 应为灰色，不可点击。
4. 切到 `B.jpg`：RAW segment 应恢复可点击。
5. 切回 `C.jpg`：RAW segment 应再次灰色。
6. 如果之前全局显示源保存为 RAW，打开 `A.jpg` 时应自动回到 JPG，不能让 RAW 保持选中。

验证重复图对比页：

1. 构造重复组中一张有 RAW、一张无 RAW。
2. 进入重复比较。
3. 按产品规则验证 RAW segment：
   - 若采用“左右都要有 RAW 才能看 RAW”，则应该灰色。
   - 若采用“任意有 RAW 可看”，则缺失的一侧必须明确显示 RAW missing，不能静默用 JPG 假装 RAW。

### 自动化测试建议

可补充 ViewModel 或轻量 UI 状态测试，把判断逻辑抽成纯函数后测试：

```swift
func canSelectRaw(for photo: photoItem?) -> Bool {
    photo?.rawPath?.isEmpty == false
}
```

测试用例：

- `rawPath == nil` -> false
- `rawPath == ""` -> false
- `rawPath == "/tmp/a.cr2"` -> true

重复比较页如果采用“左右都要有 RAW”规则：

```swift
func canSelectRaw(left: photoItem?, right: photoItem?) -> Bool {
    left?.rawPath?.isEmpty == false && right?.rawPath?.isEmpty == false
}
```

测试用例：

- left 有 RAW，right 有 RAW -> true
- left 有 RAW，right 无 RAW -> false
- left 无 RAW，right 有 RAW -> false
- left/right 任意 nil -> false

---

## 本次是否修改代码

本次仅做问题链路审阅与落档，未修改业务代码，未运行构建。建议下一步按上述优先级做最小修复。