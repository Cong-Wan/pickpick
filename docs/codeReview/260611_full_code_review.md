# 代码审核报告 — rawViewer 全量代码审查

### 总览
- **审核文件：** 40 个核心源码/配置文件（Swift / Objective-C++ / Metal / YAML）
- **验证结果：** `xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build` 通过
- **发现问题：** 🔴 0 个 / 🟠 7 个 / 🟡 7 个 / 🔵 3 个
- **整体评价：** 当前代码已经能编译，并且模块拆分方向清晰；主要风险集中在 AppKit 主线程更新、并发分析阶段的数据竞争、用户操作后内存态与 JSON 持久化不同步，以及配置/异常路径缺少防护。这些问题在真实图库、错误配置、批量删除或重复比较流程中会造成 UI 异常、卡死、状态错乱或静默失败。

---

### 问题清单

#### 🟠 [High] 后台分析线程直接更新 AppKit UI，存在主线程违规

**位置**: `rawViewer/appCoordinator.swift:45-56`、`rawViewer/services/photoAnalysisService.swift:120-122`、`rawViewer/services/photoAnalysisService.swift:182-185`

**问题**: `photoAnalysisService.analyze` 在并发 `DispatchQueue` 中调用 `progress(...)`，而 `appCoordinator` 传入的闭包直接执行 `progressController.update(progress:)`。AppKit UI 必须在主线程更新，否则会出现随机 UI 不刷新、错乱，严重时崩溃。

**修复方案**: 让 UI 更新显式回到 MainActor。最小修复是在 coordinator 侧包一层主线程派发：

```swift
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    Task { @MainActor in
        progressController.update(progress: progress)
    }
}
```

更稳妥的方案是把 `photoAnalyzing.analyze` 的 progress 设计成 `@MainActor` 或 `async` 回调，避免调用方忘记切线程。

---

#### 🟠 [High] `exifReader` 的 `DateFormatter` 被并发访问，可能数据竞争

**位置**: `rawViewer/services/exifReader.swift:20-30`、`rawViewer/services/photoAnalysisService.swift:98-105`

**问题**: `photoAnalysisService` 用并发队列同时调用同一个 `exifReader` 实例。`exifReader` 内部持有单个 `DateFormatter`，而 `DateFormatter` 不是线程安全对象。大量照片并发读取 EXIF 时，可能出现解析结果错误、偶发崩溃或 TSAN 数据竞争。

**修复方案**: 不要在并发路径共享 `DateFormatter`。可选最小修复：每次解析创建局部 formatter；如果担心性能，可用锁保护。

```swift
private func parseExifDate(_ value: String) -> Int64? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.timeZone = TimeZone.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    guard let date = formatter.date(from: value) else { return nil }
    return Int64(date.timeIntervalSince1970.rounded())
}
```

---

#### 🟠 [High] `metalConcurrency` 未校验，配置为 0 会导致分析永久卡死

**位置**: `rawViewer/services/configLoader.swift:58-61`、`rawViewer/services/photoAnalysisService.swift:131-139`

**问题**: `config.yaml` 是用户可覆盖配置。若 `analysis.metal_concurrency` 被设为 `0`，`DispatchSemaphore(value: 0)` 会让所有分析任务阻塞在 `wait()`，随后 `analysisGroup.wait()` 永不返回，进度页永久卡住。负数或过大值也会带来不可预期行为或资源打爆。

**修复方案**: 配置加载阶段做边界校验和夹取。

```swift
let rawConcurrency = intValue(analysisNode["metal_concurrency"])
    ?? analysisConfig.defaults.metalConcurrency
let concurrency = min(max(rawConcurrency, 1), 4)

return analysisConfig(exposure: exposure, blur: blur, metalConcurrency: concurrency)
```

同时建议对 exposure 阈值也做 `0...1` 校验。

---

#### 🟠 [High] 曝光阈值配置未校验，非法 YAML 可触发运行时崩溃或错误判定

**位置**: `rawViewer/services/configLoader.swift:40-56`、`rawViewer/services/rawBayerAnalyzer.swift:132-134`、`rawViewer/services/jpgAnalyzer.swift:92-94`

**问题**: `overexpose_pixel_threshold` / `underexpose_pixel_threshold` 按注释应为 `0.0...1.0`，但加载后没有校验。若用户配置为负数、NaN 或大于 1，后续转换为 `UInt32` 时可能运行时 trap，或生成超过白场的阈值，导致所有曝光判断失真。

**修复方案**: 在 `configLoader.parse` 中统一校验所有用户输入：

```swift
private func ratioValue(_ any: Any?, default defaultValue: Double) -> Double {
    guard let value = doubleValue(any), value.isFinite else { return defaultValue }
    return min(1.0, max(0.0, value))
}
```

然后 exposure 四个字段全部使用受控解析；ratio limit 也应限制在 `0...1`。

---

#### 🟠 [High] 浏览器删除后返回分组页会显示旧数据

**位置**: `rawViewer/appCoordinator.swift:96-98`、`rawViewer/browser/photoBrowserViewModel.swift:69-91`、`rawViewer/browser/photoBrowserViewController.swift:193-198`

**问题**: 浏览器删除照片时只更新 `analysis.json` 和当前 `viewModel.photos`，没有更新 `appCoordinator.records`。点击 Back 后 `showGroups()` 用旧的 `records` 重新生成分组，已删除/已移入废纸篓的照片仍会回到分组页，后续点击会加载缺失文件。

**修复方案**: Browser 返回时和删除成功后都应让 coordinator 重载 JSON 或同步内存态。最小修复：

```swift
browser.onBack = { [weak self] in
    guard let self else { return }
    try? self.reloadData()
    self.showGroups()
}
```

更完整的方案是在 `photoBrowserViewController` 删除成功后通过回调通知 coordinator 删除了哪些 `photoId`，直接更新 `records`，避免每次返回都读盘。

---

#### 🟠 [High] 删除/保留操作吞掉错误或产生文件系统与 JSON 状态不一致

**位置**: `rawViewer/browser/photoBrowserViewModel.swift:81-90`、`rawViewer/duplicate/duplicateCompareViewModel.swift:37-39`、`rawViewer/duplicate/duplicateCompareViewController.swift:184-209`、`rawViewer/duplicate/duplicateCompareViewController.swift:221-230`

**问题**: 多处操作先移动文件到废纸篓，再更新 JSON。若部分文件已成功进入废纸篓，随后 `analysisStore.save` 失败，就会出现“文件已被删，但 JSON 仍 active”的状态。重复比较控制器还大量使用 `try?`，失败时 UI 不提示，用户以为操作成功。

**修复方案**:
1. 不要在控制器层使用 `try?` 吞错，失败时弹出错误提示。
2. 批量删除至少记录已成功处理的 photoId，并对失败做可恢复提示。
3. 将 review 状态更新合并为一次 read-modify-write，减少中间半成功状态。

示例：

```swift
do {
    let result = try viewModel.keepLeft()
    handleActionResult(result)
} catch {
    showError("操作失败：\(error.localizedDescription)")
}
```

---

#### 🟠 [High] `makeComputeCommandEncoder()!` 在 GPU 异常路径会直接崩溃

**位置**: `rawViewer/services/rawBayerAnalyzer.swift:175`、`:213`、`:237`、`:258`；`rawViewer/services/jpgAnalyzer.swift:106`、`:124`、`:146`、`:174`

**问题**: `cmd.makeComputeCommandEncoder()` 返回 Optional。当前代码强制解包，在 command buffer 状态异常、资源压力或 Metal 驱动返回 nil 时会直接崩溃。虽然常规机器上概率不高，但这是图像批处理热路径，处理大量大图时更容易触发资源异常。

**修复方案**: 使用 guard 并抛错，让上层走 JPG fallback 或显示错误。

```swift
guard let encoder = cmd.makeComputeCommandEncoder() else {
    throw makeError("makeComputeCommandEncoder failed")
}
encoder.setComputePipelineState(context.bayerHistogramPipeline)
```

---

#### 🟡 [Medium] 重复比较的多步 JSON 写入不是原子操作

**位置**: `rawViewer/duplicate/duplicateCompareViewModel.swift:67-95`、`rawViewer/models/jsonReviewStateStore.swift:29-57`

**问题**: `keepBoth` 会连续调用 `mark`、`clearReviewGroupId`、`setTemplate`，每次调用都会重新 load/save 整个 JSON。中途任何一次写入失败，都会留下部分照片已 kept、部分仍在 duplicate group 的混合状态。重复组状态依赖多个字段，这类半状态后续很难自动恢复。

**修复方案**: 给 store 增加一个批量事务接口，一次加载、一次修改、一次保存。

```swift
func update(_ mutate: (inout [photoItem]) -> Void) throws
```

然后 ViewModel 在一个闭包中完成 left/right/remaining 的全部字段变更。

---

#### 🟡 [Medium] 分析进度计数在并发执行下不代表真实完成数

**位置**: `rawViewer/services/photoAnalysisService.swift:101-122`、`:135-185`

**问题**: 进度使用 `index + 1` 作为 completedCount。并发队列中任务完成顺序不等于原数组顺序，所以进度可能从 80 跳回 20，或者显示已完成数量不准确。

**修复方案**: 用锁保护一个真实完成计数器。

```swift
var completedCount = 0
recordsLock.lock()
completedCount += 1
let completed = completedCount
recordsLock.unlock()
```

分析阶段和 EXIF 阶段分别维护独立计数。

---

#### 🟡 [Medium] `analysisStore.hasResults` 只看文件存在，损坏 JSON 会阻断重新分析

**位置**: `rawViewer/services/analysisStore.swift:62-71`、`rawViewer/appCoordinator.swift:47-52`

**问题**: 只要 `analysis.json` 文件存在，启动流程就进入 `loadRecords`。如果文件为空、损坏或 schema 不兼容，会直接进入错误页，不会自动重新分析，也没有给用户重建入口。

**修复方案**: 将 `hasResults` 改成 `load` 成功才算有效；失败时允许删除旧缓存并重新分析。

```swift
if let loadedRecords = try? analyzer.loadRecords(folderUrl: folderUrl), !loadedRecords.isEmpty {
    records = loadedRecords
    showGroups()
} else {
    _ = try await analyzer.analyze(...)
}
```

---

#### 🟡 [Medium] RAW 动态范围计算把 histogram bin 当作真实码值使用

**位置**: `rawViewer/services/rawBayerAnalyzer.swift:312-315`、`rawViewer/metal/rawAnalysisShaders.metal:52-57`

**问题**: Metal histogram 的 bin 是 `0..<4096` 的归一化桶，不是 RAW 原始码值。`codeRangeEv = log2(Double(white - black) / Double(max(1, p01)))` 把 bin 直接当码值，会随 `binCount` 改变而改变含义，DR 数值不可靠。

**修复方案**: 将 bin 转回线性码值后再计算，或直接按 bin 维度计算一致的比例。

```swift
let p01Code = Double(p01) / Double(binCount - 1) * Double(white - black)
let p999Code = Double(p999) / Double(binCount - 1) * Double(white - black)
let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
let codeRangeEv = p01Code > 0 ? log2(Double(white - black) / p01Code) : 0
```

---

#### 🟡 [Medium] JPG/显示路径缺少大图尺寸保护，可能造成内存峰值过高

**位置**: `rawViewer/services/jpgAnalyzer.swift:24-240`、`rawViewer/services/photoDisplayService.swift:71-79`

**问题**: RAW 显示路径有 1GB 文件大小保护，但 JPG 分析和显示路径没有尺寸/像素数上限。超高像素 JPG 会创建 RGBA texture、grayBuffer、lapBuffer、histBuffer 等多个大对象，可能造成内存暴涨或 Metal 分配失败。

**修复方案**: 在读取 CIImage extent 后设置最大像素数，例如 100MP 或可配置阈值；超过阈值时降采样分析或返回明确错误。

---

#### 🟡 [Medium] 全量并发的 EXIF/分析队列可能在大图库下产生资源压力

**位置**: `rawViewer/services/photoAnalysisService.swift:98-190`

**问题**: EXIF 阶段对所有文件直接 `exifQueue.async`，没有并发上限；分析阶段虽然用 semaphore 限制 GPU 分析，但仍一次性创建所有任务。几千张照片时会产生大量 block、文件句柄与 Spotlight/ImageIO 调用压力。

**修复方案**: 使用 `OperationQueue.maxConcurrentOperationCount` 或 `withTaskGroup` + worker 模式控制整体并发数，不要一次性提交全部任务。

---

#### 🟡 [Medium] `metalAnalysisContext` 初始化失败使用 `fatalError`，应用会直接退出

**位置**: `rawViewer/metal/metalAnalysisContext.swift:26-58`

**问题**: 缺少 Metal、shader 未编入 bundle、pipeline 编译失败都会 `fatalError`。这对开发期排错方便，但用户环境下会直接闪退，没有错误页。

**修复方案**: 将 shared 初始化改成 throwing factory，或者在分析服务初始化阶段捕获并展示“设备不支持 Metal / shader 缺失”的可读错误。

---

#### 🔵 [Low] 浏览器切换 JPG/RAW 不会写入 `displaySourceStore`

**位置**: `rawViewer/browser/photoBrowserViewController.swift:176-180`、`rawViewer/duplicate/duplicateCompareViewController.swift:179-181`

**问题**: Duplicate 页面切换 source 会保存到 `displaySourceStore`，Browser 页面只改 ViewModel，不持久化。导致两个页面行为不一致，用户在 Browser 里切到 RAW，下次进入仍可能回到旧设置。

**修复方案**:

```swift
@objc private func sourceChanged(_ sender: NSSegmentedControl) {
    let source: displaySource = (sender.selectedSegment == 0) ? .jpg : .raw
    displaySourceStore().current = source
    viewModel.setDisplaySource(source)
    loadCurrentPhoto()
}
```

建议把 store 注入 ViewModel，避免控制器临时创建。

---

#### 🔵 [Low] `showError(_:)` 只设置状态，不实际渲染错误文字

**位置**: `rawViewer/views/metalPhotoView.swift:99-108`、`:151-185`

**问题**: `showError` 设置了 `errorMessage` 和 `isShowingError`，但 `draw(_:)` 只清空 drawable，不绘制文本。用户看到的是黑屏，不知道是 RAW 缺失、解码失败还是其他问题。

**修复方案**: 在 `photoMetalViewController` 外层叠加一个 `NSTextField` 错误 label，或在 Metal draw 之外用 AppKit 显示错误状态。

---

#### 🔵 [Low] `appDelegate` 中存在可移除的强制解包和临时调试日志

**位置**: `rawViewer/appDelegate.swift:17-24`

**问题**: `guard controller.window != nil` 后继续 `controller.window!`，当前逻辑不会崩，但没有必要；同时启动日志中带有大量临时 emoji 调试信息，不适合长期保留在正式版本。

**修复方案**:

```swift
guard let window = controller.window else {
    NSLog("main window is nil")
    return
}
NSLog("showWindow, window.isVisible=%@", window.isVisible ? "YES" : "NO")
```

---

### 优点记录

- **模块拆分清晰**：扫描、EXIF、分析、持久化、缩略图、显示图、废纸篓服务都已拆成独立类型，后续修复不会过度牵连 UI。
- **构建状态良好**：Debug 构建通过，Swift/ObjC++/Metal/Yams 依赖当前能完整链接。
- **图像显示内存意识较好**：缩略图路径已改用 `CGImageSourceCreateThumbnailAtIndex`，避免分组卡片加载完整原图。
- **缓存与状态机方向正确**：display/thumbnail cache 分离、ViewModel 持有导航状态、异步加载用 requestId 防陈旧结果覆盖，这些设计值得保留。

---

### 修复优先级建议

1. **先修主线程与并发安全**：`progressController.update` 回主线程、`DateFormatter` 不共享并发访问。这两项最容易造成随机崩溃/错乱。
2. **再修状态一致性**：Browser 删除后刷新 coordinator records；删除/重复比较不要 `try?` 吞错；批量 review 状态改成单次 JSON 写入。
3. **最后补配置和资源防护**：校验 `config.yaml`，限制 JPG 像素数，替换 Metal 强制解包/fatalError，让异常路径可恢复。
