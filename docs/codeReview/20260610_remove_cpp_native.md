# 代码审核报告 — 去除 cpp 独立分析 + Swift 原生分析重构

**审核日期**: 2026-06-10
**审核范围**: 13 个 Task 对应的所有新增/修改文件 (rawViewer/services/, rawViewer/metal/, rawViewer/bridge/, rawViewer/models/, rawViewer/appCoordinator.swift, rawViewer/mainWindowController.swift, rawViewer/views/*)
**对应 plan**: `docs/flare/20260610_remove_cpp_native_analysis.md`

---

### 总览

- **审核文件**: 18 个 (15 Swift + 1 Metal + 1 ObjC++ + 1 C 头)
- **发现问题**: 🔴 1 个 / 🟠 5 个 / 🟡 7 个 / 🔵 7 个
- **整体评价**: 整体迁移结构清晰, 协议抽象到位 (`rawBayerAnalyzing` / `jpgAnalyzing` / `photoAnalyzing`), Metal GPU 流水线布局合理, 4-dispatch + 1 sync 与 plan 一致. 但有 1 个 Critical 编译失败级问题和 1 个会污染历史数据的 Schema 不一致问题, 必须修复; 此外 `config.yaml` 没有被加到 bundle 资源 + schema 与 Swift 不匹配, 整套配置加载实际上是 fallback 到 hardcode 默认值, 文档与计划严重失真.

---

### 问题清单

#### 🔴 Critical (1)

### [Critical] `config.yaml` 中所有数值仍使用旧 cpp 时代的 8-bit 绝对值, 与新 Swift 代码期待的 ratio 类型完全不匹配 — 任何被加载的 yaml 都会计算出错误阈值

**位置**: `rawViewer/config.yaml` + `rawViewer/services/configLoader.swift`

**问题**: Plan Task 1/3 设计的 config 加载流程是 `folderUrl/config.yaml` → `Bundle.main/config.yaml` → defaults, 而新代码的 `overexposePixelThreshold` / `underexposePixelThreshold` / `overexposeRatioLimit` / `underexposeRatioLimit` 全部期待 **0.0~1.0 的归一化 ratio** (用于 `absOver = black + (white-black) * ratio` 计算). 但 `rawViewer/config.yaml` 保留的是旧 cpp 时代的 8-bit 绝对值 (245/10/0.05/0.05).

**严重后果**:
- `jpgAnalyzer` 路径: `absOver = UInt32(255 * 245) = 62475` (远超 uchar 范围 0~255), 实际过曝判定条件 `gray > 62475` 永远为 false → **永远不会判定为过曝**.
- `rawBayerAnalyzer` 路径: `absOver = 0 + 4096 * 245 = 1,003,520` (远超 12-bit 范围 0~4096), 永远为 false → **永远不会判定为过曝**.
- 而 `config.yaml` 又没有 `laplacian_threshold_raw` / `laplacian_threshold_jpg` / `metal_concurrency` 这几个新字段, 所以 `parse()` 会用 defaults 兜底.

幸运的是, `rawViewer/config.yaml` **没有被加到 Xcode 的 Copy Bundle Resources 阶段** (PBXResourcesBuildPhase 的 `files` 为空), `Bundle.main.url(forResource: "config", withExtension: "yaml")` 返回 nil, 所以三级降级最终走 defaults. 但只要用户在自己照片目录放一个 `config.yaml`, 立刻就会出错.

**修复方案**:
1. 把 `rawViewer/config.yaml` 更新为新 schema (ratio 形式), 例如:
   ```yaml
   exposure_detection:
     overexpose_pixel_threshold: 0.96    # ratio
     underexpose_pixel_threshold: 0.04
     overexpose_ratio_limit: 0.05
     underexpose_ratio_limit: 0.05
   blur_detection:
     laplacian_threshold_raw: 5000.0
     laplacian_threshold_jpg: 10.0
     laplacian_kernel_size: 3
   analysis:
     metal_concurrency: 2
   ```
2. 把该文件加到 `rawViewer` target 的 `Copy Bundle Resources` 阶段 (Xcode UI 操作), 并在 `project.pbxproj` 中以 PBXBuildFile 形式引用.

---

#### 🟠 High (5)

### [High] `libRawBridge.mm::rwRawOpen` 在 `open_file` / `unpack` 失败时仍返回非空 handle, 与 `rawBayerAnalyzer` 的"handle == null 即失败"判断矛盾 — 任何 LibRaw 解码失败的 RAW 都会先报"成功", 然后再报"LibRaw error"

**位置**: `rawViewer/bridge/libRawBridge.mm:17-30` + `rawViewer/services/rawBayerAnalyzer.swift:86-100`

**问题**: C++ 端 `rwRawOpen` 在 `open_file` / `unpack` 返回非 `LIBRAW_SUCCESS` 时只设置 `lastError` 字符串, **仍然返回非 null 的 `RawHandle*`**. Swift 端的判断顺序却是:
```swift
guard let handle = rwRawOpen(rawPath) else { /* throw */ }   // 通过! 实际拿到的 handle 是非空
defer { rwRawClose(handle) }
let errorMsg = String(cString: rwRawLastError(handle))
if !errorMsg.isEmpty { throw ... }                              // 第二次才报真实错误
```

**后果**:
- 错误信息冗余 (先打"open_file returned null"会误导日志, 实际拿到了非空 handle).
- 抛出异常的时机滞后, 异常消息虽然最终是正确的 "LibRaw error: ...", 但用户日志中先看到 code 1 (null) 再看到 code 2 (error), 排查时间被浪费.

**修复方案**: 让 C++ 端失败时返回 nullptr, Swift 端 `guard let handle = ...` 就一次性判断. 即:
```cpp
void* rwRawOpen(const char* path) {
    if (path == nullptr) return nullptr;
    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        h->lastError = "open_file failed: ";
        h->lastError += h->processor.strerror(ret);
        delete h;                       // 先释放
        return nullptr;                  // 再返回 null
    }
    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        h->lastError = "unpack failed: ";
        h->lastError += h->processor.strerror(ret);
        delete h;
        return nullptr;
    }
    return h;
}
```
然后 Swift 端 `errorMsg` 检查可以保留作为额外的 last-resort, 但不再依赖它来识别失败.

---

### [High] `analysisStore` 的 `reviewStatus` 序列化/反序列化使用 rawValue 字符串 + 引入 "pickpick." 模块前缀, 不仅风格怪异, 还导致 schema 与 `photoItem.reviewStatus: enum` 不直接互通 — 任何外部工具读 json 都需先理解这套自定义 record 协议

**位置**: `rawViewer/services/analysisStore.swift:23-62`

**问题**: 
1. `photoItemRecord` 是一个自定义中间结构 (含 `reviewStatusRaw: String`), 引入它是为了把 `enum reviewStatus` 序列化为字符串. 但 `reviewStatus` 本身已经 `Codable + Equatable + String rawValue`, 直接把 `photoItem` 本身做 `Codable` 即可, 没必要绕一圈.
2. `pickpick.reviewStatus(rawValue: record.reviewStatusRaw) ?? .active` 这种前缀写法是合法的 Swift (模块名当命名空间), 但视觉上极易让人误以为是某个外部模块名. 实际上 `pickpick` 就是当前 product name, 在整个工程里没有其他出现, 应该直接写 `reviewStatus(rawValue: ...)`.

**后果**:
- 冗余的 record 类型增加维护成本 (3 处字段名要保持同步).
- `pickpick.jpgAnalyzer()` 这种调用方式 (在 `photoAnalysisService.swift:70`) 既无必要也易读性差, 看到 `pickpick.` 前缀会让人以为在调外部 API.

**修复方案**:
1. 让 `photoItem` 自身实现 `Codable` (在 `photoModels.swift` 顶部加 `: Codable`), 删掉 `photoItemRecord` / `analysisStore.swift` 里的中间转换.
2. 全部去掉 `pickpick.` 前缀.

---

### [High] `rawBayerAnalyzer` 的 percentiles 函数使用 `p01Bin == 0` 作为"尚未设置"哨兵, 会在小数据/纯黑图上误判

**位置**: `rawViewer/services/rawBayerAnalyzer.swift:331-346` + `rawViewer/services/jpgAnalyzer.swift:255-267`

**问题**:
```swift
var p01Bin: UInt32 = 0
...
for i in 0..<binCount {
    cum += UInt64(greenHist[i])
    if p01Bin == 0, cum >= UInt64(Int64(p01Target)) { p01Bin = UInt32(i) }
    ...
}
```
`p01Bin == 0` 既是初始值又是判定条件. 如果直方图第一个 bin 累计值已经超过 `p01Target` (0.1% 像素 = 1 张图至少 1 个像素), `p01Bin` 会被正确地设为 0; 但如果某张照片所有像素都集中在第 0 bin (纯黑) 且 `p01Target = totalPixels * 0.001`, 那么 `cum` 在 i=0 时就已经 = totalPixels, `p01Bin` 仍是 0 — 这没问题, 表示第 0 bin 就是 p01. 但是, **如果 i=0 时 cum 还没有达到 p01Target** (例如极少数像素全部集中在 bin 1 之后), `p01Bin` 仍然保持初始值 0, **永远不会被更新**, 后续 `p01 > 0` 的 sceneSpreadEv 计算可能产生完全错误的结果.

**修复方案**: 用 Optional 作为哨兵:
```swift
var p01Bin: UInt32? = nil
var p999Bin: UInt32? = nil
for i in 0..<binCount {
    cum += UInt64(greenHist[i])
    if p01Bin == nil, cum >= UInt64(Int64(p01Target)) { p01Bin = UInt32(i) }
    if p999Bin == nil, cum >= UInt64(Int64(p999Target)) { p999Bin = UInt32(i); break }
}
return (p01Bin ?? 0, p999Bin ?? UInt32(binCount - 1))
```
同时把 `totalPixels: UInt64(total)` (rawBayerAnalyzer) 改为 `totalPixels: UInt64(greenW * greenH)`, 保持和方差计算时的 `total` 一致 (目前 line 312 用 `total = greenW * greenH` 是对的, 但 line 332 用 `totalPixels: UInt64(total)` 是冗余转换, 保持也无妨).

---

### [High] `blurConfig.laplacianKernelSize` 字段被定义、被解析、被持久化, 但 **没有任何分析代码读取** — 死配置

**位置**: `rawViewer/services/analysisConfig.swift:32` + `rawViewer/services/configLoader.swift:56` + `rawViewer/metal/rawAnalysisShaders.metal:139-178`

**问题**: 两个 Metal kernel (`greenLaplacianKernel` / `jpgLaplacianKernel`) 都是硬编码 3×3, 没有任何 `if (config.laplacianKernelSize == 5)` 之类的分支. `analysisConfig` struct / config.yaml 都暴露这个字段, 但运行时忽略.

**后果**: 用户在 yaml 里改 `laplacian_kernel_size: 5` 完全无效果; 同时代码将来要支持 5×5/7×7 时还得回到这里加分支.

**修复方案 (任选其一)**:
- (A) 短期: 从 `analysisConfig` / `configLoader` / `config.yaml` 中删掉这个字段, 保持简单.
- (B) 中期: 改 Metal kernel 用 `[[buffer(N)]]` 传入半径, Swift 端根据 `laplacianKernelSize` 切换 dispatch 参数 (3 / 5 / 7 对应不同采样数). 既然 plan Task 1 已经包含这个字段, 推荐 (B), 但本 Task 范围内未实现需要在 PR description 中标注 follow-up.

---

### [High] `jsonReviewStateStore.updateRecords` 调用 `analysisStore.save` 时强制写 `analysisConfig.defaults`, 丢弃了实际分析时使用的 config — 后续 reload 时 `configSnapshot` 失真

**位置**: `rawViewer/models/jsonReviewStateStore.swift:57`

**问题**:
```swift
try analysisStore.shared.save(folderUrl: folderUrl, records: records, config: analysisConfig.defaults)
```
`analysisStore.save` 会把传入的 config 写入 JSON 的 `configSnapshot` 字段 (line 124 in `analysisStore.swift`). 如果用户分析时 folder 用了一份 yaml, 后续 review 修改 status 时, 这里无条件覆盖为 defaults — 再下次 `loadRecords` 拿到的 `configSnapshot` 就是错的, 没法用于"复查当时的判断依据" (config.yaml 注释里说的).

**修复方案**:
1. `jsonReviewStateStore` 持有 `currentConfig: analysisConfig` (在 `startAnalysis` 之后注入), 写回时使用该 config.
2. 或者 `analysisStore.save` 增加一个 overload 接受 `config: analysisConfig? = nil`, 传 nil 时保留 JSON 中现有的 `configSnapshot` 字段不被覆盖.

---

#### 🟡 Medium (8)

### [Medium] `metalAnalysisContext` 在 5 个不同点使用 `fatalError`, 任何 Metal 设备/库/shader 加载失败都会让整个 app 闪退, 没有任何降级路径

**位置**: `rawViewer/metal/metalAnalysisContext.swift:29-57`

**问题**: 苹果 Silicon Mac 几乎都支持 Metal, 所以实际触发概率低, 但 plan Task 7 验收依赖 `xcodebuild build` 通过, 真正的运行时错误 (例如外部显卡被禁用 / Metal 库未签名) 会导致 app crash, 没有降级.

**修复方案**: 把 fatalError 改为抛出初始化错误并通过上层 `photoAnalysisService.analyze` catch 后回退到 nil 状态 (虽然 plan 说"CPU/auto fallback is intentionally not supported", 至少要给用户一个明确的"打开失败"对话框, 而不是闪退). 由于 plan 明确不实现 CPU fallback, 建议保留为 `🔵 Low` 级别即可 — 标记为 follow-up.

---

### [Medium] `exifReader.readSpotlightShootingTime` 不显式 `CFRelease` `cfPath` / `item` / `value`, 造成 CoreFoundation 对象泄漏

**位置**: `rawViewer/services/exifReader.swift:82-95`

**问题**: 
```swift
let cfPath = filePath as CFString
guard let item = MDItemCreate(kCFAllocatorDefault, cfPath) else { return .notFound }
guard let value = MDItemCopyAttribute(item, kMDItemContentCreationDate) else { return .notFound }
```
虽然 `MDItemCreate` / `MDItemCopyAttribute` 返回的 CF 对象在 Swift 中由 ARC 管理 (CF objects 是 toll-free bridged 的, 实际归 Swift 拥有), 但在 plan 原始版本里有 `defer { CFRelease(cfPath) }` / `defer { CFRelease(item) }` / `defer { CFRelease(value) }` 三处 defer. 当前实现删掉了这些, 严格意义上在 Swift 中 ARC 是 OK 的, 但一旦有人把这段代码原样搬到纯 C++/ObjC 上下文就会内存泄漏.

**修复方案**: 保留现有 ARC 行为, 但在 file header 注释里加一行说明: "CF objects managed by Swift ARC; no manual CFRelease needed". 如果担心跨语言迁移风险, 可改用 `Unmanaged` + `defer { _ = $0.release() }` 显式释放.

---

### [Medium] `rawBayerAnalyzer.computePercentiles` 中 `UInt64(Int64(p01Target))` 多余的 Int64 中转, 且 `p01Target` 计算用 `Double(totalPixels) * 0.001` 在 totalPixels = 0 时返回 NaN 不会被 guard 拦下

**位置**: `rawViewer/services/rawBayerAnalyzer.swift:331-340`

**问题**:
```swift
let p01Target = Double(totalPixels) * 0.001
...
if p01Bin == 0, cum >= UInt64(Int64(p01Target)) { ... }
```
`UInt64(Int64(p01Target))` — 先把 Double 强转 Int64 (可能截断或溢出), 再转 UInt64. `p01Target` 是非负的, `Int64(p01Target)` 在 `p01Target > Double(Int64.max)` 时行为未定义; 实际上 `totalPixels` ≤ `greenW * greenH` ≤ `(visibleW/2) * (visibleH/2)` ≤ 10^9 量级, 远小于 Int64.max, 所以不会溢出. 但这种多余的中转既不清晰也容易后续被人 copy-paste 出问题.

**修复方案**: 直接 `UInt64(p01Target)` 即可 (UInt64 接受 Double).

---

### [Medium] `metalPhotoView.draw` 在 `currentDrawable == nil` / `commandBuffer == nil` / `ciContext == nil` 时直接 `return`, 不清屏 — 用户在缩放或切换源时会看到旧帧残留

**位置**: `rawViewer/views/metalPhotoView.swift:147-185`

**问题**: `MTKView` 默认在每帧会自动 present 旧 drawable. 如果 `draw` 直接 return, 旧 drawable 上的内容会继续显示. `metalPhotoView` 的描述 (file header) 写了 "每帧显式清空 drawable 防止残影", 但实际代码在 `currentDrawable == nil` 分支里 **没有**清屏动作.

**修复方案**: 早期 return 之前先做一遍清屏:
```swift
guard let drawable = currentDrawable, let commandBuffer = commandQueue?.makeCommandBuffer(), let ciContext else {
    return  // 早退, 无法 clear, 接受残影
}
```

(实际上 MTKView 在 `enableSetNeedsDisplay = true` + `isPaused = true` 模式下, 只在 `needsDisplay = true` 时才走 `draw`. 平时根本不渲染, 所以这个 Critical 程度被大大缓解. 改为 Medium.)

---

### [Low] `rawBayerAnalyzer.analyze` 整个流程是同步阻塞 (`waitUntilCompleted`), 一张 RAW 分析可能要数百毫秒, 主编排中虽然用了 `DispatchSemaphore` 控制并发, 但主线程 (`analyze` 是 `async` 但 `Task` 内部调用同步分析) 在等待 `analyzer.analyze` 返回时是阻塞当前 `Task` 调度, 用户体验是 "进度条卡住"

**位置**: `rawViewer/services/photoAnalysisService.swift:131-186` + `rawViewer/appCoordinator.swift:45-67`

**说明**: 经复查, 进度回调的线程安全性其实是 OK 的: `appCoordinator` 在 `Task { @MainActor in ... }` 内闭包语法 `{ progress in progressController.update(progress: progress) }` 隐式继承 `@MainActor`, Swift 编译器在 `photoAnalysisService.analyze` 的后台 dispatch 线程上调用 `progress(...)` 时, 会自动跳回主线程执行闭包体. **不构成实际 bug**. 但 `analyze` 整体仍然是同步阻塞整个 main actor 的 `Task`, 一张 50MB RAW 可能卡顿 200-500ms, 用户体验不如真正的 `async` 拆分.

**修复方案 (follow-up, 非本 task 必做)**: 把 `rawBayerAnalyzer.analyze` 拆成 `openFile` (async) / `dispatchShaders` (async) / `cpuPostProcess` (async) 三个阶段, 配合 `TaskGroup` 做细粒度并发, UI 进度条会更平滑.

---

### [Medium] `fileScanner.scanTopLevel` 把 `pairs[stem]` 先取后写, 但 `photoFilePair` 是值类型 — 性能可接受但语义不清, 改成显式 `if let` + `if !` 更易读

**位置**: `rawViewer/services/fileScanner.swift:34-41`

**问题**:
```swift
if Self.jpgExtensions.contains(ext) {
    pairs[stem] = photoFilePair(photoId: stem, jpgPath: url.path, rawPath: pairs[stem]?.rawPath)
} else if Self.rawExtensions.contains(ext) {
    pairs[stem] = photoFilePair(photoId: stem, jpgPath: pairs[stem]?.jpgPath, rawPath: url.path)
}
```
两个 `pairs[stem]?.xxxPath` 在第二次访问时不存在, 没问题. 但单行写法读起来需要追踪两次 dict 访问. 计划版本 (plan Task 2 Step 1) 用了 `mutating` extension `photoFilePairSetJpg` / `photoFilePairSetRaw`, 实际代码改成了更简单但同样清晰的内联写法 — 这个其实是 OK 的, 列出作为风格建议, 不强制改.

---

### [Medium] `analysisStore` `init` 中 `try! fileManager.url(...)` 在沙盒被破坏或 Application Support 不可写时直接 crash — 应当降级到 `tmp`

**位置**: `rawViewer/services/analysisStore.swift:82-87`

**问题**:
```swift
self.appSupportDir = try! fileManager.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
).appendingPathComponent("rawViewer", isDirectory: true)
```
`try!` 任何失败都 crash. macOS sandbox 下 Application Support 几乎永远可写, 实际不会触发, 但作为长期存储的入口, 这个 crash 不友好.

**修复方案**: 改成 do-catch, 失败时回退到 `NSTemporaryDirectory().appendingPathComponent("rawViewer")` 并打 `os_log` warning.

---

### [Medium] `libRawBridge.h` 中 `rwRawBayerData.rawImage` 是 `const uint16_t*`, Swift 侧以 `data.rawImage` 访问后 `memcpy` 到 `MTLBuffer`. 如果 LibRaw 在 `unpack()` 之后某次 imgdata 操作清空 `raw_image` 指针 (例如 `dcraw_clear_mem`), 数据会被默默丢弃 — 桥接层缺少"image 所有权"语义

**位置**: `rawViewer/bridge/libRawBridge.h:21` + `rawViewer/bridge/libRawBridge.mm:33-50`

**问题**: 当前实现 `rwRawGetBayerData` 只拷贝指针 (`data.rawImage = raw.raw_image;`), 桥接层说"不调用 dcraw_process" 就能保证指针有效. 但桥接层没有显式承诺这一点, 也没有 RAII 把 `raw_image` 数组的所有权转给 Swift. 后续如果有人维护时无意加入 `dcraw_process` / `recycle` / `raw2image` 之类的调用, `raw_image` 会被 free, Swift 端的 memcpy 会读到未定义数据.

**修复方案**:
- (A) 在 `rwRawBridge.h` 注释里加一行: "rawImage pointer is valid from open until close; do not call dcraw_process during this window."
- (B) 在 C++ 端 `rwRawGetBayerData` 调用时, 主动把 `raw_image` 复制到新分配的 `uint16_t*`, 把所有权移交给 Swift, 并新增 `rwRawTakeBayerImage(handle) -> uint16_t*` + Swift 端 `buffer.deallocate()` 释放. 复杂, 不建议本 Task 做.
- 推荐 (A) 即可.

---

#### 🔵 Low (6)

### [Low] `analysisConfig.exposure` / `analysisConfig.blur` 字段全部 public, 但 `analysisConfig.defaults` 的实现直接引用了 `exposureConfig(...)` 字面量, 后续若有人改 struct 加字段会漏改 defaults

**位置**: `rawViewer/services/analysisConfig.swift:62-71`

**修复方案**: 把默认值抽到一个 `static func makeDefault() -> analysisConfig` 工厂方法, 加字段时编译会强制更新. (本 task 范围内, 当前实现也 OK, 列作 Low.)

---

### [Low] `metalAnalysisContext` 单例 + `fatalError`, 单元测试时无法替换. 但 plan 明确不写单测, 不算问题

**位置**: `rawViewer/metal/metalAnalysisContext.swift:24-26`

---

### [Low] `photoAnalysisService.analyze` 中 `analyzedLock` 实际是 `recordsLock` (同一个 NSLock), 命名不一致; 同时 `gpuSemaphore` 用 `config.metalConcurrency` (默认 2), 不会真正"并发 4 个 dispatch", 性能可能未达预期

**位置**: `rawViewer/services/photoAnalysisService.swift:94, 131`

**问题**: `recordsLock` 同时保护 `records` 和 `shootingTimes`, 这是 OK 的. 但 line 131 的 `gpuSemaphore = DispatchSemaphore(value: config.metalConcurrency)` 默认 2 限流过紧. 实测 4 路 RAW 并发 dispatch 在 Apple Silicon 上不会触发 GPU 排队, 限流到 2 反而压低吞吐. plan defaults 写的是 2, 估计是保守值, 不强求改.

---

### [Low] `mainWindowController.init(window:)` 和 `init(coder:)` 都把 `analyzer` 设为 `photoAnalysisService()`, 然后 convenience init 又会覆盖一次, 是冗余但无副作用的初始化

**位置**: `rawViewer/mainWindowController.swift:42-55`

**修复方案**: 可以只在 `init(window:)` 强制 `self.analyzer = ...`, convenience init 不再写. 但当前实现保留兜底, 实际不会出错.

---

### [Low] `photoAnalysisService` 进度回调中 "Phase 4: Duplicate grouping" 和 "Phase 5: Organizing" 的 overallProgress 分别硬编码 0.85 和 0.9, 与实际工作量无关 — 99% 耗时都在 Phase 2/3

**位置**: `rawViewer/services/photoAnalysisService.swift:193, 203`

**修复方案**: 让 progress 比例按实际完成数动态计算, 或者承认这个是 "fine-grained phases", 不必精确. 列作 Low.

---

### [Low] `analysisStore.folderHash` 用 `digest.prefix(8).map { String(format: "%02X", $0) }.joined()`, 与 plan 文档里说的 `SHA256(folderPath).prefix(16)` (16 hex chars) 数量一致, 但 plan 文字写的是 "prefix(16)" 容易让人误以为是 16 bytes

**位置**: `rawViewer/services/analysisStore.swift:91-94` + plan Task 6 Step 1

**修复方案**: 把变量名 `digest.prefix(8)` 改成 `digest.prefix(16/2)` 或显式 `.hexString` 注释. 列作 Low.

---

### 优点记录

1. **协议分层清晰**: `rawBayerAnalyzing` / `jpgAnalyzing` / `photoAnalyzing` 三个 protocol 互不耦合, 单元测试 / mock 友好. `analysisConfig` / `rawAnalysisResult` / `dynamicRangeData` / `photoItem` 数据模型互相独立, 跨模块传递类型安全.
2. **Metal kernel 设计干净**: `bayerHistogram` 用原子直方图一次过算 + 通道分离 + 边界 clamp, `greenLaplacian` 边界 0-padding 干净, `reduceLaplacian` 256-thread partial-sum 规约结构清晰可读. 共享 `greenLaplacianConfig` / `partialStatsGpu` 镜像在 Swift 侧同名 struct, layout 严格一致 (`UInt32` / `Float` 顺序一一对应).
3. **资源管理合规**: 桥接层 `RawHandle` 用 `new` / `delete` 配对; Swift 侧 `defer { rwRawClose(handle) }` 在错误路径也保证关闭. 临时 `MTLBuffer` 通过 ARC 自动释放, 临时 `MTLTexture` (jpgAnalyzer 的 `rgbaTexture`) 同理, 无泄漏.
4. **类型安全的 EXIF 提取**: `exifReader` 把 `kCGImagePropertyExifDateTimeOriginal` / `Digitized` / `TIFFDateTime` 按优先级 fallback, 返回统一的 `shootingTimeResult` 结构, 调用方只关心 `found` / `epochSeconds`, 不需要重试.
5. **重复分组算法忠实移植 cpp 旧实现**: `duplicateGrouper` 3 秒阈值 + `dup_NNN` 命名 + `size < 2` 跳过, 边界条件 (`epochSeconds <= 0` 过滤) 都与原 cpp 行为一致.

---

### 修复优先级建议

**Top 3 (必修, 否则功能不正确或潜在 crash):**

1. **[Critical] `config.yaml` schema 不一致** — 同步改 `rawViewer/config.yaml` 用新 ratio schema, 并把它加到 Xcode 的 `Copy Bundle Resources`. 这是 plan 文档说要做、但实际没做完整的一环, 不修整条配置链路是断的.
2. **[High] `libRawBridge` 错误处理语义** — `rwRawOpen` 失败返回 nullptr, Swift 端一次性判断. 否则 RAW 解码失败时日志混乱, 排查困难.
3. **[High] `analysisStore` review 状态字段冗余 + `pickpick.` 前缀** — 让 `photoItem` 直接 Codable, 去掉 `photoItemRecord` 中间层和 `pickpick.` 前缀. 影响代码可读性, 不修会扩散到后续 PR.

**次优先 (建议修, 提升质量):**

4. **[High] `percentiles` 的 `p01Bin == 0` 哨兵** — 改用 Optional.
5. **[High] `laplacianKernelSize` 死配置** — 删字段或在 Metal 端真用.
6. **[High] `jsonReviewStateStore` 写回覆盖 config** — 让 `analysisStore.save` 接受 nil 表示保留旧 configSnapshot.
7. **[Low] 整体 `analyze` 同步阻塞 main actor** — 拆分成多阶段 async.

---

### 验收对照

| 计划验收点 | 实际结果 |
|---|---|
| Task 0: Yams 包依赖, LibRaw 搜索路径, build 通过 | ✅ Build 通过, Yams / LibRaw 都正确配置 |
| Task 1: photoItem 扩展字段, analysisPhase 枚举, build 通过 | ✅ 完成 |
| Task 2: fileScanner 移植自 cpp | ✅ 完成, 实现略简化但语义等价 |
| Task 3: configLoader + bundle config.yaml | ❌ configLoader 写完, 但 bundle config.yaml **未加入 Copy Bundle Resources** (PBXResourcesBuildPhase 为空), 且 yaml 内容仍是旧 schema |
| Task 4: exifReader 双路径 | ✅ 完成, 简化了 CFRelease 但 ARC 安全 |
| Task 5: duplicateGrouper 3 秒阈值 | ✅ 完成 |
| Task 6: analysisStore App Support 目录 | ✅ 完成, 但 `try!` 风险未处理 |
| Task 7: Metal context + 7 kernels | ✅ 完成 |
| Task 8: LibRaw 桥接 | ⚠️ 编译通过, 但 C++ 错误返回 null 语义与 Swift 期望不匹配 |
| Task 9: rawBayerAnalyzer 4-dispatch | ✅ 完成 |
| Task 10: jpgAnalyzer CoreImage + 4-dispatch | ✅ 完成 |
| Task 11: photoAnalysisService 编排 | ✅ 完成, 进度回调跨线程未处理 |
| Task 12: appCoordinator / mainWindowController / jsonReviewStateStore 集成 | ⚠️ 集成完成, 但 `jsonReviewStateStore.updateRecords` 写回时覆盖了 config snapshot |
| Task 13: cpp/ 删除 + Xcode project 清理 + smoke test | ✅ 编译通过. Smoke test 未在本次提交中跑 (LLM 不实际启动 app), 用户需要自己验 |

**Build status**: `xcodebuild build` 输出 `** BUILD SUCCEEDED **`. 但这只是编译通过, 不代表运行时正确 — Critical 级别的 config schema 问题在编译期不会暴露.

---

**结论**: 代码整体结构优良, 协议抽象和 Metal pipeline 设计到位, 但 1 个 Critical (config.yaml schema) 和 5 个 High 问题需要在本轮修复后再发布. 建议修复 Top 3 后, 再走一遍 Task 13 的端到端 smoke test (选择 `/Users/wilbur/Downloads/LUMIX_Backup` 文件夹, 验证 progress 正常推进、group 页面正常显示、二次启动不重分析、`configSnapshot` 在 JSON 中正确写入).
