# rawViewer 彻底重构方案（方案 2）

**Date**: 2026-06-06  
**Scope**: 修复 Top Level 性能问题 + 4 个交互/逻辑 BUG，通过架构重构根治根因  
**Risk Level**: 高（改动 8-10 个文件，重写 3 个核心视图组件）

---

## 1. 问题回顾

### Top Level

| # | 问题 | 根因 |
|---|---|---|
| 1 | App 极度卡顿 | `photoThumbnailView` 每次切图全量重建；`groupGridViewController` resize 全量重建；`MTKView` 持续空转渲染 |
| 2 | 内存飙升 8-9GB | `loadJpgThumbnail` 先加载完整图再缩放；JPG+RAW 同时缓存且共用 cache(countLimit=160)；缩略图缓存的是 `CIImage` 引用完整像素数据 |

### BUG 1-4

| # | 问题 | 根因 |
|---|---|---|
| BUG1 | 网格最右侧卡片截断 | `columnCount` 未扣除滚动条宽度；`NSGridView` 列宽分配与卡片约束冲突 |
| BUG2 | 每切一张图全部刷新 | `setCurrentIndex` → `reloadThumbnails()` 全量重建 |
| BUG3 | 放大后无法拖动 + zoom 状态延续 | `metalPhotoView` 无 `NSPanGestureRecognizer`；`loadCurrentPhoto()` 未调用 `resetZoom()` |
| BUG4 | Duplicate 完成后分组不消失 | `markFinalKept` 未清空 `reviewGroupId`；`onFinished` 使用内存旧 `records`；`makeVisiblePhotoGroups` 未将 surviving 照片归入 normal |

---

## 2. 架构目标

1. **视图增量更新**：滚动/切图/resize 时不重建视图，只更新状态
2. **内存隔离**：缩略图与 Display 图完全分离，缩略图使用真正的降采样加载
3. **状态机驱动**：`photoMetalViewController` 管理缩放/平移/加载/空态四态
4. **数据闭环**：Duplicate 处理完成后，surviving 照片自动归入 normal，JSON reload 后 UI 刷新

---

## 3. 组件架构

```
┌─────────────────────────────────────────┐
│         mainWindowController            │
│     (窗口管理 + 生命周期持有)            │
├─────────────────────────────────────────┤
│         appCoordinator                  │
│   (导航状态机 + 数据刷新 + 路由分发)      │
├─────────────────────────────────────────┤
│  startVC │ groupGridVC │ browserVC      │
│  │ duplicateCompareVC │ errorVC         │
│         ↑                               │
│    每个 VC 持自己的 ViewModel            │
├─────────────────────────────────────────┤
│  photoImageService (Facade)             │
│   ├─ photoThumbnailService              │
│   └─ photoDisplayService                │
└─────────────────────────────────────────┘
```

### 3.1 appCoordinator（新建）

**文件**: `rawViewer/appCoordinator.swift`

**职责**：
- 持有 `records: [photoItem]` 和 `groups: [photoGroup]`，作为全 app 的数据单一来源
- 管理 `windowScreenState` 枚举状态机
- 提供 `reloadData()` 方法：从 `analyzer.loadAnalysisResult(folderUrl:)` 重新读取 JSON
- 路由分发：`showStart()` / `showGroups()` / `showBrowser(group:)` / `showDuplicate(group:)` / `showError()`
- 所有子 VC 通过 `onNavigate` 闭包或 delegate 回调到 coordinator，coordinator 负责切换 contentViewController

**接口**：
```swift
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
    private var currentFolderUrl: URL?
    
    public init(window: NSWindow, analyzer: photoAnalyzerBridge)
    public func startAnalysis(folderUrl: URL)
    public func reloadData() throws
    // ... 路由方法
}
```

**为什么需要 coordinator**：
当前 `mainWindowController` 直接持有 `records` 和 `groups`，Duplicate 处理完后调用 `showGroups(records: self.records)` 导致数据不刷新。coordinator 作为数据持有者，Duplicate 完成后可调用 `reloadData()` 重新从磁盘读取，保证 `groups` 永远与 JSON 一致。

### 3.2 mainWindowController（改造）

**文件**: `rawViewer/mainWindowController.swift`

**改造点**：
- 移除 `records`、`groups`、`selectedGroup`、`currentFolderUrl`、`analyzer` 等数据状态
- 只保留窗口创建、菜单、生命周期管理
- 创建并持有 `appCoordinator`，把窗口和 analyzer 注入 coordinator
- 所有路由调用转交给 coordinator

### 3.3 groupGridViewController（重写）

**文件**: `rawViewer/groupGridViewController.swift`

**旧方案问题**：`NSGridView` + `buildGrid(columns:)` 在 resize 时反复销毁重建所有卡片。

**新方案**：`NSCollectionView` + `NSCollectionViewFlowLayout`（纯代码）。

**实现要点**：
- `NSCollectionView` 注册自定义 `groupCollectionViewItem`
- `NSCollectionViewFlowLayout` 动态计算列数：
  ```swift
  let availableWidth = collectionView.bounds.width - scrollerWidth - horizontalPadding * 2
  let columns = max(1, Int(availableWidth / (cardWidth + columnSpacing)))
  let actualCardWidth = (availableWidth - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)
  layout.itemSize = NSSize(width: actualCardWidth, height: cardHeight)
  ```
- resize 时通过 `collectionView.collectionViewLayout?.invalidateLayout()` 触发重新布局，`NSCollectionView` 内部只调整已有 item 的 frame，不销毁重建
- `groupCollectionViewItem` 内部使用 `groupCardView`（保留现有卡片 UI 和叠放预览逻辑），但 item 本身由 CollectionView 复用池管理

**文件新增**: `rawViewer/groupCollectionViewItem.swift`

```swift
public final class groupCollectionViewItem: NSCollectionViewItem {
    private var cardView: groupCardView?
    
    public func configure(with group: photoGroup, imageService: photoImageService)
    public override func prepareForReuse()   // 取消缩略图加载 task
}
```

### 3.4 photoThumbnailView（重写）

**文件**: `rawViewer/photoThumbnailView.swift`

**旧方案问题**：`NSStackView` 管理所有缩略图，`setCurrentIndex` 调用 `reloadThumbnails()` 全量重建。

**新方案**：`NSTableView` + `photoThumbnailCellView`。

**实现要点**：
- `photoThumbnailView` 继承 `NSView`，内部嵌入 `NSScrollView` + `NSTableView`
- `NSTableView` 单列，行高固定 56pt
- `photoThumbnailCellView`（`NSTableCellView` 子类）包含：
  - `NSImageView`（缩略图）
  - `NSButton`（checkbox）
  - 选中态边框（通过 `layer?.borderColor` 控制）
- `setCurrentIndex(_:)` 逻辑：
  ```swift
  let oldIndex = currentIndex
  currentIndex = index
  tableView.reloadData(forRowIndexes: [oldIndex, index], columnIndexes: [0])
  tableView.scrollRowToVisible(index)
  ```
- `updatePhotos(_:)` 时调用 `tableView.reloadData()`，但 `NSTableView` 只渲染可见行，不会同时创建 500 个 cell
- 缩略图异步加载由 cell 自己管理，dequeue 时取消旧 task、启动新 task

**文件新增**: `rawViewer/photoThumbnailCellView.swift`

```swift
public final class photoThumbnailCellView: NSTableCellView {
    private let imageView = NSImageView()
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var loadTask: Task<Void, Never>?
    
    public func configure(photo: photoItem, isSelected: Bool, isChecked: Bool, imageService: photoImageService)
    public func cancelLoad()
}
```

### 3.5 photoMetalViewController（新建）

**文件**: `rawViewer/photoMetalViewController.swift`

**旧方案问题**：`metalPhotoView` 是裸 `MTKView`，直接嵌入 VC；无拖动支持；zoom 状态未管理；持续渲染。

**新方案**：`photoMetalViewController` 包装 `MTKView`，内部管理状态机。

**状态机**：

```
┌──────────┐    load(photo:)     ┌──────────┐
│  empty   │ ──────────────────→ │ loading  │
└──────────┘                     └────┬─────┘
      ▲                               │ render success
      │                               ▼
   reset()  ←───────────────────  ┌──────────┐
                                   │  loaded  │
                                   └────┬─────┘
                              zoomIn/Out│
                                      ▼
                                   ┌──────────┐
                                   │  zoomed  │
                                   └────┬─────┘
                              pan       │
                                      ▼
                                   ┌──────────┐
                                   │  panned  │
                                   └──────────┘
```

**实现要点**：
- `MTKView` 设置 `isPaused = true`、`enableSetNeedsDisplay = true`
- 增加 `NSPanGestureRecognizer` 管理 `panOffset: CGPoint`
- `draw(_:)` 中变换矩阵：
  ```swift
  let fitScale = min(Double(w)/image.extent.width, Double(h)/image.extent.height)
  let effectiveScale = fitScale * userZoom
  let x = (Double(w) - image.extent.width * effectiveScale) / 2 + panOffset.x
  let y = (Double(h) - image.extent.height * effectiveScale) / 2 + panOffset.y
  ```
- 暴露接口：
  ```swift
  public func load(image: CIImage?)   // 进入 loaded 态
  public func reset()                  // 清空 image + zoom=1 + pan=0，进入 empty 态
  public func zoomIn() / zoomOut() / resetZoom()
  ```

**删除旧方法**：`metalPhotoView.swift` 中的兼容方法 `loadPhoto(url:source:)`、`loadJpgCompat`、`loadRawCompat` 全部删除。

### 3.6 photoImageService / photoThumbnailService / photoDisplayService（拆分）

**文件**: `rawViewer/photoImageService.swift`（改造为 Facade）  
**文件新增**: `rawViewer/photoThumbnailService.swift`  
**文件新增**: `rawViewer/photoDisplayService.swift`

**photoThumbnailService**：
- 使用 `CGImageSourceCreateThumbnailAtIndex` 加载真正缩略图
- 通过 `kCGImageSourceThumbnailMaxPixelSize` 控制输出像素尺寸
- 缓存 `NSCache<NSString, NSImage>`，countLimit = 200
- 返回 `NSImage` 而非 `CIImage`，避免引用原始像素数据

```swift
public final class photoThumbnailService {
    private let cache = NSCache<NSString, NSImage>()
    
    public func loadThumbnail(for photo: photoItem, size: NSSize) async -> NSImage?
    private func decodeThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage?
}
```

**photoDisplayService**：
- 负责 JPG/RAW display 加载
- 缓存 `NSCache<NSString, CIImage>`，countLimit = 20（严格控制大图像数量）
- RAW 解码前检查文件大小，拒绝异常大文件（>1GB）

```swift
public final class photoDisplayService {
    private let cache = NSCache<NSString, CIImage>()
    
    public func loadDisplayJpg(for photo: photoItem) async -> CIImage?
    public func loadDisplayRaw(for photo: photoItem) async -> CIImage?
}
```

**photoImageService（Facade）**：
- 对外保持 `preloadDisplayPair` / `loadImage(for:kind:)` 接口不变
- 内部根据 `photoImageKind` 分发到 thumbnailService 或 displayService
- 缩略图缓存不再存 `CIImage`，完全隔离

### 3.7 photoBrowserViewController（改造）

**文件**: `rawViewer/photoBrowserViewController.swift`

**改造点**：
- `mainPhotoView: metalPhotoView` → `mainPhotoController: photoMetalViewController`
- `loadView()` 中通过 `addChild(mainPhotoController)` 嵌入
- `loadCurrentPhoto()` 开头调用 `mainPhotoController.reset()`，确保 zoom 和 pan 归零
- `deleteClicked()` 后更新 toolbar title：`titleLabel.stringValue = "\(groupTitle) · \(viewModel.photos.count)"`

### 3.8 duplicateCompareViewController（改造）

**文件**: `rawViewer/duplicateCompareViewController.swift`

**改造点**：
- `leftPhotoView: metalPhotoView` → `leftPhotoController: photoMetalViewController`
- `rightPhotoView: metalPhotoView` → `rightPhotoController: photoMetalViewController`
- `loadPhotos()` 开头对两个 controller 调用 `reset()`

### 3.9 duplicateCompareViewModel（改造）

**文件**: `rawViewer/duplicateCompareViewModel.swift`

**改造点**：
- `markFinalKept` 增加清空 `reviewGroupId` 逻辑：
  ```swift
  private func markFinalKept(_ photo: photoItem) throws {
      try store.mark(photoId: photo.photoId, status: .kept)
      if !photo.reviewGroupId.isEmpty {
          try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
          try store.clearReviewGroupId(photoId: photo.photoId)   // 新增
      }
  }
  ```
- `jsonReviewStateStore` 新增 `clearReviewGroupId(photoId:)` 方法，在 JSON 中把对应 photo 的 `review_group_id` 设为空字符串

### 3.10 photoModels.makeVisiblePhotoGroups（改造）

**文件**: `rawViewer/photoModels.swift`

**改造点**：
- Duplicate 分组过滤增加：只包含 `reviewGroupId` 非空的照片
- 由于 `markFinalKept` 已清空 surviving 照片的 `reviewGroupId`，这些照片会自动落入 normal 过滤条件（`!isBlurry && exposureStatus == "normal"`）

---

## 4. 数据流

### 4.1 启动分析 → 显示分组

```
user 选择 folder
    ↓
mainWindowController.startAnalysis(folderUrl:)
    ↓
coordinator.startAnalysis(folderUrl:)
    ↓
显示 progressViewController
    ↓
analyzer.startAnalysis(...) 完成
    ↓
coordinator.reloadData()  // 读取 .cache/analysis.json
    ↓
coordinator.showGroups()  // groups = makeVisiblePhotoGroups(records)
    ↓
创建 groupGridViewController(viewModel: groupGridViewModel(groups:))
    ↓
window.contentViewController = groupGridViewController
```

### 4.2 Duplicate 处理完成 → 分组刷新

```
user 在 duplicateCompareViewController 按 ←/→ 完成全部选择
    ↓
viewModel.keepLeft() / keepRight() 返回 .finished
    ↓
controller.handleActionResult(.finished)
    ↓
controller.onFinished?()
    ↓
coordinator.showDuplicateFinished()
    ↓
coordinator.reloadData()  // 重新读取 JSON，surviving 照片 reviewGroupId 已清空
    ↓
coordinator.showGroups()  // 该 duplicate 分组消失，surviving 照片归入 normal
```

### 4.3 浏览器切图

```
user 按 ↓ / 点击缩略图
    ↓
photoBrowserViewController.keyDown / thumbnailDidSelect
    ↓
viewModel.moveNext() / setCurrentIndex()
    ↓
thumbnailView.setCurrentIndex(index)  // NSTableView 只刷新两行
    ↓
mainPhotoController.reset()  // zoom=1, pan=0
    ↓
photoImageService.preloadDisplayPair(for: photo)
    ↓
mainPhotoController.load(image: ciImage)  // 进入 loaded 态
```

---

## 5. 内存预算

| 缓存 | 类型 | 上限 | 估算单条大小 | 峰值内存 |
|------|------|------|-------------|---------|
| thumbnailCache | `NSImage` (降采样后) | 200 | ~50KB | ~10MB |
| displayJpgCache | `CIImage` (完整 JPG) | 20 | ~100MB | ~2GB |
| displayRawCache | `CIImage` (RAW) | 10 | ~500MB | ~5GB |

**策略**：
- `NSCache` 在内存压力下会自动释放，但上限设得更保守
- `preloadDisplayPair` 不再同时预加载 RAW，改为按需加载：先显示 JPG，用户切到 RAW 源时才加载 RAW
- 浏览器切图时，旧图的 display cache 可能被释放，但 thumbnail cache 长期保留（因为用户可能在缩略图列表中反复浏览）

---

## 6. 错误处理

| 场景 | 处理 |
|------|------|
| `reloadData()` JSON 读取失败 | coordinator 捕获 error，显示 errorVC，不崩溃 |
| `photoThumbnailService.decodeThumbnail` 失败 | 返回 nil，cell 保留 darkGray 占位 |
| `photoDisplayService.loadDisplayRaw` 文件 >1GB | 拒绝加载，返回 unavailable("RAW too large") |
| `metalPhotoViewController` drawable 缺失 | `draw(_:)` 直接 return，不 crash |
| Duplicate `keepLeft/Right` JSON 写入失败 | alert 提示用户，不推进状态 |

---

## 7. 测试策略

### 7.1 单元测试（改造现有 tests/）

| 测试文件 | 验证内容 |
|---------|---------|
| `photoBrowserViewModelTests` | `moveNext` 递增 `currentRequestId`；`confirmDelete` 移除照片并更新 checkedIds |
| `duplicateCompareViewModelTests` | `keepLeft` 到只剩一张时返回 `.finished`；JSON 中 `reviewGroupId` 被清空 |
| `groupGridViewModelTests` | `columnCount` 扣除滚动条宽度后计算正确 |
| `photoImageServiceTests` | Facade 正确分发 thumbnail/display；缩略图返回 `NSImage` |

### 7.2 集成测试（新增）

| 测试文件 | 验证内容 |
|---------|---------|
| `appCoordinatorTests` | `reloadData()` 后 `groups` 与 JSON 一致；Duplicate 完成后该分组消失 |
| `photoMetalViewControllerTests` | `reset()` 后 `currentZoom == 1.0`；`load(image:)` 后 `hasImage == true` |

### 7.3 性能验证（手动）

| 场景 | 验收标准 |
|------|---------|
| 500 张照片分组网格 | 内存 < 500MB；resize 不卡顿 |
| 进入 200 张的 browser | 缩略图列表内存 < 100MB；上下切图 < 100ms |
| RAW 切换 | 首次加载 RAW 有短暂 loading，第二次瞬间显示（cache 命中） |
| Duplicate 全部选择完成 | 退出后该分组卡片消失，normal 分组数量 +1 |

---

## 8. 文件变更清单

### 新建文件（6 个）

| 文件 | 说明 |
|------|------|
| `rawViewer/appCoordinator.swift` | 导航协调器 + 数据持有者 |
| `rawViewer/groupCollectionViewItem.swift` | CollectionView item |
| `rawViewer/photoThumbnailCellView.swift` | TableView cell |
| `rawViewer/photoMetalViewController.swift` | Metal 视图控制器 + 状态机 |
| `rawViewer/photoThumbnailService.swift` | 真正缩略图加载服务 |
| `rawViewer/photoDisplayService.swift` | Display 图加载服务 |

### 改造文件（8 个）

| 文件 | 改造内容 |
|------|---------|
| `rawViewer/mainWindowController.swift` | 数据逻辑移出，转交 coordinator |
| `rawViewer/groupGridViewController.swift` | `NSGridView` → `NSCollectionView` |
| `rawViewer/groupGridViewModel.swift` | `columnCount` 扣除滚动条宽度 |
| `rawViewer/photoThumbnailView.swift` | `NSStackView` → `NSTableView` |
| `rawViewer/photoBrowserViewController.swift` | 嵌入 `photoMetalViewController`，`loadCurrentPhoto` 调用 `reset()` |
| `rawViewer/duplicateCompareViewController.swift` | 嵌入 `photoMetalViewController` |
| `rawViewer/duplicateCompareViewModel.swift` | `markFinalKept` 清空 `reviewGroupId` |
| `rawViewer/photoImageService.swift` | 拆分为 Facade，内部分发 |
| `rawViewer/photoModels.swift` | `makeVisiblePhotoGroups` 过滤空 `reviewGroupId` |
| `rawViewer/jsonReviewStateStore.swift` | 新增 `clearReviewGroupId(photoId:)` |
| `rawViewer/metalPhotoView.swift` | 删除兼容方法，简化 draw |

### 删除内容

- `metalPhotoView.swift` 中的 `loadPhoto(url:source:)`、`loadJpgCompat`、`loadRawCompat`、`jpgFallbackUrl`

---

## 9. 实施顺序

考虑到模块依赖关系，按以下顺序实施：

1. **底层服务**：`photoThumbnailService` + `photoDisplayService` + `photoImageService` Facade 改造
2. **Metal 视图**：`photoMetalViewController` 新建，`metalPhotoView` 简化
3. **缩略图列表**：`photoThumbnailCellView` + `photoThumbnailView` NSTableView 重写
4. **网格**：`groupCollectionViewItem` + `groupGridViewController` NSCollectionView 重写
5. **数据层**：`appCoordinator` 新建，`mainWindowController` 改造，`jsonReviewStateStore` 新增方法
6. **Duplicate 闭环**：`duplicateCompareViewModel` + `photoModels` 改造
7. **浏览器集成**：`photoBrowserViewController` + `duplicateCompareViewController` 嵌入新 Metal VC
8. **测试**：更新现有测试，新增 coordinator 和 metal VC 测试

---

## 10. 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| NSCollectionView 纯代码写法在 macOS 下行为异常 | 中 | 高 | 参考 AppKit 官方示例，先在独立 test app 验证 layout |
| `CGImageSourceCreateThumbnailAtIndex` 对某些 RAW 导出的 JPG 降采样效果差 | 低 | 中 | fallback 到完整图加载 + `NSImage.draw(in:)` 缩放 |
| 改造后测试覆盖率不足，引入回归 bug | 中 | 高 | 每个改造模块配套单元测试；保留旧文件备份到 git history |
| `appCoordinator` 引入新的 retain cycle | 中 | 高 | 所有闭包使用 `[weak self]`，用 Instruments 验证 |

---

## 11. Spec Self-Review

- [x] **Placeholder scan**：无 TBD、TODO、不完整段落
- [x] **Internal consistency**：架构图与组件描述一致；数据流与接口定义一致
- [x] **Scope check**：本方案覆盖全部 Top Level + 4 个 BUG，不引入新功能（如批量导出、快捷键自定义）
- [x] **Ambiguity check**：
  - "真正缩略图" 明确指 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`
  - "清空 reviewGroupId" 明确指 JSON 中写入空字符串
  - "扣除滚动条宽度" 明确指 `NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)`

---

**下一步**：等待用户 review 本 spec。如有修改意见，在此文件上迭代更新。
