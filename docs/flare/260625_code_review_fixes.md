# codeReviewFixes 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复 `docs/codeReview/260625_deep_code_review.md` 中经核验属实的状态一致性、缓存串图、RAW/JPG 分析健壮性、UI 复用与若干崩溃点问题。

**架构：** 优先修复会造成状态分裂和错误图片显示的核心路径，再补齐分析输入安全边界，最后处理 UI 复用和低风险结构清理。所有改动遵循现有 AppKit + ViewModel + Service 分层，不引入新测试框架，不做无关重构。

**技术栈：** Swift / AppKit / CoreImage / Metal / ObjC++ LibRaw bridge / Xcode Debug build。

---

## 已核验结论

`docs/codeReview/260625_deep_code_review.md` 中列出的核心问题基本属实。计划覆盖以下问题：

- `duplicateCompareViewModel.keepBoth` 先改内存再落盘。
- 图片缓存 key 只依赖 `photoId`。
- 缓存存在性探测不校验 `configSnapshot`。
- RAW Bayer 分析硬编码 RGGB，且 LibRaw open/unpack 错误不可诊断。
- RAW/JPG/display 缺少统一尺寸、乘法溢出和内存预算保护。
- 浏览器删除最后一批照片后停留空页。
- `jsonReviewStateStore` 缺失 `folderUrl` 时静默成功。
- `analysisStore.update` 依赖旧文件二次读取保留 `configSnapshot`。
- JPG 分析未标准化 `CIImage.extent.origin`。
- 缩略图与分组卡片异步回调存在复用陈旧写入风险。
- Duplicate 比较页 source segment 允许左右来源不一致。
- `as! groupCollectionViewItem`、双 `screenState` 等脆弱点。

## 不纳入本轮修复

- 不新增 Xcode Unit Test target：本计划按 flare 约束不安排任何测试框架或测试文件。
- 不统一替换所有 `runModal()`：这是可维护性改进，不影响当前 Critical/High 修复目标。
- 不批量修全部历史文件头：只更新本轮实际修改文件的文件头。
- 不编排任何 Git 操作。
- 不新增命令行打印输出；只沿用现有 `appDebugLogger` / `appFileLogger` 的关键节点日志。

## 文件结构

将修改这些文件：

- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 修复 `keepBoth` 的内存/磁盘一致性。
- `rawViewer/browser/photoBrowserViewController.swift` — 删除后空列表自动返回分组页。
- `rawViewer/models/jsonReviewStateStore.swift` — 缺失 `folderUrl` 时显式抛错。
- `rawViewer/services/analysisStore.swift` — `update` 以完整 root 文件为单位读写，保留 `configSnapshot` 不依赖二次读旧文件；缺失缓存文件时显式抛 `missingResults`。
- `rawViewer/services/photoDisplayService.swift` — display 缓存 key 加入路径和文件签名，并补 display 尺寸与单边维度保护。
- `rawViewer/services/photoThumbnailService.swift` — thumbnail 缓存 key 加入来源路径和文件签名。
- `rawViewer/appCoordinator.swift` — 取消 `hasResults` 预探测，直接尝试带配置校验的异步加载。
- `rawViewer/services/rawBayerAnalyzer.swift` — RAW 尺寸保护、Bayer pattern 参数传入 Metal、LibRaw 错误信息读取。
- `rawViewer/services/jpgAnalyzer.swift` — JPG 尺寸保护、零原点渲染。
- `rawViewer/bridge/libRawBridge.h` — bridge 结构增加 Bayer pattern 字段和 open 错误输出函数。
- `rawViewer/bridge/libRawBridge.mm` — 填充 Bayer pattern 字段和 LibRaw 错误信息。
- `rawViewer/metal/rawAnalysisShaders.metal` — RAW histogram 与 green plane 不再假设 RGGB。
- `rawViewer/views/photoThumbnailCellView.swift` — cell 复用时校验 `photoId`。
- `rawViewer/views/groupCardView.swift` — 卡片复用时取消任务、清理闭包和防陈旧回调。
- `rawViewer/views/groupCollectionViewItem.swift` — `prepareForReuse` 调用卡片清理。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — source segment 要求左右两侧均可用，避免 RAW/JPG 混比。
- `rawViewer/groupGrid/groupGridViewController.swift` — 去掉强制转换崩溃点。
- `rawViewer/mainWindowController.swift` — `screenState` 转发到 coordinator，避免两份状态。

---

### Task 1: 修复 review 状态一致性与空列表返回

**目标：** 保证重复组 keepBoth、浏览器删除、review store 写入都满足“落盘失败不篡改内存，缺失持久化上下文必须暴露错误，列表清空后 UI 自动回到分组页”。

**涉及的文件：**

- `rawViewer/duplicate/duplicateCompareViewModel.swift` — `keepBoth` 先构造临时结果，落盘成功后再更新 `photos`。
- `rawViewer/browser/photoBrowserViewController.swift` — 删除后列表为空时调用 `onBack?()`。
- `rawViewer/models/jsonReviewStateStore.swift` — `folderUrl == nil` 时抛 `missingFolderUrl`。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/duplicate/duplicateCompareViewModel.swift` 文件头：版本 `1.8`，日期 `2026-06-25`，Description 追加“v1.8 keepBoth 改为先落盘后更新内存，避免落盘失败导致 UI/磁盘状态分裂”。
- [ ] 将 `keepBoth(templatePhotoId:)` 完整替换为：

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

- [ ] 更新 `rawViewer/browser/photoBrowserViewController.swift` 文件头：版本 `3.7`，日期 `2026-06-25`，Description 追加“v3.7 删除操作清空当前列表后自动返回分组页”。
- [ ] 将 `deleteClicked()` 中确认删除后的成功分支替换为：

```swift
            do {
                try viewModel.confirmDelete()
                thumbnailView.updatePhotos(viewModel.photos)
                thumbnailView.setCheckedIds(viewModel.checkedPhotoIds)
                if viewModel.photos.isEmpty {
                    onBack?()
                } else {
                    thumbnailView.setCurrentIndex(viewModel.currentIndex)
                    loadCurrentPhoto()
                }
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
```

- [ ] 更新 `rawViewer/models/jsonReviewStateStore.swift` 文件头：版本 `1.8`，日期 `2026-06-25`，Description 追加“v1.8 缺失 folderUrl 时写操作显式抛错”。
- [ ] 将 `reviewStateStoreError` 完整替换为：

```swift
public enum reviewStateStoreError: LocalizedError, Equatable {
    case emptyPhotoIds
    case missingPhotoIds([String])
    case missingFolderUrl

    public var errorDescription: String? {
        switch self {
        case .emptyPhotoIds:
            return "No photo ids were provided"
        case .missingPhotoIds(let ids):
            return "Photo ids were not found in analysis store: \(ids.joined(separator: ","))"
        case .missingFolderUrl:
            return "Review state store was created without folderUrl"
        }
    }
}
```

- [ ] 将 `update(_:)` 和 `updateThrowing(_:)` 完整替换为：

```swift
    public func update(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { throw reviewStateStoreError.missingFolderUrl }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            mutate(&items)
        }
    }

    private func updateThrowing(_ mutate: (inout [photoItem]) throws -> Void) throws {
        guard let folderUrl else { throw reviewStateStoreError.missingFolderUrl }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            try mutate(&items)
        }
    }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过，无 Swift 编译错误。

手动验证：

1. 打开一个包含重复组的文件夹，对重复比较页点击 `Keep both`，操作成功后继续比较或返回分组页。
2. 在浏览器页勾选当前组全部照片并删除，确认后页面返回分组页，不停留在空详情页。
3. 若人为构造缺失 `folderUrl` 的 store 并触发写操作，界面弹出 `Review state store was created without folderUrl`，不静默成功。

✅ **完成的标志：** 构建通过；`keepBoth` 不再在 `store.update` 前改动 `photos`；删除清空列表后自动返回分组页。

------

### Task 2: 修复 analysisStore 更新语义与缓存探测路径

**目标：** `analysisStore.update` 保留 `configSnapshot` 不再依赖保存时二次读取旧文件；缺失缓存、过期缓存、损坏缓存分别走清晰日志路径后重分析。

**涉及的文件：**

- `rawViewer/services/analysisStore.swift` — root 级读写。
- `rawViewer/appCoordinator.swift` — 删除 `hasResults` 分支。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/services/analysisStore.swift` 文件头：版本 `1.5`，日期 `2026-06-25`，Description 追加“v1.5 update 改为读取完整 analysisFile 后原样保留 configSnapshot 写回，缺失缓存文件显式抛 missingResults”。
- [ ] 将 `analysisStoreError` 完整替换为：

```swift
public enum analysisStoreError: Error, LocalizedError, Equatable {
    case missingResults
    case staleConfigSnapshot

    public var errorDescription: String? {
        switch self {
        case .missingResults:
            return "analysis cache file does not exist"
        case .staleConfigSnapshot:
            return "analysis cache configSnapshot differs from current config"
        }
    }
}
```

- [ ] 将 `update(folderUrl:mutate:)` 替换为：

```swift
    public func update(folderUrl: URL, mutate: (inout [photoItem]) throws -> Void) throws {
        try ioQueue.sync {
            var root = try loadFileUnlocked(for: folderUrl)
            try mutate(&root.photos)
            try saveFileUnlocked(folderUrl: folderUrl, root: root)
        }
    }
```

- [ ] 将 `loadUnlocked(for:expectedConfig:)` 替换为：

```swift
    private func loadUnlocked(for folderUrl: URL, expectedConfig: analysisConfig? = nil) throws -> [photoItem] {
        let root = try loadFileUnlocked(for: folderUrl)
        if let expectedConfig, root.configSnapshot != expectedConfig {
            throw analysisStoreError.staleConfigSnapshot
        }
        return root.photos
    }
```

- [ ] 在 `loadUnlocked` 后新增：

```swift
    private func loadFileUnlocked(for folderUrl: URL) throws -> analysisFile {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else {
            throw analysisStoreError.missingResults
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(analysisFile.self, from: data)
    }

    private func saveFileUnlocked(folderUrl: URL, root: analysisFile) throws {
        let dir = resultsUrl(for: folderUrl).deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var nextRoot = root
        nextRoot.schemaVersion = "2.0"
        nextRoot.folderPath = folderUrl.path
        nextRoot.updatedAt = isoNow()
        if nextRoot.createdAt.isEmpty { nextRoot.createdAt = nextRoot.updatedAt }
        nextRoot.summary = summaryCounts(nextRoot.photos)

        let data = try JSONEncoder().encode(nextRoot)
        try data.write(to: resultsUrl(for: folderUrl), options: .atomic)
    }
```

- [ ] 将 `saveUnlocked(folderUrl:records:config:)` 中最后从 `existing.schemaVersion = "2.0"` 到写文件的逻辑替换为：

```swift
        existing.photos = records
        if let config {
            existing.configSnapshot = config
        }
        try saveFileUnlocked(folderUrl: folderUrl, root: existing)
```

- [ ] 更新 `rawViewer/appCoordinator.swift` 文件头：版本 `1.8`，日期 `2026-06-25`，Description 追加“v1.8 启动分析直接尝试加载带配置校验的缓存，过期或损坏时重分析”。
- [ ] 将 `startAnalysis(folderUrl:)` 中从 `Task { @MainActor in` 开始到该 Task 闭包结束的整段实现替换为：

```swift
        Task { @MainActor in
            do {
                do {
                    let loadedRecords = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
                    self.records = loadedRecords
                    self.trashService.cleanupTrashedPhotos(self.records)
                    self.showGroups()
                    return
                } catch analysisStoreError.missingResults {
                    appDebugLogger.log("analysis cache missing, analyzing")
                } catch analysisStoreError.staleConfigSnapshot {
                    appDebugLogger.log("analysis cache stale, reanalyzing")
                } catch {
                    appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
                }

                _ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
                    Task { @MainActor in
                        progressController.update(progress: progress)
                    }
                }
                self.records = try await analyzer.loadRecordsAsync(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
            } catch {
                self.screenState = .error(error.localizedDescription)
                self.showError(message: error.localizedDescription)
            }
        }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过。

手动验证：

1. 第一次打开文件夹完成分析。
2. 第二次打开同一文件夹，应直接进入分组页。
3. 第一次打开无缓存文件夹时，应记录一次 `analysis cache missing, analyzing` 并正常分析。
4. 修改分析配置后再次打开同一文件夹，应记录一次 `analysis cache stale, reanalyzing` 并重新分析。

✅ **完成的标志：** 构建通过；`analysisStore.update` 不再通过 `config: nil` 调用旧的保存路径；`startAnalysis` 不再调用 `analysisStore.shared.hasResults(for:)`；缺缓存不再被误报为 stale。

------

### Task 3: 修复图片缓存 key 串图问题

**目标：** 跨文件夹同名照片不会命中旧文件夹的 display/thumbnail 缓存；同路径文件被替换后也尽量通过文件签名失效。

**涉及的文件：**

- `rawViewer/services/photoDisplayService.swift` — display 缓存 key 使用 source + path + size + mtime。
- `rawViewer/services/photoThumbnailService.swift` — thumbnail 缓存 key 使用 source path + size + mtime + 尺寸。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/services/photoDisplayService.swift` 文件头：版本 `1.4`，日期 `2026-06-25`，Description 追加“v1.4 缓存 key 加入文件路径、大小和修改时间，避免跨文件夹同名照片串图”。
- [ ] 在 `init` 后新增：

```swift
    private func displayCacheKey(photo: photoItem, source: displaySource) -> String {
        let path: String
        switch source {
        case .jpg:
            path = photo.jpgPath
        case .raw:
            path = photo.rawPath ?? ""
        }
        return "\(photo.photoId)|display|\(source.rawValue)|\(path)|\(fileSignature(path: path))"
    }

    private func fileSignature(path: String) -> String {
        guard !path.isEmpty,
              let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)"
    }
```

- [ ] 在 `loadDisplayJpg(for:)` 中把所有 `"\(photo.photoId)|displayJpg" as NSString` 替换为先计算并捕获同一个 key：

```swift
        let key = displayCacheKey(photo: photo, source: .jpg)
        if let cached = jpgCache.object(forKey: key as NSString) {
            return .image(cached.image)
        }

        let jpgPath = photo.jpgPath
        let task = Task.detached(priority: .userInitiated) { [weak self, key] () -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadJpg(jpgPath: jpgPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                self.jpgCache.setObject(photoCachedImage(image: image), forKey: key as NSString)
            }
            return result
        }
```

- [ ] 在 `loadDisplayRaw(for:)` 中把所有 `"\(photo.photoId)|displayRaw" as NSString` 替换为同样模式：

```swift
        let key = displayCacheKey(photo: photo, source: .raw)
        if let cached = rawCache.object(forKey: key as NSString) {
            return .image(cached.image)
        }

        let rawPath = photo.rawPath
        let task = Task.detached(priority: .userInitiated) { [weak self, key] () -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadRaw(rawPath: rawPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                self.rawCache.setObject(photoCachedImage(image: image), forKey: key as NSString)
            }
            return result
        }
```

- [ ] 更新 `rawViewer/services/photoThumbnailService.swift` 文件头：版本 `1.4`，日期 `2026-06-25`，Description 追加“v1.4 缩略图缓存 key 加入实际来源路径、大小和修改时间”。
- [ ] 在 `init` 后新增：

```swift
    private func thumbnailCacheKey(photo: photoItem, source: thumbnailSource, maxWidth: Int, maxHeight: Int) -> String {
        "\(photo.photoId)|thumb|\(source.path)|\(fileSignature(path: source.path))|\(maxWidth)x\(maxHeight)"
    }

    private func fileSignature(path: String) -> String {
        guard !path.isEmpty,
              let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)"
    }
```

- [ ] 将 `loadThumbnail(for:maxWidth:maxHeight:)` 完整替换为：

```swift
    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        guard let source = resolveThumbnailSource(for: photo) else {
            return nil
        }

        let cacheKey = thumbnailCacheKey(photo: photo, source: source, maxWidth: maxWidth, maxHeight: maxHeight)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let maxPixelSize = max(maxWidth, maxHeight)
        let task = Task.detached(priority: .userInitiated) { [weak self, cacheKey] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }

            let image = self.decodeThumbnail(source: source, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return nil }

            if let image {
                self.cache.setObject(image, forKey: cacheKey as NSString)
            }
            return image
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过。

手动验证：

1. 准备两个不同文件夹，均包含同 stem 的照片，例如 `P1000001.JPG`，但图像内容不同。
2. 先打开 A 文件夹，进入分组页和详情页。
3. 返回开始页打开 B 文件夹。
4. B 文件夹分组缩略图和详情大图必须显示 B 文件夹图片，不显示 A 文件夹图片。

✅ **完成的标志：** 构建通过；display 与 thumbnail 缓存 key 都包含实际文件路径和签名。

------

### Task 4: 增加 RAW/JPG/display 尺寸与内存安全保护，并修正 JPG origin

**目标：** 损坏或极端大图不会通过 CGFloat 转 Int trap、整数溢出、非法单边纹理尺寸、超大 GPU buffer 或非零 origin 渲染导致崩溃、OOM 或采样偏移。

**涉及的文件：**

- `rawViewer/services/rawBayerAnalyzer.swift` — RAW 尺寸乘法和内存预算检查。
- `rawViewer/services/jpgAnalyzer.swift` — JPG 尺寸乘法、内存预算检查、零原点渲染。
- `rawViewer/services/photoDisplayService.swift` — display 加载时也检查像素尺寸。

------

#### Step 1 — 实现

- [ ] 在 `rawViewer/services/rawBayerAnalyzer.swift` 的 `rawBayerAnalyzer` 类中、`makeError(_:)` 前新增：

```swift
    private func checkedPixelCount(width: Int, height: Int, maxPixels: Int, label: String) throws -> Int {
        guard width > 0, height > 0 else {
            throw makeError("Invalid \(label) dimensions: \(width)x\(height)")
        }
        guard width <= maxPixels / height else {
            throw makeError("\(label) dimension overflow: \(width)x\(height)")
        }
        let pixels = width * height
        guard pixels <= maxPixels else {
            throw makeError("\(label) too large: \(width)x\(height)")
        }
        return pixels
    }

    private func checkedByteCount(pixelCount: Int, bytesPerPixel: Int, maxBytes: Int, label: String) throws -> Int {
        guard pixelCount > 0, bytesPerPixel > 0 else {
            throw makeError("Invalid \(label) byte count input")
        }
        guard pixelCount <= maxBytes / bytesPerPixel else {
            throw makeError("\(label) memory budget exceeded")
        }
        return pixelCount * bytesPerPixel
    }
```

- [ ] 在 `rawBayerAnalyzer.analyze` 中，将：

```swift
        let totalRaw = rawW * rawH
        guard let rawBuffer = context.device.makeBuffer(
            length: totalRaw * MemoryLayout<UInt16>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, totalRaw * MemoryLayout<UInt16>.size)
```

替换为：

```swift
        let maxRawPixels = 120_000_000
        let maxRawBytesPerTask = 768 * 1024 * 1024
        let totalRaw = try checkedPixelCount(width: rawW, height: rawH, maxPixels: maxRawPixels, label: "RAW")
        let rawByteCount = try checkedByteCount(
            pixelCount: totalRaw,
            bytesPerPixel: MemoryLayout<UInt16>.size,
            maxBytes: maxRawBytesPerTask,
            label: "RAW buffer"
        )
        guard let rawBuffer = context.device.makeBuffer(
            length: rawByteCount,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, rawByteCount)
```

- [ ] 在 `greenW` / `greenH` 计算后、创建 `greenBuffer` 前新增：

```swift
        let greenPixels = try checkedPixelCount(width: greenW, height: greenH, maxPixels: maxRawPixels / 4, label: "RAW green plane")
        let greenByteCount = try checkedByteCount(
            pixelCount: greenPixels,
            bytesPerPixel: MemoryLayout<Float>.size,
            maxBytes: maxRawBytesPerTask,
            label: "RAW green plane"
        )
```

- [ ] 将 `greenBuffer` 与 `lapBuffer` 的 `length: greenW * greenH * MemoryLayout<Float>.size` 都替换为 `length: greenByteCount`。

- [ ] 更新 `rawViewer/services/jpgAnalyzer.swift` 文件头：版本 `1.9`，日期 `2026-06-25`，Description 追加“v1.9 JPG 分析增加尺寸/内存预算检查并标准化 CIImage 零原点渲染”。
- [ ] 在 `jpgAnalyzer` 类中、`makeError(_:)` 前新增与 RAW 同名的 `checkedPixelCount` / `checkedByteCount` 私有方法，错误域仍使用 `makeError`。
- [ ] 同时新增 `checkedImageDimensions(extent:maxPixels:maxDimension:label:)`，先检查 `CGFloat` 有限、正数、可安全转 `Int`、单边不超过 Metal 纹理上限，再调用 `checkedPixelCount`：

```swift
    private func checkedImageDimensions(extent: CGRect, maxPixels: Int, maxDimension: Int, label: String) throws -> (width: Int, height: Int, pixels: Int, bounds: CGRect, normalizedOrigin: CGPoint) {
        let integralExtent = extent.integral
        guard integralExtent.width.isFinite, integralExtent.height.isFinite,
              integralExtent.width > 0, integralExtent.height > 0 else {
            throw makeError("\(label) has invalid extent")
        }
        guard integralExtent.width <= CGFloat(Int.max), integralExtent.height <= CGFloat(Int.max) else {
            throw makeError("\(label) dimensions exceed Int range")
        }
        let width = Int(integralExtent.width)
        let height = Int(integralExtent.height)
        guard width <= maxDimension, height <= maxDimension else {
            throw makeError("\(label) dimensions exceed texture limit: \(width)x\(height)")
        }
        let pixels = try checkedPixelCount(width: width, height: height, maxPixels: maxPixels, label: label)
        return (width, height, pixels, CGRect(origin: .zero, size: integralExtent.size), integralExtent.origin)
    }
```

- [ ] 将 `analyze(jpgPath:config:)` 中读取尺寸和渲染部分：

```swift
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else { throw makeError("CIImage has zero dimensions") }
        let totalPixels = width * height
        guard totalPixels <= maxJpgPixels else { throw makeError("JPG too large: \(width)x\(height)") }
```

替换为：

```swift
        let dimensions = try checkedImageDimensions(extent: ciImage.extent, maxPixels: maxJpgPixels, maxDimension: 32_768, label: "JPG")
        let width = dimensions.width
        let height = dimensions.height
        let totalPixels = dimensions.pixels
        let maxJpgBytesPerTask = 768 * 1024 * 1024
        _ = try checkedByteCount(pixelCount: totalPixels, bytesPerPixel: 9, maxBytes: maxJpgBytesPerTask, label: "JPG analysis")
        let normalizedImage = ciImage.transformed(by: CGAffineTransform(translationX: -dimensions.normalizedOrigin.x, y: -dimensions.normalizedOrigin.y))
        let renderBounds = dimensions.bounds
```

- [ ] 将 JPG render 调用替换为：

```swift
        ciContext.render(normalizedImage, to: texture, commandBuffer: cmd, bounds: renderBounds, colorSpace: colorSpace)
```

- [ ] 在 `rawViewer/services/photoDisplayService.swift` 中新增 display 专用尺寸检查，避免 `CGFloat -> Int` trap 和非法单边纹理尺寸：

```swift
    private func isDisplayExtentAllowed(_ extent: CGRect) -> Bool {
        let integralExtent = extent.integral
        guard integralExtent.width.isFinite, integralExtent.height.isFinite,
              integralExtent.width > 0, integralExtent.height > 0 else {
            return false
        }
        guard integralExtent.width <= 32_768, integralExtent.height <= 32_768 else {
            return false
        }
        return integralExtent.width * integralExtent.height <= CGFloat(maxDisplayJpgPixels)
    }
```

- [ ] 在 `loadJpg(jpgPath:)` 中用 `isDisplayExtentAllowed(image.extent)` 替换现有 extent/totalPixels 检查。
- [ ] 在 `loadRaw(rawPath:)` 中，找到 `guard let filter = CIFilter(imageURL: URL(fileURLWithPath: rawPath), options: nil), let image = filter.outputImage else { return .unavailable("Cannot decode RAW") }` 这段解码成功后的下一行，新增：

```swift
        guard isDisplayExtentAllowed(image.extent) else {
            return .unavailable("Invalid or too large RAW extent")
        }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过。

手动验证：

1. 打开正常 RAW/JPG 文件夹，分析和浏览仍可用。
2. 放入异常超大 JPG 或 RAW 文件，应用不崩溃，日志或 UI 中显示该文件分析失败或图片不可用。

✅ **完成的标志：** 构建通过；RAW/JPG 分析路径不再直接裸乘 `width * height` 后分配大 buffer；JPG render 使用零原点 bounds；JPG/display 路径在转 Int 或建 texture 前已检查单边维度。

------

### Task 5: 修复 RAW Bayer pattern 假设和 LibRaw 错误信息

**目标：** RAW 分析按 LibRaw 返回的可见区域 2x2 Bayer pattern 选择绿色像素和 histogram 通道；LibRaw open/unpack 失败时能返回具体错误。

**涉及的文件：**

- `rawViewer/bridge/libRawBridge.h` — 增加 Bayer 字段和 open-with-error API。
- `rawViewer/bridge/libRawBridge.mm` — 填充 pattern 和错误。
- `rawViewer/services/rawBayerAnalyzer.swift` — 读取 pattern 并传给 Metal。
- `rawViewer/metal/rawAnalysisShaders.metal` — histogram 和 green plane 使用 pattern 配置。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/bridge/libRawBridge.h` 文件头：版本 `1.2`，日期 `2026-06-25`，Description 追加“v1.2 返回可见区域 Bayer pattern 并提供 open 错误输出”。
- [ ] 在 `rwRawBayerData` 末尾新增字段：

```cpp
    int color00;
    int color01;
    int color10;
    int color11;
    int green1OffsetX;
    int green1OffsetY;
    int green2OffsetX;
    int green2OffsetY;
    int greenPixelCount;
```

- [ ] 在函数声明区新增：

```cpp
void* rwRawOpenWithError(const char* path, char* errorBuffer, int errorBufferSize);
```

- [ ] 更新 `rawViewer/bridge/libRawBridge.mm` 文件头：版本 `1.2`，日期 `2026-06-25`，Description 追加“v1.2 填充 LibRaw 错误和可见区域 Bayer pattern”。
- [ ] 在 include 区新增：

```cpp
#include <cstdio>
```

- [ ] 在 `RawHandle` 后新增：

```cpp
static void writeError(char* errorBuffer, int errorBufferSize, const char* message) {
    if (errorBuffer == nullptr || errorBufferSize <= 0) return;
    if (message == nullptr) message = "unknown LibRaw error";
    snprintf(errorBuffer, static_cast<size_t>(errorBufferSize), "%s", message);
}

static int colorCodeForChar(char c) {
    switch (c) {
        case 'R': return 0;
        case 'G': return 1;
        case 'B': return 2;
        default: return 3;
    }
}
```

- [ ] 将 `rwRawOpen` 完整替换为：

```cpp
void* rwRawOpen(const char* path) {
    return rwRawOpenWithError(path, nullptr, 0);
}

void* rwRawOpenWithError(const char* path, char* errorBuffer, int errorBufferSize) {
    if (path == nullptr) {
        writeError(errorBuffer, errorBufferSize, "path is null");
        return nullptr;
    }

    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        writeError(errorBuffer, errorBufferSize, libraw_strerror(ret));
        delete h;
        return nullptr;
    }

    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        writeError(errorBuffer, errorBufferSize, libraw_strerror(ret));
        delete h;
        return nullptr;
    }

    return h;
}
```

- [ ] 在 `rwRawGetBayerData` 设置 whiteLevel 后新增：

```cpp
    auto& idata = h->processor.imgdata.idata;
    int greenCount = 0;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            int colorIndex = h->processor.COLOR(data.visibleOffsetY + dy, data.visibleOffsetX + dx);
            char colorChar = idata.cdesc[colorIndex];
            int code = colorCodeForChar(colorChar);
            if (dy == 0 && dx == 0) data.color00 = code;
            if (dy == 0 && dx == 1) data.color01 = code;
            if (dy == 1 && dx == 0) data.color10 = code;
            if (dy == 1 && dx == 1) data.color11 = code;
            if (code == 1) {
                if (greenCount == 0) {
                    data.green1OffsetX = dx;
                    data.green1OffsetY = dy;
                } else if (greenCount == 1) {
                    data.green2OffsetX = dx;
                    data.green2OffsetY = dy;
                }
                greenCount += 1;
            }
        }
    }
    data.greenPixelCount = greenCount;
```

- [ ] 更新 `rawViewer/services/rawBayerAnalyzer.swift` 文件头：版本 `1.8`，日期 `2026-06-25`，Description 追加“v1.8 RAW Bayer pattern 来自 LibRaw，可诊断 open/unpack 错误”。
- [ ] 将 `greenPlaneConfig` 替换为：

```swift
struct greenPlaneConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var greenWidth: UInt32
    var greenHeight: UInt32
    var blackLevel: UInt32
    var green1OffsetX: UInt32
    var green1OffsetY: UInt32
    var green2OffsetX: UInt32
    var green2OffsetY: UInt32
}
```

- [ ] 将 `bayerHistConfig` 替换为：

```swift
struct bayerHistConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var visibleWidth: UInt32
    var visibleHeight: UInt32
    var binCount: UInt32
    var blackLevel: UInt32
    var whiteLevel: UInt32
    var color00: UInt32
    var color01: UInt32
    var color10: UInt32
    var color11: UInt32
}
```

- [ ] 将 open handle 逻辑替换为：

```swift
        var openError = [CChar](repeating: 0, count: 512)
        let handle = rawPath.withCString { pathPointer in
            openError.withUnsafeMutableBufferPointer { buffer in
                rwRawOpenWithError(pathPointer, buffer.baseAddress, CInt(buffer.count))
            }
        }
        guard let handle else {
            let message = String(cString: openError)
            throw makeError("LibRaw open/unpack failed for \(rawPath): \(message.isEmpty ? "unknown" : message)")
        }
```

- [ ] 在 `let data = rwRawGetBayerData(handle)` 后新增：

```swift
        guard data.greenPixelCount == 2 else {
            throw makeError("Unsupported Bayer pattern: expected 2 green pixels, got \(data.greenPixelCount)")
        }
```

- [ ] 构造 `histConfig` 时补充 pattern 字段：

```swift
            color00: UInt32(data.color00), color01: UInt32(data.color01),
            color10: UInt32(data.color10), color11: UInt32(data.color11)
```

- [ ] 构造 `greenConfig` 时补充 green offset 字段：

```swift
            greenWidth: UInt32(greenW), greenHeight: UInt32(greenH), blackLevel: UInt32(black),
            green1OffsetX: UInt32(data.green1OffsetX), green1OffsetY: UInt32(data.green1OffsetY),
            green2OffsetX: UInt32(data.green2OffsetX), green2OffsetY: UInt32(data.green2OffsetY)
```

- [ ] 更新 `rawViewer/metal/rawAnalysisShaders.metal` 文件头：版本 `1.4`，日期 `2026-06-25`，Description 追加“v1.4 RAW histogram/green plane 根据 LibRaw Bayer pattern 取样”。
- [ ] 将 Metal `BayerHistConfig` 和 `GreenPlaneConfig` 替换为以下完整定义，字段顺序必须与 Swift 结构一致：

```metal
struct BayerHistConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint visibleWidth; uint visibleHeight;
    uint binCount; uint blackLevel; uint whiteLevel;
    uint color00; uint color01; uint color10; uint color11;
};

struct GreenPlaneConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint greenWidth; uint greenHeight; uint blackLevel;
    uint green1OffsetX; uint green1OffsetY;
    uint green2OffsetX; uint green2OffsetY;
};
```

- [ ] 在 Metal 中新增：

```metal
static inline uint bayerColorForLocal(uint localX, uint localY, constant BayerHistConfig& config) {
    bool right = (localX & 1u) == 1u;
    bool bottom = (localY & 1u) == 1u;
    if (!bottom && !right) return config.color00;
    if (!bottom && right) return config.color01;
    if (bottom && !right) return config.color10;
    return config.color11;
}
```

- [ ] 将 `bayerHistogramKernel` 中 hard-coded channel 行替换为：

```metal
    uint channel = bayerColorForLocal(localX, localY, config);
```

- [ ] 将 `bayerToGreenPlaneKernel` 中 g1/g2 坐标替换为：

```metal
    uint g1X = baseX + config.green1OffsetX;
    uint g1Y = baseY + config.green1OffsetY;
    uint g2X = baseX + config.green2OffsetX;
    uint g2Y = baseY + config.green2OffsetY;
    if (g1X >= config.rawWidth || g1Y >= config.rawHeight || g2X >= config.rawWidth || g2Y >= config.rawHeight) return;
    uint g1 = static_cast<uint>(rawBuffer[g1Y * config.rawWidth + g1X]);
    uint g2 = static_cast<uint>(rawBuffer[g2Y * config.rawWidth + g2X]);
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过，ObjC++、Swift、Metal 均无编译错误。

手动验证：

1. 使用原有 RGGB RAW 文件分析，结果仍正常。
2. 使用非 RGGB RAW 文件分析，不应静默按 RGGB 算错；若 LibRaw 返回 2 个绿色像素，应正常分析；若 pattern 异常，应报 `Unsupported Bayer pattern` 并进入既有 JPG fallback 或失败路径。
3. 使用损坏 RAW 文件，错误信息包含 LibRaw 返回的具体 open/unpack 失败原因。

✅ **完成的标志：** 构建通过；Metal 中不存在固定 `(baseX + 1, baseY)` 与 `(baseX, baseY + 1)` 的绿色假设；LibRaw open 失败不再只有 `returned null`。

------

### Task 6: 修复异步 UI 复用陈旧写入

**目标：** 缩略图 cell 和分组卡片复用后，旧异步加载任务不会把旧照片图片写入新 cell/card。

**涉及的文件：**

- `rawViewer/views/photoThumbnailCellView.swift` — 记录并校验 `representedPhotoId`。
- `rawViewer/views/groupCardView.swift` — 增加 generation，reset 时清理闭包和任务。
- `rawViewer/views/groupCollectionViewItem.swift` — `prepareForReuse` 调用 card reset。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/views/photoThumbnailCellView.swift` 文件头：版本 `1.1`，日期 `2026-06-25`，Description 追加“v1.1 异步缩略图回调校验 photoId，避免 cell 复用串图”。
- [ ] 在属性区新增：

```swift
    private var representedPhotoId: String?
```

- [ ] 在 `configure(photo:index:isSelected:isChecked:imageService:)` 中 `thumbIndex = index` 后新增：

```swift
        representedPhotoId = photo.photoId
```

- [ ] 在创建 task 前新增：

```swift
        let expectedPhotoId = photo.photoId
```

- [ ] 将 task 的 MainActor guard 替换为：

```swift
                guard let self = self,
                      self.representedPhotoId == expectedPhotoId,
                      let targetView = targetView,
                      self.thumbImageView === targetView else { return }
```

- [ ] 在 `prepareForReuse()` 中 `cancelLoad()` 后新增：

```swift
        representedPhotoId = nil
```

- [ ] 更新 `rawViewer/views/groupCardView.swift` 文件头：版本 `2.9`，日期 `2026-06-25`，Description 追加“v2.9 增加复用 generation 和 resetForReuse，避免卡片异步预览串图”。
- [ ] 在属性区新增：

```swift
    private var loadGeneration: Int = 0
```

- [ ] 在 `configure(group:previewPhotos:)` 开头替换为：

```swift
        cancelLoads()
        loadGeneration += 1
        let expectedGeneration = loadGeneration
        cardContainers.forEach { $0.removeFromSuperview() }
        cardContainers.removeAll()
```

- [ ] 将每个预览 task 的 MainActor guard 替换为：

```swift
                    guard let self = self,
                          self.loadGeneration == expectedGeneration,
                          let container = targetView.superview,
                          self.cardContainers.contains(container) else { return }
                    targetView.image = image
```

- [ ] 在 `cancelLoads()` 后新增：

```swift
    public func resetForReuse() {
        cancelLoads()
        loadGeneration += 1
        onTap = nil
        cardContainers.forEach { $0.removeFromSuperview() }
        cardContainers.removeAll()
        nameLabel.stringValue = ""
        countLabel.stringValue = ""
    }
```

- [ ] 更新 `rawViewer/views/groupCollectionViewItem.swift` 文件头：版本 `1.3`，日期 `2026-06-25`，Description 追加“v1.3 prepareForReuse 清理 groupCardView 的任务和旧闭包”。
- [ ] 将 `prepareForReuse()` 替换为：

```swift
    public override func prepareForReuse() {
        super.prepareForReuse()
        cardView?.resetForReuse()
    }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过。

手动验证：

1. 打开大量照片的分组页，快速滚动分组卡片，预览图不跳成旧组图片。
2. 打开浏览器缩略图列表，快速上下滚动和切换选择，cell 不显示旧照片缩略图。

✅ **完成的标志：** 构建通过；`photoThumbnailCellView` 回调校验 `representedPhotoId`；`groupCardView.prepareForReuse` 路径会取消旧任务并清空旧闭包。

------

### Task 7: 修复 UI 脆弱点和 duplicate 来源一致性

**目标：** Duplicate 比较页不会在 segment 显示 RAW/JPG 时左右实际来源不同；分组 item dequeue 失败不会直接 crash；窗口 screenState 只有 coordinator 一份真实状态。

**涉及的文件：**

- `rawViewer/duplicate/duplicateCompareViewController.swift` — source segment 两侧均可用才允许选择。
- `rawViewer/groupGrid/groupGridViewController.swift` — 强转改为 guard。
- `rawViewer/mainWindowController.swift` — `screenState` 转发 coordinator。

------

#### Step 1 — 实现

- [ ] 更新 `rawViewer/duplicate/duplicateCompareViewController.swift` 文件头：版本 `3.10`，日期 `2026-06-25`，Description 追加“v3.10 duplicate source segment 要求左右两侧均可用，避免左右 RAW/JPG 混比”。
- [ ] 将 `canSelectJpgForCurrentPair()` 替换为：

```swift
    private func canSelectJpgForCurrentPair() -> Bool {
        let leftHasJpg = viewModel.mainPhoto?.hasExistingJpgFile() == true
        let rightHasJpg = viewModel.candidatePhoto?.hasExistingJpgFile() == true
        return leftHasJpg && rightHasJpg
    }
```

- [ ] 将 `canSelectRawForCurrentPair()` 替换为：

```swift
    private func canSelectRawForCurrentPair() -> Bool {
        let leftHasRaw = viewModel.mainPhoto?.hasExistingRawFile() == true
        let rightHasRaw = viewModel.candidatePhoto?.hasExistingRawFile() == true
        return leftHasRaw && rightHasRaw
    }
```

- [ ] 更新 `rawViewer/groupGrid/groupGridViewController.swift` 文件头：版本 `4.6`，日期 `2026-06-25`，Description 追加“v4.6 dequeue groupCollectionViewItem 失败时记录错误并返回空 item，避免强转崩溃”。
- [ ] 将 `itemForRepresentedObjectAt` 开头的强制转换替换为：

```swift
        let identifier = NSUserInterfaceItemIdentifier("groupCard")
        guard let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as? groupCollectionViewItem else {
            appFileLogger.log("failed to dequeue groupCollectionViewItem index=\(indexPath.item)", level: .error)
            return NSCollectionViewItem()
        }
```

- [ ] 更新 `rawViewer/mainWindowController.swift` 文件头：版本 `2.3`，日期 `2026-06-25`，Description 追加“v2.3 screenState 转发 coordinator，避免窗口控制器维护过期状态”。
- [ ] 将属性：

```swift
    public private(set) var screenState: windowScreenState = .start
```

替换为：

```swift
    public var screenState: windowScreenState {
        coordinator?.screenState ?? .start
    }
```

------

#### Step 2 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过。

手动验证：

1. 打开左右一侧有 RAW、另一侧无 RAW 的 duplicate 组，RAW segment 不可选；若 JPG 双侧都有，JPG 可选。
2. 正常打开分组页，卡片仍可点击进入对应页面。
3. 若有调试入口读取 `mainWindowController.screenState`，其值与当前页面一致。

✅ **完成的标志：** 构建通过；duplicate source 选择使用 `&&`；`mainWindowController` 不再持有独立可变 `screenState`。

------

### Task 8: 最终构建与回归走查

**目标：** 所有修复合并后 Debug 构建通过，关键用户路径无 crash、无明显错误显示。

**涉及的文件：**

- 全部本计划修改文件。

------

#### Step 1 — 运行验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

预期：构建通过，日志中没有 Swift/ObjC++/Metal 编译错误。

手动走查：

1. **缓存路径**：同一文件夹二次打开可复用缓存；配置变化时会重分析。
2. **跨文件夹同名**：A/B 两个文件夹同名照片不会串缩略图或大图。
3. **浏览器删除**：删除当前组全部照片后返回分组页。
4. **重复组**：`Keep both`、删左、删右都能继续比较或结束，失败时不提前改内存。
5. **RAW/JPG**：普通 RAW/JPG 分析仍成功；损坏或超大文件不会导致应用崩溃。
6. **快速滚动**：分组页和缩略图列表快速滚动不显示旧图片。

✅ **完成的标志：** 构建通过；上述六条手动走查符合预期。

---

## 自我复审

- **规范覆盖：** Critical/High 问题均有任务覆盖；Medium 中与状态、分析正确性、UI 复用、崩溃点相关的问题有任务覆盖；Low 中不影响当前可靠性的 `runModal`、全量文件头、测试 target 不纳入本轮。
- **占位符扫描：** 本计划不包含待补实现项；所有代码片段均为可直接替换的具体实现。
- **类型一致性：** `bayerHistConfig` / `greenPlaneConfig` 的 Swift 与 Metal 字段顺序在 Task 5 明确要求一致；`rwRawOpenWithError` 的 C 签名和 Swift 调用使用 `withUnsafeMutableBufferPointer` + `CInt`，避免 Swift 数组错误传参。
- **验证完整性：** 每个任务均包含 `xcodebuild` 构建命令和手动关键路径验证，不使用测试框架，不包含 Git 操作。

## 执行交接

计划已完成并保存到 `docs/flare/260625_code_review_fixes.md`。两种执行选项：

**1. 子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。

**2. 内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

请选择执行方式。
