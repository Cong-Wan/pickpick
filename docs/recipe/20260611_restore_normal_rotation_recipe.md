# Recipe — Restore Normal 与照片旋转持久化

## 背景

当前 App 会把照片按分析结果分为 `overexposed`、`underexposed`、`blurry`、`normal` 和 `duplicate` 分组。用户希望增加两个能力：

1. 在过曝、欠曝、虚焦分组中，可以把当前照片或左侧缩略图勾选的多张照片放回 `normal` 分组。
2. 在所有分组查看照片时，支持左旋 / 右旋 90°，并且 JPG / RAW 切换时保持同一张照片的旋转状态。

已确认产品决策：

- Restore Normal 直接修改分析分类字段：`exposureStatus = "normal"` 且 `isBlurry = false`。
- 旋转状态持久保存到 `analysis.json`。
- 旋转只影响 App 内显示，不修改 JPG/RAW 原始文件。
- duplicate 分组也包含旋转按钮，且左右两张当前对比照片一起旋转。
- 普通单图页采用布局 C：旋转按钮放顶部工具栏，Restore Normal 放左侧缩略图区。
- Restore Normal 在无勾选时作用于当前大图；有勾选时批量作用于勾选照片。
- Restore Normal / Rotate 的失败都要写入 app log，方便排查。

## 目标

### 功能目标

- 过曝、欠曝、虚焦分组支持把照片还原为 normal。
- 左侧缩略图多选后支持批量还原为 normal。
- 普通单图页支持左旋 / 右旋当前大图。
- duplicate 对比页支持左旋 / 右旋当前左右两张图。
- 旋转角度在 JPG/RAW 切换、返回分组页、App 重启后保持。
- 旧 `analysis.json` 没有旋转字段时仍能正常读取。
- 操作失败时写入 `appFileLogger` 并弹窗提示。

### 非目标

- 不修改 JPG/RAW 原始文件。
- 不写 EXIF orientation。
- 不增加撤销按钮。
- 不增加任意角度旋转。
- 不让 Restore Normal 出现在 duplicate 页。
- 不重构缩略图加载服务。
- 不改变曝光 / 虚焦分析算法。
- 不改变 duplicate keep 逻辑。

## 方案选择

采用方案：在 `photoItem` 上新增持久字段 `rotationDegrees`，展示层按该字段渲染旋转。

不采用单独 `rotationStateStore`，因为当前人工状态已经写回 `analysis.json`，再引入独立 store 会增加同步和 folder 绑定复杂度。

不采用内存态旋转，因为用户已确认旋转需要持久保存。

## 数据模型与持久化

### `photoItem.rotationDegrees`

在 `rawViewer/models/photoModels.swift` 的 `photoItem` 中新增：

```swift
public var rotationDegrees: Int
```

规则：

- 只保存 `0 / 90 / 180 / 270`。
- 默认值为 `0`。
- 左旋：`(rotationDegrees + 270) % 360`。
- 右旋：`(rotationDegrees + 90) % 360`。
- JPG 和 RAW 共用同一个角度，因此切换 JPG/RAW 时天然保持旋转。

### 旧 JSON 兼容

`photoItem` 的 `Codable` 需要兼容旧缓存：

- 旧 JSON 缺少 `rotationDegrees` 时解码为 `0`。
- 新保存后写入 `rotationDegrees`。

### Restore Normal 写入规则

在 `jsonReviewStateStore` 中通过 `update(_:)` 修改目标照片：

```swift
items[index].exposureStatus = "normal"
items[index].isBlurry = false
```

不修改：

- `reviewStatus`
- `reviewGroupId`
- `templatePhotoId`
- `analysisSource`
- `dynamicRange`
- 原始 JPG/RAW 文件

### Rotate 写入规则

单图浏览页：

- 旋转当前照片。
- 写回 `analysis.json`。
- 同步更新当前 ViewModel 的 `photos`。

Duplicate 对比页：

- 当前左右两张照片一起旋转。
- 两张照片分别写回 `analysis.json`。
- 同步更新 ViewModel 中左右照片的 `rotationDegrees`。

## 普通单图浏览页交互

范围：`photoBrowserViewController`，用于 `overexposed`、`underexposed`、`blurry`、`normal` 普通单图分组。

### 分组上下文传递

当前 `appCoordinator.showBrowser(group:)` 使用 `photoBrowserViewController(viewModel:imageService:)` 初始化浏览页，因此控制器本身不能可靠知道当前 `photoGroupKind`。本功能需要让浏览页知道当前分组类型，用于标题展示和 Restore Normal 可见性判断。

设计要求：

- `photoBrowserViewController` 接收当前 `photoGroupKind` 或等价的 `groupTitle` + `canRestoreNormal` 标志。
- `appCoordinator.showBrowser(group:)` 创建浏览页时传入 `group.kind`。
- Restore Normal 仅当当前分组 kind 是 `.overexposed / .underexposed / .blurry` 时显示。
- `normal` 普通分组不显示 Restore Normal。

### 按钮位置

采用布局 C：

- 顶部工具栏新增：
  - `⟲ 90°`
  - `⟳ 90°`
- 左侧缩略图区域新增：
  - `Restore Normal`

### Restore Normal 行为

- 只在 `overexposed / underexposed / blurry` 普通分组显示。
- `normal` 分组不显示。
- 有勾选：还原勾选照片。
- 无勾选：还原当前大图。

成功后：

- 从当前 `viewModel.photos` 中移除目标照片。
- 清理 checked 状态。
- 当前索引移动到合理位置：优先同位置下一张，否则上一张。
- 当前组为空时触发 `onBack` 回到分组页。

### 旋转行为

- 所有普通单图分组显示旋转按钮。
- 只旋转当前大图，不作用于勾选照片。
- 写入成功后立即更新 UI。
- JPG/RAW 切换时使用同一个 `rotationDegrees`。

### 普通页错误处理与日志

Restore Normal 写入失败：

- 写入 `appFileLogger`，level `.error`。
- 弹出已有 `Operation failed` alert。
- 不移除 UI 中照片。
- 不清空勾选状态。

日志字段：

```text
page=browser action=restoreNormal targetCount=<count> photoIds=<ids> error=<localizedDescription>
```

旋转写入失败：

- 写入 `appFileLogger`，level `.error`。
- 弹出 alert。
- 保持旧旋转角度。
- 不重载图片。

日志字段：

```text
page=browser action=rotateLeft|rotateRight photoId=<id> oldRotation=<old> targetRotation=<target> error=<localizedDescription>
```

## Duplicate 对比页交互

范围：`duplicateCompareViewController`。

### 按钮位置

Duplicate 页没有左侧缩略图区，因此旋转按钮放顶部工具栏。

建议顺序：

```text
Back | Duplicate · N | JPG/RAW | ⟲ 90° | ⟳ 90° | Keep both
```

### 旋转行为

点击旋转时，左右两张当前正在对比的照片一起旋转。

左旋：

```text
left.rotationDegrees  = (left.rotationDegrees + 270) % 360
right.rotationDegrees = (right.rotationDegrees + 270) % 360
```

右旋：

```text
left.rotationDegrees  = (left.rotationDegrees + 90) % 360
right.rotationDegrees = (right.rotationDegrees + 90) % 360
```

如果只有左图、没有右图，则只旋转左图。

### 与 Keep 行为的关系

- 旋转只改变展示状态，不改变 duplicate 判断。
- `keepLeft` / `keepRight` / `keepBoth` 不清空旋转角度。
- 保留下来的照片在其它分组中仍保持此前旋转角度。
- 被丢进废纸篓的照片可能仍在 JSON 中保留旋转状态，本轮不额外清理。

### JPG/RAW 切换

- 左右两张图分别使用自己的 `rotationDegrees`。
- 点击旋转后左右都会各自加减 90°。
- 切换 JPG/RAW 时：左图保持左图角度，右图保持右图角度。
- 如果某侧 RAW 不可用并 fallback JPG，仍应用该侧照片的旋转角度。

### Duplicate 错误处理与日志

旋转写入失败：

- 写入 `appFileLogger`，level `.error`。
- 弹出 `Operation failed` alert。
- 不更新 UI，保持旧角度。

日志字段：

```text
page=duplicate action=rotateLeft|rotateRight leftPhotoId=<id> rightPhotoId=<id?> oldLeftRotation=<old> targetLeftRotation=<target> oldRightRotation=<old?> targetRightRotation=<target?> error=<localizedDescription>
```

没有可旋转照片时：

- 旋转按钮禁用。
- 不记 error，因为这是正常 UI 状态。

## 渲染旋转实现

范围：`photoMetalViewController` 和 `metalPhotoView`。

### 展示层旋转

加载流程保持为：

```text
photoImageService.preloadDisplayPair(for:)
  -> 得到 JPG / RAW 的 CIImage
  -> browser 或 duplicate 选择 source
  -> photoMetalViewController.load(image:rotationDegrees:)
  -> metalPhotoView.setImage(image, rotationDegrees:)
  -> draw 时按角度渲染
```

### API 调整

`photoMetalViewController` 当前 API：

```swift
public func load(image: CIImage?)
```

调整为：

```swift
public func load(image: CIImage?, rotationDegrees: Int = 0)
```

`metalPhotoView` 增加状态：

```swift
private var rotationDegrees: Int = 0
```

并调整 API：

```swift
public func setImage(_ image: CIImage?, rotationDegrees: Int = 0)
```

### 绘制逻辑

`draw(_:)` 中按 `rotationDegrees` 处理：

1. 归一化角度到 `0 / 90 / 180 / 270`。
2. 根据旋转后展示尺寸计算 `fitScale`：
   - `0 / 180` 使用原始宽高。
   - `90 / 270` 使用交换后的宽高。
3. 构造 affine transform：
   - 先把图片移动到原点。
   - 应用旋转。
   - 修正旋转后坐标落点。
   - 应用缩放。
   - 移动到视图中心并叠加 pan offset。
4. 使用 `ciContext.render(image.transformed(by: transform), ...)` 渲染。

### 缩放和平移

- 旋转不会重置 zoom。
- 旋转不会重置 pan。
- 如果旋转后图片宽高变化，用户可以按 `R` 重置缩放/平移。
- 本轮不自动修正 pan，避免引入复杂行为。

### 空态与错误态

- `clearImage()` 同时把 `rotationDegrees` 重置为 0。
- `showError()` 不需要显示旋转。
- 下一次成功加载图片时重新设置角度。

## 验证计划

### 构建验证

实施后运行：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

成功标准：Debug build 通过，无新增 Swift 编译错误，无旧缓存 Codable 解码崩溃。

### 普通单图浏览验证

准备测试照片：

- overexposed 组至少 2 张。
- underexposed 组至少 2 张。
- blurry 组至少 2 张。
- normal 组至少 1 张。
- 尽量包含 JPG+RAW 成对照片。

验收：

1. overexposed / underexposed / blurry 页左侧显示 `Restore Normal`。
2. normal 页不显示 `Restore Normal`。
3. 没勾选时点击 `Restore Normal`，当前大图进入 normal，当前组列表减少。
4. 勾选多张后点击 `Restore Normal`，多张一起进入 normal。
5. 当前组清空后自动回到分组页。
6. 点击左旋 / 右旋，当前图立即旋转 90°。
7. 连续旋转 4 次后回到原角度。
8. JPG 旋转后切 RAW，角度保持。
9. RAW 旋转后切 JPG，角度保持。
10. 返回分组页再进入，角度保持。
11. 重启 App 后角度保持。

### Duplicate 对比页验证

验收：

1. duplicate 页顶部显示左旋 / 右旋按钮。
2. 点击右旋，左右两张图一起顺时针 90°。
3. 点击左旋，左右两张图一起逆时针 90°。
4. 左右两张图的角度分别写入 JSON。
5. JPG/RAW 切换后，左右各自角度保持。
6. Keep Left / Keep Right / Keep Both 后，保留下来的照片在其它分组里仍保持旋转。
7. 如果某侧 RAW fallback JPG，仍应用旋转。

### JSON 兼容验证

1. 使用旧 `analysis.json`，里面没有 `rotationDegrees` 字段。
2. App 能正常读取。
3. 所有照片默认角度为 0。
4. 旋转任意照片后，重新保存的 JSON 包含 `rotationDegrees`。
5. Restore Normal 不破坏其它字段：
   - `reviewStatus`
   - `reviewGroupId`
   - `templatePhotoId`
   - `dynamicRange`
   - `analysisSource`

### 日志验证

人工制造 JSON 写入失败或 store 失败时，检查：

- Restore Normal 失败写入 `.error` 日志。
- Browser rotate 失败写入 `.error` 日志。
- Duplicate rotate 失败写入 `.error` 日志。
- UI 弹出 `Operation failed`。
- UI 不提前移除照片或改变旋转角度。

日志目录沿用现有：

```text
~/Library/Application Support/rawViewer/logs/
```

## 实施顺序建议

1. 修改 `photoItem`，新增 `rotationDegrees` 并处理旧 JSON 解码默认值。
2. 在 `jsonReviewStateStore` 或对应 ViewModel 中增加 Restore Normal 与 Rotate 操作。
3. 修改 `photoBrowserViewModel`，支持还原目标、旋转当前照片、同步内存照片列表。
4. 修改 `appCoordinator.showBrowser(group:)` 与 `photoBrowserViewController` 初始化参数，传入当前普通分组 kind 或等价显示/能力标志。
5. 修改 `photoBrowserViewController`，添加左侧 Restore Normal 按钮与顶部旋转按钮。
6. 修改 `duplicateCompareViewModel`，支持左右照片一起旋转。
7. 修改 `duplicateCompareViewController`，添加旋转按钮和失败日志。
8. 修改 `photoMetalViewController` 与 `metalPhotoView`，按 `rotationDegrees` 渲染。
9. 运行 Debug build。
10. 按验证计划做人工验收。
