# rawViewer App Bug Fix 重构方案

**Author:** wilbur  
**Version:** 1.0  
**Date:** 2026-06-03  
**Description:** 定义 rawViewer 在不改变 App 用户可见布局的前提下，通过内部 ViewModel、图片服务、缓存和显示层重构修复首页样式、分组预览、响应式分组列、返回导航、缩略图、图片叠加、RAW/JPG 切换延迟、缩放刷新和 duplicate 两张图边界问题。

## 1. 背景与目标

当前 rawViewer App 已能构建运行，但存在明显 UI/交互/图片显示 bug：

1. 首页选择文件夹控件样式与既有 HTML 设计不一致。
2. 分组卡片不显示真实图片，只显示灰色占位。
3. 分组页硬编码每行 2 个卡片，不能随窗口宽度自适应。
4. 分组页、普通浏览页、duplicate 页缺少返回按钮。
5. 普通浏览页左侧缩略图区域没有真实预览图。
6. 上下键切换照片时旧图未清空，可能叠加下一张图。
7. RAW/JPG 切换时才现场加载，导致约 1 秒延迟。
8. 缩放时有明显整图刷新体感，加载与缩放职责耦合。
9. duplicate 分组只有 2 张照片时，左右选择键边界行为不稳定。

本方案选择“方案 C”：**保留 App 用户看到的布局不变，但内部做数据驱动重构**。重构目标是修 bug、提升性能、让代码更清晰；不能借重构改变页面结构、控件位置和交互语义。

## 2. 明确约束

### 2.1 不改变用户可见布局

以下页面结构保持不变：

| 页面 | 保持的布局语义 |
|---|---|
| 首页 | 中央文件夹选择入口 |
| 分组页 | 分组卡片网格 |
| 普通浏览页 | 顶部工具栏 + 左侧缩略图栏 + 右侧主图 |
| duplicate 页 | 顶部工具栏 + 左右双图对比 |
| 进度页 | 当前进度展示结构 |

允许修复明显错误控件实现，例如把首页普通按钮替换为既有设计要求的虚线 drop zone；这属于样式 bug 修复，不属于布局重设计。

### 2.2 可以大幅改内部代码

为了性能、稳定性和代码优雅，可以引入：

- ViewModel；
- 统一图片加载服务；
- 图片缓存；
- 更清晰的导航模型；
- 更薄的 ViewController；
- 更单一职责的 `metalPhotoView`。

## 3. 总体架构

重构后的分层：

```plain
ViewController / NSView
        ↓ 绑定展示
ViewModel
        ↓ 调用服务
Service / Loader / Cache / Store
        ↓ 读写
File system / analysis.json / Core Image / Metal
```

设计原则：

1. **布局冻结**：用户看到的页面结构不因重构改变。
2. **状态集中**：数组、index、checked、source、加载状态进入 ViewModel。
3. **图片加载集中**：JPG、RAW、thumbnail 统一走 service/cache。
4. **显示层变薄**：`metalPhotoView` 只显示已准备好的图片，不直接处理路径读取和 fallback。
5. **可测试**：ViewModel、列数计算、duplicate 边界、加载状态都能单独测试。
6. **异步防竞态**：快速切图时旧请求不能覆盖当前 UI。

## 4. 新增与重构模块

### 4.1 `appNavigationViewModel.swift`

职责：

- 管理当前页面状态：start、progress、groups、browser、duplicateCompare、error。
- 持有当前 folder、records、groups、selected group。
- 提供导航动作：
  - `showStart()`
  - `startAnalysis(folderUrl:)`
  - `showGroups(records:)`
  - `openGroup(_:)`
  - `backToStart()`
  - `backToGroups()`
  - `showError(message:)`

返回规则：

| 当前页面 | 返回目标 |
|---|---|
| groups | start |
| browser | groups |
| duplicateCompare | groups |

`mainWindowController` 作为窗口和页面 controller 组装点，不再散落复杂业务状态判断。

### 4.2 `groupGridViewModel.swift`

职责：

- 输入 `[photoItem]` 或 `[photoGroup]`。
- 输出可显示分组。
- 过滤空分组。
- 计算分组卡片响应式列数。
- 为每个卡片提供前 1~3 张 JPG 预览照片。
- 判断点击分组后的路由类型。

核心接口：

```swift
public final class groupGridViewModel {
    public private(set) var groups: [photoGroup]

    public func columnCount(for availableWidth: CGFloat) -> Int
    public func previewPhotos(for group: photoGroup) -> [photoItem]
    public func route(for group: photoGroup) -> groupRoute
}
```

列数规则：

- 至少 1 列。
- 根据可用宽度、卡片最小宽度、列间距计算。
- 不再硬编码 `maxColumns = 2`。
- 保持分组卡片网格布局语义不变。

### 4.3 `photoBrowserViewModel.swift`

职责：

- 管理普通浏览页照片数组。
- 管理当前 index。
- 管理 checked photo ids。
- 管理当前 display source。
- 管理当前照片 JPG/RAW 加载状态。
- 处理上下键、缩略图点击、单选、全选、删除目标计算和删除后切换。
- 当前照片变化时触发图片预加载。

核心接口：

```swift
public final class photoBrowserViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int
    public private(set) var checkedPhotoIds: Set<String>

    public var currentPhoto: photoItem? { get }

    public func movePrevious()
    public func moveNext()
    public func setCurrentIndex(_ index: Int)
    public func toggleCheck(photoId: String, isChecked: Bool)
    public func toggleAll(isChecked: Bool)
    public func deleteTargets() -> [photoItem]
    public func confirmDelete() throws
}
```

异步加载规则：ViewModel 维护当前 `photoId` 或 `requestId`，旧请求结果不能覆盖新当前照片。

### 4.4 `duplicateCompareViewModel.swift`

职责：

- 替换当前 `duplicateCompareState`。
- 管理 duplicate 对比状态。
- 处理 keepLeft、keepRight、keepBoth。
- 修复 2 张图边界。
- 结束时触发返回 groups。
- 不让 ViewController 直接操作 `photos.remove(at:)`、`mainIndex`、`candidateIndex` 或 JSON store 细节。

2 张图边界规则：

```plain
photos.count == 2
左键 keepLeft:
  右图 trashed
  左图 kept
  左图设为 template
  finish

photos.count == 2
右键 keepRight:
  左图 trashed
  右图 kept
  右图设为 template
  finish
```

### 4.5 `photoImageService.swift`

职责：

- 加载 JPG。
- 加载 RAW。
- 生成缩略图。
- 当前照片变更时预加载 JPG + RAW。
- 加载失败时返回明确状态。
- 防止 View 和 Controller 里散落文件读取逻辑。

建议类型：

```swift
public enum photoImageKind: Hashable {
    case thumbnail(size: CGSize)
    case displayJpg
    case displayRaw
}

public enum photoImageResult {
    case image(CIImage)
    case unavailable(String)
}
```

核心接口：

```swift
public final class photoImageService {
    public func loadImage(for photo: photoItem, kind: photoImageKind) async -> photoImageResult
    public func preloadDisplayPair(for photo: photoItem) async -> photoDisplayPair
}
```

### 4.6 `photoImageCache.swift`

职责：

- 使用 `NSCache` 做内存缓存。
- 以 `photoId + image kind + size` 为 key。
- 缩略图和显示图分开缓存。
- 避免上下键切换、RAW/JPG 切换、缩放时重复读取和 decode。

缓存策略：

- group card 缩略图缓存小图。
- sidebar 缩略图缓存小图。
- JPG display 可缓存当前和相邻照片。
- RAW display 较大，优先只缓存当前照片和最近使用项。
- 依赖 `NSCache` 响应内存压力，不实现复杂淘汰算法。

### 4.7 `metalPhotoView.swift`

重构后职责：

- 接收已加载好的 `CIImage`。
- 清空旧图。
- 等比显示。
- 缩放。
- 显示错误状态。

关键接口：

```swift
public func setImage(_ image: CIImage?)
public func clearImage()
public func showError(_ message: String)
```

路径加载逻辑迁移到 `photoImageService`。缩放只改变 zoom/transform 状态，不读取磁盘、不重新 decode。

## 5. 现有文件改动范围

### 5.1 `startViewController.swift`

保留：选择文件夹、拖拽文件夹。

修改：

- 将普通 `NSButton` 替换为自定义虚线 drop zone view。
- 显示大号 `+`、`点击选择文件夹`、`或拖入文件夹`。
- 点击区域仍触发 `chooseFolder()`。

### 5.2 `groupGridViewController.swift`

保留：分组卡片网格、点击分组进入对应页面。

修改：

- 使用 `groupGridViewModel`。
- 移除 `maxColumns = 2`。
- 根据 view 宽度 rebuild grid。
- 增加返回按钮，触发 `onBack`。
- 卡片继续使用 `groupCardView`。

### 5.3 `groupCardView.swift`

保留：叠放图片 + 底部分组名和数量。

修改：

- 从 ViewModel 获得预览照片。
- 通过 `photoImageService` 异步加载 JPG 缩略图。
- 成功后显示真实图片。
- 失败时保留占位。

### 5.4 `photoThumbnailView.swift`

保留：左侧固定宽度、顶部全选、每项 56 高、checkbox、选中边框。

修改：

- 每个 item 显示真实 JPG 缩略图。
- 点击/勾选只通知 ViewModel。
- 勾选状态由 ViewModel 回写。
- 刷新时优先使用缓存，避免重复 decode。

### 5.5 `photoBrowserViewController.swift`

重构为 UI 绑定层：

- 绑定 toolbar、thumbnail view、main `metalPhotoView`。
- 接收键盘事件。
- 调用 ViewModel。
- 根据 ViewModel 和 image service 结果刷新 UI。

不再直接管理 checked ids、删除目标、当前照片状态或 JPG/RAW 复杂加载。

### 5.6 `duplicateCompareViewController.swift`

重构为 UI 绑定层：

- 显示左右图。
- 响应左右键和 Keep both。
- 调用 `duplicateCompareViewModel`。
- 完成时触发 `onFinished` 返回分组页。

### 5.7 `mainWindowController.swift`

职责：

- 创建页面 controller。
- 注入对应 ViewModel、service、store。
- 处理 back callback。
- 通过 `appNavigationViewModel` 管理状态。

## 6. 数据流

### 6.1 进入文件夹

```plain
startViewController
  → onFolderSelected(url)
  → mainWindowController
  → appNavigationViewModel.startAnalysis(folderUrl)
  → progressViewController
  → analyzer
  → records
  → appNavigationViewModel.showGroups(records)
  → groupGridViewController(viewModel)
```

### 6.2 分组页预览图

```plain
groupGridViewController
  → groupGridViewModel.previewPhotos(group)
  → groupCardView.configure(previewPhotos)
  → photoImageService.loadImage(kind: thumbnail)
  → photoImageCache
  → thumbnail image
  → card image view
```

### 6.3 普通浏览切图

```plain
keydown ↑/↓
  → photoBrowserViewController
  → photoBrowserViewModel.movePrevious/moveNext
  → currentPhoto changes
  → metalPhotoView.clearImage()
  → photoImageService.preloadDisplayPair(currentPhoto)
  → display selected source when ready
```

清空旧图必须发生在新图加载前，避免旧图叠加。

### 6.4 RAW/JPG 切换

```plain
currentPhoto changed
  → preload JPG + RAW

user changes segmented control
  → viewModel.setDisplaySource(.raw/.jpg)
  → get cached image from display pair
  → metalPhotoView.setImage(image)
```

RAW 不可用时：

```plain
RAW result = unavailable
  → RAW segment disabled or shows unavailable
  → keep JPG visible
```

### 6.5 缩放

```plain
keyboard / pinch
  → metalPhotoView.zoomIn/zoomOut/reset
  → update zoom state
  → draw using existing CIImage
```

缩放不能触发文件读取、RAW decode、JPG decode 或 cache miss 加载。

### 6.6 duplicate 两张边界

```plain
Duplicate group with 2 photos
  → duplicateCompareViewModel

left arrow:
  → trash right
  → keep left
  → set left as template
  → finish
  → onFinished
  → mainWindowController.backToGroups()

right arrow:
  → trash left
  → keep right
  → set right as template
  → finish
  → onFinished
  → mainWindowController.backToGroups()
```

## 7. 错误处理

### 7.1 图片加载失败

| 场景 | 行为 |
|---|---|
| 分组卡片 JPG 缩略图失败 | 保留占位块，不影响卡片点击 |
| 左侧缩略图 JPG 失败 | 显示占位底色，不影响选择/勾选 |
| 主图 JPG 失败 | `metalPhotoView.clearImage()` 后显示错误文案 |
| RAW 不存在 | RAW segment 置灰或不可切 |
| RAW decode 失败 | RAW segment 置灰，保持/回退 JPG |
| JPG/RAW 都不可用 | 主图显示 `No image available` |

关键规则：

- 不能保留上一张图当成当前图。
- 不能因为某张图失败导致页面崩溃。
- 不能把 RAW 失败伪装成 RAW 成功。

### 7.2 异步加载竞态

快速切图时，旧请求可能晚于新请求返回。解决方式：

- ViewModel 维护 `currentPhotoId` 或 `requestId`。
- 每次加载时携带请求身份。
- 回调更新 UI 前校验当前 photo/source 是否仍匹配。
- 不匹配则丢弃结果。

### 7.3 删除与 JSON 更新失败

删除流程顺序：

1. 用户确认。
2. 尝试移动文件到废纸篓。
3. 成功后更新 JSON。
4. 成功后更新 ViewModel 列表。
5. 切换到相邻照片。

若 JSON 更新失败，不从 UI 列表移除。若移动废纸篓失败，不标记为已删除。

### 7.4 返回行为

- groups 返回 start：清理 selected group。
- browser 返回 groups：保留 records 和 current folder。
- duplicate 返回 groups：重新按当前 records/JSON 状态生成 groups。
- records 不存在时退回 start，不崩溃。

## 8. 性能策略

### 8.1 缩略图

- 分组卡片和左侧缩略图只加载 JPG。
- 分组卡片目标尺寸约 `160 x 110` 或更小。
- 左侧缩略图目标尺寸约 `150 x 56`。
- 使用统一下采样逻辑。
- cache key 包含 photoId、kind、target width、target height。

### 8.2 主图预加载

当前照片变化时调用：

```plain
preloadDisplayPair(currentPhoto)
```

加载：

- JPG display image。
- RAW display image，如果 `rawPath` 存在。
- RAW 失败记录 unavailable。
- 默认 source 先显示，另一个 source 后台准备。

内存控制：

- JPG 缓存当前和相邻照片。
- RAW 优先只缓存当前照片和最近使用项。
- 使用 `NSCache` 避免手写复杂内存回收。

### 8.3 快速切图

流程：

1. 立即更新 current index。
2. 立即高亮左侧缩略图。
3. 立即 `metalPhotoView.clearImage()`。
4. 缓存命中则立刻显示。
5. 缓存未命中则显示轻量 loading/空状态。
6. 异步加载完成后校验 request，再显示。

### 8.4 RAW/JPG 切换

- 优先使用当前照片的 display pair。
- 目标 source 已加载则立即显示。
- 目标 source 加载中则显示 loading 状态。
- 目标 source unavailable 则禁用或回退。
- segmented action 中不直接读磁盘。

### 8.5 缩放

`metalPhotoView` 保存当前 `CIImage` 与 zoom 状态。`zoomIn/zoomOut/reset` 只修改 zoom，不触发图片服务、不读取文件、不重新 decode。

## 9. 实施顺序

```plain
1. ViewModel 状态机落地
   验证：ViewModel 脚本测试通过

2. photoImageService/cache 落地
   验证：mock service/cache 测试通过

3. metalPhotoView 职责收窄 + 清屏/缩放状态修复
   验证：metalPhotoViewStateTests + 构建通过

4. 绑定 group/browser/duplicate controller
   验证：分组真实预览、缩略图、预加载切换、返回按钮

5. 全量回归
   验证：xcodebuild + tests + 手动验证清单
```

## 10. 测试计划

### 10.1 `tests/groupGridViewModelTests.swift`

覆盖：

- 空分组过滤。
- 普通组路由到 browser。
- duplicate 组路由到 duplicate。
- 宽度很小时至少 1 列。
- 宽度足够时列数增加。
- preview photos 最多 3 张。

### 10.2 `tests/photoBrowserViewModelTests.swift`

覆盖：

- 上下键边界。
- 选择缩略图。
- 单张勾选。
- 全选。
- 无勾选时删除当前照片。
- 有勾选时删除勾选照片。
- 删除后 currentIndex 合理。
- currentPhoto 变化生成新 request id。
- 旧 request id 不能更新当前 UI 状态。

### 10.3 `tests/duplicateCompareViewModelTests.swift`

覆盖：

- 2 张图 keepLeft：右图 trashed、左图 kept、template 为左图、finished 为 true。
- 2 张图 keepRight：左图 trashed、右图 kept、template 为右图、finished 为 true。
- 3 张图 keepLeft/keepRight 后继续流程。
- keepBoth 记录两张 kept 和 template。
- 无候选图时安全结束，不崩溃。

### 10.4 `tests/photoImageServiceTests.swift`

使用 mock loader 覆盖：

- JPG 可用返回 image。
- JPG 不存在返回 unavailable。
- RAW path 为空返回 unavailable。
- preload pair 同时请求 JPG/RAW。
- cache 命中时不重复 load。
- 加载失败不会污染成功缓存。

### 10.5 `tests/metalPhotoViewStateTests.swift`

不做真实 Metal 渲染，只测状态逻辑：

- `setImage` 后 current image 非空。
- `clearImage` 后 current image 为空。
- `showError` 后 image 清空。
- zoom 不改变 image。
- loading 新图前必须 clear 旧图。

### 10.6 构建验证

每轮实现后运行：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

当前基线：构建成功，仅有 `main.swift` Swift 6 actor warning。该 warning 不属于本次 bug 范围，除非重构触发相关问题。

## 11. 手动验证清单

1. 首页是虚线拖拽/点击区域，不再是普通按钮。
2. 选择文件夹后分组页正常出现。
3. 分组卡片显示真实 JPG 叠放预览。
4. 改变窗口宽度，分组每行数量自动变化。
5. 分组页返回按钮返回首页。
6. 普通分组页左侧真实缩略图可见。
7. 普通分组页返回按钮返回分组页。
8. 上下键快速切换，不叠加旧图。
9. JPG/RAW 切换明显无 1 秒卡顿或大幅减少卡顿。
10. 缩放不重新读文件、不明显闪烁。
11. duplicate 页返回按钮返回分组页。
12. duplicate 只有 2 张时，左右键都可用，并在选择后结束返回分组页。
13. RAW 不存在或解码失败时 UI 不崩，RAW 状态正确。

## 12. 范围外事项

以下内容不在本轮修复范围内：

- 重写 C++ 分析 pipeline。
- 改变 analysis.json 数据结构。
- 重新设计 App 页面布局。
- 增加新的照片筛选、排序、评分功能。
- 完整专业级 Metal texture 渲染引擎重写。

如果实现过程中发现 C++ 输出路径或 JSON 数据本身导致图片无法加载，只做必要兼容或 bug fix，并在实现报告中说明。
