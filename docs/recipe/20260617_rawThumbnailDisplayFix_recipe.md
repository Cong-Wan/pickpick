# RAW-heavy 分组缩略图与图片显示修复方案

**日期：** 2026-06-17  
**范围：** 修复分组界面缩略图不显示、进入 RAW-heavy/RAW-only 分组后图片不显示或极慢的问题。  
**推荐方案：** 修正缩略图源选择 + RAW 缩略图限流 + RAW 内嵌预览优先。

---

## 1. 背景与问题

当前分析结果中，RAW-only 照片会被写成：

```text
jpgPath = xxx.RW2
rawPath = xxx.RW2
```

而 `photoThumbnailService` 当前直接使用 `photo.jpgPath` 作为缩略图源。结果是：

- JPG 照片：缩略图加载正常；
- RAW-only 照片：缩略图服务实际在解码 RAW；
- 分组页每个可见 group card 最多启动 5 个缩略图任务，RAW-heavy 数据集会同时触发大量 RAW 解码；
- RAW 缩略图解码在 app 中表现为卡住或极慢，导致分组页看不到缩略图；
- 进入 RAW-only 分组后，大图显示也只能走 RAW 解码，容易被后台 RAW 缩略图任务拖慢，表现为空白或长时间不显示。

问题共同病灶是：**缩略图加载没有区分真实 JPG 与 RAW，且 RAW 缩略图解码没有限流。**

---

## 2. 目标

1. 分组页 JPG 缩略图继续快速显示。
2. RAW-only / RAW-heavy 分组缩略图不再整体卡死，允许逐步显示。
3. 进入 RAW-only 分组后，大图显示不再被大量后台 RAW 缩略图任务明显拖住。
4. 保持改动集中，不引入持久化缩略图缓存、不改分析结果 schema。
5. 构建通过，并消除当前 `photoThumbnailService.swift` 中 debug log 引入的 MainActor warning。

---

## 3. 非目标

本次不做以下事情：

- 不生成磁盘持久化 JPEG proxy；
- 不迁移已有 `analysis.json`；
- 不重写大图显示链路；
- 不扩大支持格式；
- 不做无关 UI 重构。

---

## 4. 方案选择

### 方案 A：修正缩略图源选择 + RAW 限流（推荐）

做法：

- `photoThumbnailService` 不再盲用 `photo.jpgPath`；
- 优先使用真实 JPG；
- 无真实 JPG 但有 RAW 时使用 RAW；
- RAW 缩略图使用内嵌预览优先；
- RAW 缩略图解码限制并发。

优点：改动集中、风险低、能保留 RAW-only 真实缩略图。  
缺点：RAW-only 首次缩略图仍比 JPG 慢，但不会把界面整体拖死。

### 方案 B：RAW-only 只显示占位

做法：缩略图服务只加载真实 JPG，RAW-only 直接返回 nil，由 UI 显示灰色占位。

优点：最快、最稳。  
缺点：RAW-only 分组仍没有真实预览，体验差。

### 方案 C：生成持久化 JPEG proxy

做法：分析 RAW 时生成小图缓存，UI 永远读 proxy。

优点：长期体验最好。  
缺点：涉及缓存目录、失效策略、清理策略和 schema/版本兼容，超出本次修复范围。

**结论：采用方案 A。**

---

## 5. 方案 A 详细设计

方案 A 只改缩略图服务的内部行为，对外 API 不变。调用方仍然调用：

```swift
await imageService.loadThumbnail(for: photo, maxWidth: maxWidth, maxHeight: maxHeight)
```

`photoImageService` 继续把请求转发给 `photoThumbnailService`。UI 层不需要知道缩略图来自 JPG 还是 RAW。

### 5.1 缩略图源选择：不要再盲用 `photo.jpgPath`

在 `photoThumbnailService` 内部增加私有源类型：

```swift
private enum thumbnailSource {
    case jpg(path: String)
    case raw(path: String)
}
```

新增私有方法：

```swift
private func thumbnailSource(for photo: photoItem) -> thumbnailSource?
```

选择顺序必须固定：

1. 如果 `photo.hasExistingJpgFile(fileManager: fileManager)` 为 true：返回 `.jpg(path: photo.jpgPath)`；
2. 否则，如果 `photo.hasExistingRawFile(fileManager: fileManager)` 为 true，且 `photo.rawPath` 非空：返回 `.raw(path: rawPath)`；
3. 否则返回 nil。

这个顺序的目的：

- JPG+RAW 配对照片优先用 JPG 做缩略图，因为最快；
- RAW-only 照片才走 RAW 缩略图；
- RAW-only 记录中的 `jpgPath = xxx.RW2` 不再被当成 JPG 路径使用。

`loadThumbnail` 的入口流程应变为：

```swift
public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
    let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
    if let cached = cache.object(forKey: cacheKey) { return cached }

    guard let source = thumbnailSource(for: photo) else { return nil }
    let maxPixelSize = max(maxWidth, maxHeight)

    // 后续根据 source 分 JPG / RAW 解码
}
```

### 5.2 解码函数拆分：源选择与实际解码分开

把当前 `decodeThumbnail(path:maxPixelSize:)` 调整为更明确的内部结构：

```swift
private func decodeThumbnail(source: thumbnailSource, maxPixelSize: Int) -> NSImage?
private func decodeImageSourceThumbnail(path: String, source: thumbnailSource, maxPixelSize: Int) -> NSImage?
```

职责划分：

- `decodeThumbnail(source:maxPixelSize:)`：负责判断 JPG/RAW，并决定是否走 RAW 限流；
- `decodeImageSourceThumbnail(path:source:maxPixelSize:)`：只负责 FileManager 检查、`CGImageSourceCreateWithURL`、`CGImageSourceCreateThumbnailAtIndex` 和 `NSImage` 包装。

这样可以避免把“选择源”“限制并发”“ImageIO 解码”揉在一个函数里。

### 5.3 JPG 解码策略：保持当前快速路径

JPG 分支保持现有行为：

```swift
let options: [CFString: Any] = [
    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceShouldCacheImmediately: true
]
```

原因：JPG 解码快，且当前 JPG 缩略图已经能正常显示，不应为了 RAW 问题改动 JPG 行为。

### 5.4 RAW 解码策略：内嵌预览优先

RAW 分支不能继续强制完整 RAW 创建缩略图。RAW 分支应使用：

```swift
let options: [CFString: Any] = [
    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
    kCGImageSourceShouldCacheImmediately: true
]
```

含义：

- 如果 RAW 文件内有预览图，优先使用内嵌预览；
- 如果没有内嵌预览，ImageIO 才尝试创建缩略图；
- 即使需要创建，也会被 RAW 限流保护。

不要在 RAW 分支使用：

```swift
kCGImageSourceCreateThumbnailFromImageAlways: true
```

因为它可能触发完整 RAW demosaic。当前问题就是分组页批量触发 RAW 解码后，缩略图任务卡住或极慢。

### 5.5 RAW 限流：串行执行 RAW 缩略图解码

在 `photoThumbnailService` 中新增一个私有串行队列：

```swift
private let rawDecodeQueue = DispatchQueue(label: "rawViewer.thumbnail.rawDecode")
```

RAW 分支必须通过该队列执行：

```swift
private func decodeThumbnail(source: thumbnailSource, maxPixelSize: Int) -> NSImage? {
    switch source {
    case .jpg:
        return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
    case .raw:
        return rawDecodeQueue.sync {
            guard !Task.isCancelled else { return nil }
            return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
        }
    }
}
```

实际代码可用 computed property 或 switch 取出 path，不要求照抄伪代码。

限流规则：

- JPG 不进入 `rawDecodeQueue`，继续并行；
- RAW 全部进入 `rawDecodeQueue`，同一时间最多 1 个 RAW 缩略图解码；
- 每个缩略图请求仍在 `Task.detached` 中执行，避免阻塞 MainActor；
- 解码前后都保留取消检查，防止复用 cell 或返回上级页面后继续把结果写回 UI。

这样做的取舍：

- 会让 RAW 缩略图逐个出现，而不是同时出现；
- 但能避免 RAW-heavy 分组页同时启动几十个 RAW 解码任务，把大图显示和 UI 响应一起拖慢。

### 5.6 缓存策略

当前缓存 key 可以继续使用：

```text
photoId|thumb|WIDTHxHEIGHT
```

不把 JPG/RAW 类型加入 key。理由：

- 当前 UI 只有“这张照片的一张缩略图”这个语义；
- 源选择是内部实现细节；
- 分析结果在一次 app 会话内不会动态从 RAW-only 变成 JPG+RAW；
- 保持 key 不变能减少无关改动。

只缓存成功的 `NSImage`。如果源不存在或解码失败，返回 nil，不缓存失败结果，避免临时文件访问问题被永久记住。

### 5.7 `loadThumbnail` 完整控制流

期望的最终控制流如下：

```text
loadThumbnail(photo, maxWidth, maxHeight)
  ├─ 计算 cacheKey
  ├─ 命中 cache → 返回 cached image
  ├─ 选择 thumbnailSource
  │    ├─ 真实 JPG 存在 → .jpg(path)
  │    ├─ RAW 存在 → .raw(path)
  │    └─ 都不可用 → nil
  ├─ 无 source → 返回 nil
  ├─ Task.detached
  │    ├─ cancelled → nil
  │    ├─ JPG → 直接 ImageIO 降采样
  │    ├─ RAW → rawDecodeQueue 串行 ImageIO 降采样
  │    ├─ cancelled → nil
  │    ├─ 成功 → 写入 cache
  │    └─ 返回 image / nil
  └─ withTaskCancellationHandler 取消 detached task
```

这个流程保留现有 API 和取消模型，只改变源选择、RAW options 和 RAW 并发。

### 5.8 大图显示保持不变

`photoDisplayService` 现有 JPG/RAW 分离保持不变：

- JPG 只接受 `.jpg/.jpeg`；
- RAW 只接受 `.rw2/.cr2`；
- 浏览页已能在 JPG 不可用时切到 RAW。

本次不直接改大图链路。进入分组后大图变正常的主要原因应是：分组页不再并发堆积大量 RAW 缩略图解码任务，CoreImage/Metal 显示 RAW 时不会被同类后台任务抢占。

### 5.9 日志与并发 warning

当前 `photoThumbnailService.swift` 中临时 debug log 从非 MainActor 上下文调用，构建出现 MainActor warning。实现时必须处理：

- 删除本次排查加入的临时 `appDebugLogger.log`；
- 或只在安全上下文记录必要日志；
- 最终构建不能再出现 `photoThumbnailService.swift` 的 MainActor warning。

本次推荐删除诊断性临时日志。保留的失败行为用返回 nil 表示，UI 继续显示现有占位。

### 5.10 不修改的内容

方案 A 明确不改以下内容：

- 不改 `photoAnalysisService` 写出的 `jpgPath` 兼容逻辑；
- 不迁移已有 `analysis.json`；
- 不改 `groupCardView` 的加载数量；
- 不改 `photoThumbnailCellView` 的 UI 占位逻辑；
- 不改 `photoDisplayService` 的 JPG/RAW 可用性判断。

原因：当前最小病灶在缩略图服务内部。把修复限制在服务层，可以同时覆盖分组卡片缩略图和浏览器左侧缩略图，并避免 UI 层散落判断。

---

## 6. 修改文件

预计只修改：

- `rawViewer/services/photoThumbnailService.swift`

如实现过程中发现需要微调 facade，可最小修改：

- `rawViewer/services/photoImageService.swift`

不计划修改：

- `photoAnalysisService.swift`
- `photoDisplayService.swift`
- group/grid/browser UI 文件
- analysis schema 或已有缓存文件

---

## 7. 验证计划

### 7.1 构建验证

执行：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build
```

通过标准：

- build succeeded；
- 不出现 `photoThumbnailService.swift` 的 MainActor debug log warning。

### 7.2 手动验证

使用当前样本：

```text
/Users/wilbur/Downloads/test_bak2
```

检查：

1. 分组页可显示 group card；
2. JPG-heavy 分组缩略图快速显示；
3. RAW-heavy 分组缩略图不再整体卡死，能逐步显示；
4. 进入 RAW-only 或 RAW-heavy 普通分组后，主图能显示；
5. 快速返回分组页、进入其他分组，不出现明显卡死。

### 7.3 回归验证

检查：

- JPG-only 文件夹缩略图仍正常；
- RAW-only 文件夹不会把 JPG segment 误判为可用；
- 删除、返回分组、重复组入口不受影响。

---

## 8. 风险与应对

### 风险 1：部分 RAW 没有可用内嵌预览

应对：`IfAbsent` 会在无内嵌预览时创建缩略图，但受 RAW 限流保护，不会拖垮分组页。

### 风险 2：RAW 首次缩略图仍慢

应对：本次目标是避免卡死与空白，不承诺 RAW 缩略图与 JPG 同速。长期可用持久化 JPEG proxy 优化。

### 风险 3：缓存 key 没包含源类型

应对：当前同一 `photoId` 只有一个缩略图语义。若未来支持动态选择 JPG/RAW 缩略图，再扩展 key。

---

## 9. 成功标准

本修复完成后应满足：

- 分组界面不再因为 RAW-heavy 数据集长期无缩略图；
- 进入 RAW-only/RAW-heavy 普通分组后，主图能正常显示或明显更快显示；
- 构建通过；
- 没有新增无关重构；
- 修改行能直接追溯到本问题。

---

## 10. 规范自我复审

- 占位符检查：无 TODO、无未完成章节。
- 一致性检查：目标、设计和验证均围绕 `photoThumbnailService` 的源选择与 RAW 限流展开，不要求 schema 迁移。
- 范围检查：集中于单个修复计划，未包含持久化 proxy 等长期方案实现。
- 歧义检查：明确采用方案 A；RAW 并发限制建议为最多 1 个；大图显示链路保持不变。
