## 代码审核报告 — rawViewer 深层次审查

### 总览

- 审核范围：`rawViewer/` 下 Swift / ObjC++ / Metal / YAML 业务源码，约 6.5k 行；另抽查 `rawViewer.xcodeproj/project.pbxproj` 构建配置。
- 未纳入范围：`3rdPart/` 第三方库源码、`.build/` 与 `build/` 构建产物。
- 验证命令：`xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build`
- 验证结果：Debug 构建通过。
- 发现问题：🔴 1 个 / 🟠 6 个 / 🟡 7 个 / 🔵 4 个
- 整体评价：项目主干架构已经比较清晰，AppKit 路由、分析流水线、JSON 状态落盘、Metal 显示和 RAW/JPG 分析模块拆分合理。但当前仍有几处“状态先改内存再落盘”“缓存 key 不唯一”“RAW Bayer 假设过强”“空列表后 UI 不回退”等问题，容易在真实照片库、重复组处理和异常 IO 场景下造成错误显示、状态不一致或分析误判。

---

### 审查上下文与当前状态

1. 当前工作区在审查前已有多处未提交修改，以及 `docs/codeReview/240626_window_size_restore*.md` 的删除状态；本报告未改动业务代码，只新增本文件。
2. 构建通过只能证明语法、链接和资源编译可用，不代表运行期状态流完全正确；下面问题主要来自源码路径推演。
3. 当前 app 的核心数据源为 `analysisStore` 里的 `analysis.json`，UI 页面通过 `appCoordinator.records/groups`、各 ViewModel 内存列表，以及 `jsonReviewStateStore` 共同维护状态，因此“落盘失败时内存是否已变更”是本次审查的重点。

---

### 问题清单

### 🔴 Critical — `keepBoth` 先修改内存再落盘，落盘失败会造成 UI/磁盘状态分裂

**位置**：`rawViewer/duplicate/duplicateCompareViewModel.swift:109-151`

**问题**：

`keepBoth(templatePhotoId:)` 在调用 `store.update` 之前先执行：

```swift
photos.removeAll { keptIds.contains($0.photoId) }
let remainingCount = photos.count
let remainingLast = photos.first

try store.update { items in
    ...
}
```

这与同文件 `keepLeft/keepRight` 里“先落盘、再改内存”的策略不一致。如果 `analysis.json` 解码/写入失败，方法会抛错，但 `photos` 已经移除了左右两张照片。控制器 catch 后只弹错误，不会恢复内存列表；继续操作时 UI 会基于已经被篡改的 `photos` 工作，而磁盘仍保留旧状态。后果包括：

- 重复组比较界面跳过本不该跳过的照片；
- 返回分组页重新读盘后照片“复活”，用户以为操作成功但实际未保存；
- 后续 `templatePhotoId` 计算基于已删内存，可能给错误剩余照片写模板。

**修复方案**：

把内存变更延后到 `store.update` 成功之后；需要用临时变量计算 remaining 状态，而不是直接改 `photos`。

```swift
public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
    let left = mainPhoto
    let right = candidatePhoto
    let originalGroupId = left?.reviewGroupId.isEmpty == false ? left?.reviewGroupId : right?.reviewGroupId
    let keptIds = Set([left, right].compactMap { $0?.photoId })
    let nextPhotos = photos.filter { !keptIds.contains($0.photoId) }
    let remainingCount = nextPhotos.count
    let remainingLast = nextPhotos.first

    try store.update { items in
        for index in items.indices where keptIds.contains(items[index].photoId) {
            items[index].reviewStatus = .kept
            items[index].reviewGroupId = ""
        }

        if remainingCount == 1, let last = remainingLast,
           let lastIndex = items.firstIndex(where: { $0.photoId == last.photoId }) {
            items[lastIndex].reviewStatus = .kept
            if !last.reviewGroupId.isEmpty {
                for index in items.indices where items[index].reviewGroupId == last.reviewGroupId {
                    items[index].templatePhotoId = last.photoId
                }
                items[lastIndex].reviewGroupId = ""
            }
        } else if remainingCount > 1, let groupId = originalGroupId, !groupId.isEmpty {
            for index in items.indices where items[index].reviewGroupId == groupId {
                items[index].templatePhotoId = templatePhotoId
            }
        }
    }

    photos = nextPhotos
    switch remainingCount {
    case 0, 1:
        return .finished
    default:
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
}
```

---

### 🟠 High — 图片缓存 key 只使用 `photoId`，跨文件夹/同名照片会显示错误图片

**位置**：

- `rawViewer/services/photoDisplayService.swift:28,58`
- `rawViewer/services/photoThumbnailService.swift:39`

**问题**：

显示图和缩略图缓存 key 均只依赖 `photo.photoId`：

```swift
let key = "\(photo.photoId)|displayJpg" as NSString
let key = "\(photo.photoId)|displayRaw" as NSString
let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
```

`photoId` 来自文件 stem，例如不同文件夹都可能有 `P1000001.JPG`。`appCoordinator` 持有一个长期存在的 `photoImageService`，用户从 A 文件夹回到开始页再打开 B 文件夹时，两个文件夹里的同名照片会命中同一个缓存 key。结果是 B 文件夹页面可能显示 A 文件夹的缩略图或大图。

**修复方案**：

缓存 key 至少加入稳定文件路径和修改时间/文件大小；更简单可先用路径。注意同一 `photoId` 的 JPG/RAW 也要分开。

```swift
private func displayKey(photo: photoItem, source: displaySource) -> NSString {
    let path = source == .jpg ? photo.jpgPath : (photo.rawPath ?? "")
    return "\(photo.photoId)|\(source.rawValue)|\(path)" as NSString
}

private func thumbnailKey(photo: photoItem, maxWidth: Int, maxHeight: Int) -> NSString {
    let path = photo.hasExistingJpgFile() ? photo.jpgPath : (photo.rawPath ?? "")
    return "\(photo.photoId)|thumb|\(path)|\(maxWidth)x\(maxHeight)" as NSString
}
```

更稳妥的做法是在 `photoItem` 中增加 `cacheIdentity`，由 path + fileSize + modificationDate 组成，避免同路径文件被替换后仍命中旧图。

---

### 🟠 High — 缓存存在性检查未校验配置快照，可能先走缓存路径再回退重分析，造成 UI 延迟与错误日志噪声

**位置**：

- `rawViewer/appCoordinator.swift:47-56`
- `rawViewer/services/analysisStore.swift:74-76`

**问题**：

`startAnalysis` 先用 `analysisStore.shared.hasResults(for:)` 判断是否存在缓存，再调用 `analyzer.loadRecordsAsync`。但 `hasResults` 只检查文件存在，不检查 `configSnapshot`：

```swift
if analysisStore.shared.hasResults(for: folderUrl) {
    do {
        let loadedRecords = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
        ...
    } catch {
        appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
    }
}
```

当配置变化时，`loadRecordsAsync` 会抛 `staleConfigSnapshot`，然后才重分析。功能上能恢复，但体验上会先进入“尝试缓存失败”的路径；如果旧缓存损坏，也会先做一次失败解码。这个问题在大文件 JSON 或频繁调阈值时会放大。

**修复方案**：

提供一个带配置校验的缓存探测方法，或者直接移除 `hasResults` 分支，用 `loadRecordsAsync` 的成功/失败作为唯一判断。更清晰的写法：

```swift
do {
    let loadedRecords = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
    self.records = loadedRecords
    self.trashService.cleanupTrashedPhotos(self.records)
    self.showGroups()
    return
} catch analysisStoreError.staleConfigSnapshot {
    appDebugLogger.log("analysis cache stale, reanalyzing")
} catch {
    appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
}
```

这样可以删除 `hasResults` 的语义歧义，缓存损坏/配置过期都由同一入口处理。

---

### 🟠 High — RAW Bayer 绿色通道提取硬编码 RGGB，非 RGGB 相机会分析错误

**位置**：

- `rawViewer/bridge/libRawBridge.h:10-22`
- `rawViewer/bridge/libRawBridge.mm:37-48`
- `rawViewer/services/rawBayerAnalyzer.swift:213-218`
- `rawViewer/metal/rawAnalysisShaders.metal:72-82`

**问题**：

Metal kernel 固定取 `(baseX + 1, baseY)` 和 `(baseX, baseY + 1)` 为绿色像素：

```metal
uint g1 = static_cast<uint>(rawBuffer[baseY * config.rawWidth + (baseX + 1u)]);
uint g2 = static_cast<uint>(rawBuffer[(baseY + 1u) * config.rawWidth + baseX]);
```

这等价于假设可见区域 Bayer pattern 一定是 RGGB，并且 `visibleOffsetX/Y` 对齐后仍满足该排列。实际相机可能是 BGGR / GBRG / GRBG，且 LibRaw 的 `filters`/`cdesc` 才能描述颜色排列。对非 RGGB RAW，绿色平面会取到红/蓝像素或错位像素，导致曝光直方图、Laplacian、动态范围全部偏离。

**修复方案**：

在 ObjC++ bridge 返回 Bayer pattern 或每个坐标的 color index；Swift 配置传入 Metal，由 kernel 根据 pattern 选择两个绿色位置。

示例方向：

```cpp
// libRawBridge.h
int filters;
char colorDesc[5];
```

```cpp
// libRawBridge.mm
data.filters = h->processor.imgdata.idata.filters;
memcpy(data.colorDesc, h->processor.imgdata.idata.cdesc, 4);
data.colorDesc[4] = '\0';
```

Swift/Metal 层不要再假设固定两点，而是按 LibRaw pattern 判断绿色像素；如果暂时不支持，应检测 pattern 并在不匹配时降级到 JPG fallback，而不是静默产生错误分析。

---

### 🟠 High — 大图/RAW 分析缺少尺寸乘法溢出与内存预算检查，极端文件可能 OOM 或崩溃

**位置**：

- `rawViewer/services/rawBayerAnalyzer.swift:126-148`
- `rawViewer/services/jpgAnalyzer.swift:55-74`
- `rawViewer/services/photoDisplayService.swift:80-118`

**问题**：

RAW 路径中直接计算：

```swift
let totalRaw = rawW * rawH
makeBuffer(length: totalRaw * MemoryLayout<UInt16>.size, ...)
```

JPG 分析仅检查 `totalPixels <= 100_000_000`，但随后分配 RGBA texture、grayBuffer、lapBuffer、hist/grid buffer；100MP 图像单张就可能超过数百 MB，加上 `metalConcurrency` 并发分析，很容易触发内存压力。`photoDisplayService.loadRaw` 仅按文件大小限制 1GB，没有限制解码后的像素尺寸。

Swift `Int` 在极端尺寸下也可能乘法溢出，虽然真实照片通常不会达到，但解析损坏 RAW/JPG 时不应假设尺寸可信。

**修复方案**：

集中增加安全乘法和像素预算；RAW/JPG/display 使用同一套上限。

```swift
private func checkedPixelCount(width: Int, height: Int, maxPixels: Int) throws -> Int {
    guard width > 0, height > 0 else { throw makeError("invalid dimensions") }
    guard width <= maxPixels / height else { throw makeError("dimension overflow") }
    let pixels = width * height
    guard pixels <= maxPixels else { throw makeError("image too large: \(width)x\(height)") }
    return pixels
}
```

同时建议按预算估算内存：

```swift
let estimatedBytes = pixels * (2 + 4 + 4) // raw/green/lap 仅示意
let maxBytesPerTask = 512 * 1024 * 1024
```

超过预算时降级 JPG fallback 或标记分析失败，而不是继续分配 GPU buffer。

---

### 🟠 High — 浏览器删除最后一批照片后不自动返回分组页，UI 留在空详情页

**位置**：`rawViewer/browser/photoBrowserViewController.swift:374-393`

**问题**：

`restoreNormalClicked` 在列表为空时会 `onBack?()`，但 `deleteClicked` 删除后只更新列表、设置 index 并 `loadCurrentPhoto()`：

```swift
try viewModel.confirmDelete()
thumbnailView.updatePhotos(viewModel.photos)
thumbnailView.setCurrentIndex(viewModel.currentIndex)
loadCurrentPhoto()
```

当删除的是当前组最后一张或选中了全组照片时，`viewModel.photos` 为空。`thumbnailView.setCurrentIndex(0)` 会因无有效 index 直接 return，`loadCurrentPhoto()` reset 后无当前照片，只打 debug log。用户会停留在一个空的浏览页，需要手动返回；这与 Restore Normal 行为不一致，也容易让用户误判删除是否完成。

**修复方案**：

删除后与 Restore Normal 统一：列表为空则回分组页。

```swift
try viewModel.confirmDelete()
thumbnailView.updatePhotos(viewModel.photos)
if viewModel.photos.isEmpty {
    onBack?()
} else {
    thumbnailView.setCurrentIndex(viewModel.currentIndex)
    loadCurrentPhoto()
}
```

---

### 🟠 High — `jsonReviewStateStore` 在没有 `folderUrl` 时静默成功，测试/运行期会掩盖持久化失败

**位置**：`rawViewer/models/jsonReviewStateStore.swift:106-116`

**问题**：

```swift
public func update(_ mutate: (inout [photoItem]) -> Void) throws {
    guard let folderUrl else { return }
    try analysisStore.shared.update(folderUrl: folderUrl) { items in
        mutate(&items)
    }
}
```

`folderUrl == nil` 时所有写操作都“成功返回”。这对 `required init?(coder:)` 或单元测试默认构造很方便，但在真实运行中如果某条路径忘记注入 `folderUrl`，用户的 keep/delete/rotate/restore 操作会只改内存或只追加 `operations`，不会写入 `analysis.json`，且控制器不会收到错误。

**修复方案**：

新增明确错误；测试用 mock store，不要让生产 store 静默吞写入。

```swift
public enum reviewStateStoreError: LocalizedError, Equatable {
    case missingFolderUrl
    ...

    public var errorDescription: String? {
        switch self {
        case .missingFolderUrl:
            return "Review state store was created without folderUrl"
        ...
        }
    }
}

public func update(_ mutate: (inout [photoItem]) -> Void) throws {
    guard let folderUrl else { throw reviewStateStoreError.missingFolderUrl }
    try analysisStore.shared.update(folderUrl: folderUrl) { items in
        mutate(&items)
    }
}
```

---

### 🟡 Medium — `analysisStore.update` 写回时传 `config: nil`，依赖旧文件存在才能保留 configSnapshot

**位置**：`rawViewer/services/analysisStore.swift:106-110,125-145`

**问题**：

`update` 先 `loadUnlocked`，再 `saveUnlocked(..., config: nil)`。`saveUnlocked` 会尝试读取旧文件并保留 `existing.configSnapshot`，所以正常情况下没问题。但这个设计有一个隐含前提：旧文件在 save 前仍存在且可解码。

如果未来增加“从内存首建 analysis.json 后立即写 review 状态”的路径，或旧 JSON 被外部损坏，`configSnapshot` 可能丢失/更新失败。更重要的是，`saveUnlocked` 在 `ioQueue.sync` 内重复读同一个 JSON，成本不必要。

**修复方案**：

让 `update` 一次性读出 root，修改 root.photos，再保存 root，避免二次读取和 `config:nil` 的隐式语义。

```swift
public func update(folderUrl: URL, mutate: (inout [photoItem]) throws -> Void) throws {
    try ioQueue.sync {
        var root = try loadFileUnlocked(for: folderUrl)
        try mutate(&root.photos)
        try saveFileUnlocked(folderUrl: folderUrl, root: root)
    }
}
```

---

### 🟡 Medium — JPG 分析渲染未标准化 CIImage origin，非零 extent origin 时可能采样偏移

**位置**：`rawViewer/services/jpgAnalyzer.swift:55-84`

**问题**：

`CIImage(contentsOf:)` 的 `extent.origin` 不一定总是 `.zero`。当前创建 texture 使用 `width/height`，但 render 时直接传 `bounds: ciImage.extent`：

```swift
let width = Int(ciImage.extent.width)
let height = Int(ciImage.extent.height)
ciContext.render(ciImage, to: texture, commandBuffer: cmd, bounds: ciImage.extent, colorSpace: colorSpace)
```

如果 origin 非零，渲染到从 `(0,0)` 开始的 texture 时可能出现偏移或裁剪风险。显示路径 `metalPhotoView` 已经显式考虑 `extent.minX/maxY`，分析路径也应做同样规范化。

**修复方案**：

在分析前把图像平移到零原点，并用零原点 bounds 渲染。

```swift
let extent = ciImage.extent.integral
let normalizedImage = ciImage.transformed(by: CGAffineTransform(
    translationX: -extent.minX,
    y: -extent.minY
))
let bounds = CGRect(origin: .zero, size: extent.size)
ciContext.render(normalizedImage, to: texture, commandBuffer: cmd, bounds: bounds, colorSpace: colorSpace)
```

---

### 🟡 Medium — 缩略图 cell 异步回调未校验 photoId，复用竞争下可能显示旧图

**位置**：`rawViewer/views/photoThumbnailCellView.swift:70-78`

**问题**：

回调只校验 `self.thumbImageView === targetView`：

```swift
guard let self = self, let targetView = targetView, self.thumbImageView === targetView else { return }
targetView.image = image
```

但 NSTableCellView 复用时 `thumbImageView` 是同一个对象。旧任务即使被 cancel，底层解码函数未必能立刻停下；旧任务完成后仍可能把旧照片缩略图写入已复用为新照片的 cell。

**修复方案**：

记录当前 `photoId`，回调时同时校验。

```swift
private var representedPhotoId: String?

public func configure(photo: photoItem, ...) {
    representedPhotoId = photo.photoId
    ...
    let expectedPhotoId = photo.photoId
    loadTask = Task { [weak self, weak targetView] in
        let image = await imageService.loadThumbnail(for: photo)
        if Task.isCancelled { return }
        await MainActor.run {
            guard let self,
                  self.representedPhotoId == expectedPhotoId,
                  let targetView,
                  self.thumbImageView === targetView else { return }
            targetView.image = image
        }
    }
}
```

`groupCardView` 的异步预览加载也有类似风险，应按 card/photoId 校验。

---

### 🟡 Medium — `groupCollectionViewItem.prepareForReuse` 未清理旧闭包与加载任务

**位置**：

- `rawViewer/views/groupCollectionViewItem.swift:37-39`
- `rawViewer/views/groupCardView.swift:30-44,134-137`

**问题**：

`groupCollectionViewItem.prepareForReuse()` 是空实现。虽然 `itemForRepresentedObjectAt` 会调用 `update` 并重新设置 `onTap`，但复用窗口内如果数据源变化或 item 短时间处于复用池，旧 `onTap` 闭包仍持有旧 group/self；`groupCardView` 也只有在 `configure` 时 cancel loads，prepareForReuse 阶段没有主动清理。

**修复方案**：

暴露 `resetForReuse()` 清空闭包、取消加载、移除旧预览。

```swift
public func resetForReuse() {
    onTap = nil
    cancelLoads()
    cardContainers.forEach { $0.removeFromSuperview() }
    cardContainers.removeAll()
    nameLabel.stringValue = ""
    countLabel.stringValue = ""
}

public override func prepareForReuse() {
    super.prepareForReuse()
    cardView?.resetForReuse()
}
```

---

### 🟡 Medium — 重复比较页 RAW/JPG segment 是“任意一侧可用”语义，可能左右显示不同来源而用户无提示

**位置**：`rawViewer/duplicate/duplicateCompareViewController.swift:252-265,267-300`

**问题**：

`canSelectRawForCurrentPair()` 只要左或右任意一侧有 RAW 就允许选择 RAW。随后 `show(pair:source:)` 如果某一侧 RAW 不可用，会 fallback 到 JPG。结果：segment 显示 RAW，但左图可能 RAW、右图可能 JPG；或反过来。重复比较本质上需要公平比较，左右来源不一致会影响用户判断锐度/曝光。

**修复方案**：

至少在 UI 上标识每侧实际来源；更严格则要求左右两侧都可用才允许 RAW/JPG segment。

```swift
private func canSelectRawForCurrentPair() -> Bool {
    let leftHasRaw = viewModel.mainPhoto?.hasExistingRawFile() == true
    let rightHasRaw = viewModel.candidatePhoto?.hasExistingRawFile() == true
    return leftHasRaw && rightHasRaw
}
```

如果业务允许 fallback，建议在文件名栏增加 `RAW fallback JPG` 提示，避免用户误判。

---

### 🟡 Medium — `as! groupCollectionViewItem` 是不必要的崩溃点

**位置**：`rawViewer/groupGrid/groupGridViewController.swift:160`

**问题**：

```swift
let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! groupCollectionViewItem
```

当前注册逻辑正确，所以正常不会崩。但这是 UI 层常见脆弱点：identifier 改名、注册遗漏、Storyboard/Nib 介入都会直接 crash。这里没有必要用强制转换。

**修复方案**：

```swift
guard let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as? groupCollectionViewItem else {
    appFileLogger.log("failed to dequeue groupCollectionViewItem", level: .error)
    return NSCollectionViewItem()
}
```

---

### 🟡 Medium — `mainWindowController.screenState` 与 `appCoordinator.screenState` 是两份状态，容易读到旧值

**位置**：

- `rawViewer/mainWindowController.swift:17-18`
- `rawViewer/appCoordinator.swift:21-23`

**问题**：

`mainWindowController` 和 `appCoordinator` 各自维护 `screenState`。实际路由全部由 coordinator 更新，`mainWindowController.screenState` 初始化后基本不会同步。后续若测试或菜单逻辑读取 `mainWindowController.screenState`，会得到 `.start` 而非真实页面。

**修复方案**：

删除 `mainWindowController.screenState`，或把它改成转发属性：

```swift
public var screenState: windowScreenState {
    coordinator?.screenState ?? .start
}
```

---

### 🟡 Medium — RAW 分析错误信息丢失，LibRaw open/unpack 失败不可诊断

**位置**：`rawViewer/bridge/libRawBridge.mm:17-33` 与 `rawViewer/services/rawBayerAnalyzer.swift:105-111`

**问题**：

`rwRawOpen` 失败时直接 `delete h; return nullptr;`，Swift 只能得到：

```swift
throw makeError("LibRaw open_file returned null for \(rawPath)")
```

`lastError` 字段从未写入，`rwRawLastError(handle)` 只能在 handle 非空时读取，因此 open/unpack 的 LibRaw 错误码、错误字符串都丢失。真实用户文件损坏或格式不支持时，日志无法定位。

**修复方案**：

提供 `rwRawOpenWithError` 或全局/输出参数错误缓冲。示例：

```cpp
void* rwRawOpen(const char* path, char* errorBuffer, int errorBufferSize) {
    ...
    if (ret != LIBRAW_SUCCESS) {
        snprintf(errorBuffer, errorBufferSize, "%s", libraw_strerror(ret));
        delete h;
        return nullptr;
    }
}
```

Swift 侧把错误写入 `analysisSource` debug log 或 fallback 原因。

---

### 🔵 Low — `visibleGroupCards` 与 `makeVisiblePhotoGroups` 对 Normal 空组语义重复，建议集中

**位置**：

- `rawViewer/models/photoModels.swift:257-293`
- `rawViewer/groupGrid/groupGridViewController.swift:10-23`
- `rawViewer/groupGrid/groupGridViewModel.swift:26-27`

**问题**：

`makeVisiblePhotoGroups` 总是 append Normal 组，即使为空；`visibleGroupCards` 又再次保留 Normal、过滤其它空组，并把 Normal 排到前面。这种规则分散在 model 和 controller 文件里，后续改“是否显示空 Normal”容易漏改。

**修复方案**：

把排序/过滤语义放回 ViewModel 或 Model 层一个函数，例如：

```swift
public func makeDisplayPhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    visibleGroupCards(from: makeVisiblePhotoGroups(from: photos))
}
```

控制器不再持有业务过滤逻辑。

---

### 🔵 Low — `runModal()` 同步弹窗分散在多个控制器，阻塞主线程且不利于测试

**位置**：

- `rawViewer/browser/photoBrowserViewController.swift:301-307,385`
- `rawViewer/duplicate/duplicateCompareViewController.swift:328-334,419`
- `rawViewer/views/startViewController.swift:135`

**问题**：

AppKit `runModal()` 可用，但它会进入嵌套事件循环，分散在控制器中也让测试较难。当前项目还没有系统测试，所以不是立即 bug；但随着操作增多，会影响可维护性。

**修复方案**：

封装 alert 服务或使用 sheet：

```swift
alert.beginSheetModal(for: view.window!) { response in
    if response == .alertFirstButtonReturn { ... }
}
```

删除/保留类操作尤其适合 sheet，避免主线程同步阻塞。

---

### 🔵 Low — 文件头版本与修改日期更新不一致风险较高

**位置**：多个文件头，如 `photoBrowserViewController.swift` 日期仍为 `2026-06-16`，但文件已有 6/25 相关行为改动。

**问题**：

项目要求每次修改更新文件头版本和 description。当前多数近期文件已经更新，但仍有部分文件头日期/描述与实际行为不完全匹配。它不会影响运行，但会降低审计可信度。

**修复方案**：

后续每个业务变更都同步更新文件头；可以在提交前加一个轻量检查脚本，提示当天改动文件的 `Date:` 是否匹配。

---

### 🔵 Low — Debug 构建通过，但缺少自动化测试靶标

**位置**：`rawViewer.xcodeproj/project.pbxproj`

**问题**：

本次只能跑 `xcodebuild build`，没有可执行的单元测试/集成测试。当前项目里很多逻辑非常适合测试：

- `makeVisiblePhotoGroups`
- `duplicateCompareViewModel.keepLeft/keepRight/keepBoth`
- `photoBrowserViewModel.confirmDelete/rotate/restoreNormal`
- `configLoader.parse`
- `analysisScoring` 特征与分类器

缺少测试会让后续修复 Critical/High 问题时更容易引入回归。

**修复方案**：

新增 Xcode Unit Test target，优先覆盖纯 Swift ViewModel/Model/Config/Scoring。测试 store 使用 mock `jsonReviewStateStoring`，不要依赖真实磁盘。

---

### 优点记录

1. **架构拆分清晰**：`appCoordinator` 负责路由，ViewModel 负责操作状态，Service 负责分析/图片/垃圾桶，职责边界总体明确。
2. **状态先落盘再删文件的方向正确**：`keepLeft/keepRight` 与 `confirmDelete` 已经采用“先 JSON 状态，再尽力 trash 文件”的策略，能避免幽灵照片；Critical 问题主要是 `keepBoth` 尚未统一该策略。
3. **异步加载防陈旧结果已有意识**：浏览器用 `currentRequestId` 防止快速切换照片后旧图覆盖新图，这是正确方向。
4. **配置快照机制有价值**：`analysisConfig` 进入 `analysis.json`，配置变化触发重分析，避免旧算法缓存混用。
5. **Metal 显示层处理了 drawable 未就绪与 offscreen 渲染**：`viewDidAppear` 延后加载、offscreen texture 再 blit 到 drawable，比直接渲染 drawable 更稳。

---

### 修复优先级建议

1. **先修 `keepBoth` 内存/磁盘分裂（Critical）**：这是确定性状态一致性 bug，修复范围小，收益最大。
2. **再修缓存 key 加路径/文件签名（High）**：跨文件夹同名照片非常常见，错误显示会直接破坏用户信任。
3. **随后修 RAW Bayer pattern 与尺寸/内存保护（High）**：这两项影响分析正确性与稳定性；尤其 RAW 支持目标明确时，不能长期假设 RGGB。
4. **顺手修浏览器删除空列表回退、`jsonReviewStateStore` missing folder 抛错**：这两项都是小改动，但能消除明显 UX 和持久化隐患。
5. **补单元测试 target**：建议在修复第 1、4 项时同时补 ViewModel 测试，防止重复组流程回归。
