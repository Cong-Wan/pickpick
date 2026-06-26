# pickpick 健壮性修复 + 死代码清理 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 完成代码审查报告（`docs/codeReview/260625_full_module_review.md`）中**剩余的 6 个 Medium + 10 个 Low**（Top 3 High 已在上一轮修复）。分两阶段：阶段 A 修 4 个健壮性问题（改行为、低风险），阶段 B 清理 10 项死代码/杂项（无行为变更或近乎无）。

**架构：** 11 个任务，按"改动文件"聚类以避免冲突。阶段 A（Task 1–4）是健壮性修复；阶段 B（Task 5–11）是清理。唯一跨任务文件冲突是 `rawAnalysisShaders.metal`（Task 4 与 Task 5 都改），故 Task 5 依赖 Task 4。所有任务串行执行（共享同一 Xcode 工程，`xcodebuild` 不能并行）。

**技术栈：** Swift 5.9+ / AppKit / Metal / Objective-C++（Metal shader）。Xcode 工程 `rawViewer.xcodeproj`，scheme = `pickpick`。

**前置状态说明：** 本计划基于"Top 3 High 修复已完成"的当前磁盘状态（工作区有未提交改动）。文件版本号延续当前值递增。

**日志约定（精简模式）：** 新增日志一律走 `appDebugLogger`（`--debug` 启动时输出）或 `appFileLogger`（写本地文件）。`appDebugLogger.isEnabled` 的解析逻辑已在 `services/appDebugLogger.swift` 实现，本计划复用。

**构建/运行命令（全文统一）：**

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期最后一行：** BUILD SUCCEEDED **
```

---

## 文件结构与任务归属

| 任务 | 类型 | 涉及文件 | 依赖 |
|------|------|----------|------|
| **Task 1** | A 健壮性 | `services/configLoader.swift` | — |
| **Task 2** | A 健壮性 | `views/metalPhotoView.swift`（捏合+删枚举+精简重绘） | — |
| **Task 3** | A 健壮性 | `services/exifReader.swift` | — |
| **Task 4** | A 健壮性 | `metal/rawAnalysisShaders.metal`、`services/rawBayerAnalyzer.swift`、`services/jpgAnalyzer.swift`（删 exposureBuffer 白算 + p999Code 改名） | — |
| **Task 5** | B 清理 | `metal/metalAnalysisContext.swift`、`metal/rawAnalysisShaders.metal`（删旧 reduce pipeline） | **Task 4**（同 shader 文件） |
| **Task 6** | B 清理 | `services/photoAnalysisService.swift`（删 runJpgFallback） | — |
| **Task 7** | B 清理 | `services/photoImageService.swift`、`models/photoImageCache.swift`（删 loadImage/scaleToThumbnail/photoImageKind） | — |
| **Task 8** | B 清理 | `groupGrid/groupGridViewController.swift`、`groupGrid/groupGridViewModel.swift`（删 route/previewPhotos） | — |
| **Task 9** | B 清理 | `models/photoModels.swift`（删 displayUrl/displayAvailability） | — |
| **Task 10** | B 清理 | `services/analysisScoring.swift`、`services/appDebugLogger.swift`（删 usable 死变量 + isEnabled 缓存） | — |
| **Task 11** | B 清理 | `views/groupCollectionViewItem.swift`、`views/groupCardView.swift`（复用重构） | — |

---

## 阶段 A — 健壮性修复

---

### Task 1: configLoader YAML 行内注释剥离 + 解析失败反馈

**目标：** 让自研 YAML 解析器能正确剥离行内 `#` 注释（如 `overexpose_pixel_threshold: 0.975  # 高光`），避免被解析成字符串后静默回退默认值；解析失败的值在 `--debug` 下输出反馈。

**涉及的文件：**

- `rawViewer/services/configLoader.swift` — 当前 v1.8，本任务 → v1.9

---

#### Step 1 — 实现

**1.1 在 `parseValue(_:)` 之前新增行内注释剥离函数。** 定位 `private func parseValue(_ raw: String) -> Any {` 这一行，在它**前面**插入：

```swift
    /// 剥离 YAML 行内注释：首个引号外的 "#"（井号前需为空白或行首）之后视为注释。
    /// 当前 config.yaml 的值均为简单标量，此实现足够；引号内的 # 不剥离。
    private func stripInlineComment(_ value: String) -> String {
        var inQuotes = false
        let chars = Array(value)
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes {
                if i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                    return String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return value
    }
```

**1.2 修改 `parseValue(_:)`，在 fallback 返回前加 debug 反馈。** 定位整个 `parseValue` 函数，替换为：

```swift
    private func parseValue(_ raw: String) -> Any {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        if let d = Double(raw) { return d }
        if let i = Int(raw) { return i }
        if raw == "true" { return true }
        if raw == "false" { return false }
        appDebugLogger.log("config value parsed as string (fallback): \(raw)")
        return raw
    }
```

> 说明：`appDebugLogger` 是同模块 public enum，无需额外 import。仅当值无法识别为数值/布尔/带引号字符串时才记一条 debug 日志，并原样返回字符串（保持原有"回退"行为，不破坏既有解析）。

**1.3 在 `parseSimpleYaml(_:)` 里对每行剥离注释。** 定位 `parseSimpleYaml` 函数体内这一段：

```swift
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if let colonIdx = trimmed.firstIndex(of: ":") {
```

替换为（在 `let trimmed = ...` 之后、`if let colonIdx` 之前插入一行注释剥离）：

```swift
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let lineNoComment = stripInlineComment(trimmed)
            if lineNoComment.isEmpty { continue }

            if let colonIdx = lineNoComment.firstIndex(of: ":") {
                let key = lineNoComment[..<colonIdx].trimmingCharacters(in: .whitespaces)
                let afterColon = lineNoComment[lineNoComment.index(after: colonIdx)...]
                    .trimmingCharacters(in: .whitespaces)
```

> 注意：原代码 `if let colonIdx` 块内用的是 `trimmed`，现在改用 `lineNoComment`。请确保块内 `key` 和 `afterColon` 的取值都从 `lineNoComment` 而非 `trimmed` 取（上面已给出）。块内其余逻辑（`if afterColon.isEmpty { section } else { currentDict[key] = parseValue(afterColon) }`）不变。

**1.4 更新文件头**：版本号 `1.8` → `1.9`，Description 末尾追加：`v1.9 parseSimpleYaml 剥离行内 # 注释，parseValue fallback 时输出 --debug 日志`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
```

构建通过即可（YAML 解析逻辑改动小，行为正确性可由后续手动加载 config 验证）。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`configLoader` 含 `stripInlineComment` 函数；`parseSimpleYaml` 用 `lineNoComment` 取键值；`parseValue` fallback 处有 debug 日志。

---

### Task 2: metalPhotoView 捏合缩放累积 + 删死枚举 + 精简重绘

**目标：** (a) 修复捏合缩放手势——`NSMagnificationGestureRecognizer.magnification` 是逐帧增量，改为累积到 `userZoom`，使长按捏合能真正连续放大；(b) 删除无调用方的 `photoSource`/`photoLoadError` 死枚举；(c) 精简 `requestRedrawIfNeeded` 的双触发。

**涉及的文件：**

- `rawViewer/views/metalPhotoView.swift` — 当前 v3.5，本任务 → v3.6

---

#### Step 1 — 实现

**2.1 修改 `handlePinch(_:)` 为累积缩放。** 定位整个 `handlePinch` 函数（当前从 `@objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {` 到对应 `}`），替换为：

```swift
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .changed:
            // magnification 是相对上一帧的增量，直接累积乘到 userZoom，长按捏合可连续放大/缩小。
            userZoom = max(minZoom, min(maxZoom, userZoom * (1.0 + Double(gesture.magnification))))
            needsDisplay = true
            onZoomChanged?(userZoom)
        case .ended:
            onZoomChanged?(userZoom)
        default:
            break
        }
    }
```

**2.2 删除不再使用的 `pinchStartZoom` / `pinchStartMagnification` 属性。** 定位这两行（在 `zoomStep` 之后）：

```swift
    private var pinchStartZoom: Double = 1.0
    private var pinchStartMagnification: Double = 0.0
```

整段删除（2.1 改累积后这两个属性不再被任何代码引用）。

**2.3 删除死枚举 `photoLoadError` 和 `photoSource`。** 定位文件顶部这两个枚举（紧跟 import 之后）：

```swift
public enum photoLoadError: Error, Equatable {
    case cannotLoadImage
    case missingDrawable
}

public enum photoSource {
    case jpg
    case raw
}
```

整段删除（经全项目 grep 确认零调用方；`showError` 收的是 `String`，与这两个枚举无关）。

**2.4 精简 `requestRedrawIfNeeded` 的双触发。** 定位该函数，当前为：

```swift
    private func requestRedrawIfNeeded() {
        guard currentImage != nil || isShowingError else { return }
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImage != nil || self.isShowingError else { return }
            self.needsDisplay = true
        }
    }
```

替换为（保留带守卫的 async 触发，去掉无守卫的同步裸触发）：

```swift
    private func requestRedrawIfNeeded() {
        // 保留 async 触发（带守卫）：drawable 在 viewDidMoveToWindow/layout 时机可能未就绪，
        // 延后到下一 runloop 重绘更稳；去掉原先无守卫的同步裸触发，避免双触发。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImage != nil || self.isShowingError else { return }
            self.needsDisplay = true
        }
    }
```

> ⚠️ 注意：metalPhotoView 历史上多次修复"详情页空白"问题。本改动只去掉重复的同步触发，保留 async 触发（这是更稳的那次）。若验证发现详情页空白，回退本步即可（其它步骤不受影响）。

**2.5 更新文件头**：版本号 `3.5` → `3.6`，Description 末尾追加：`v3.6 捏合缩放改累积乘、删除无用的 photoSource/photoLoadError 枚举、精简 requestRedrawIfNeeded 双触发`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "pinchStartZoom\|pinchStartMagnification\|photoLoadError\|photoSource" rawViewer/views/metalPhotoView.swift
# 预期：无输出（已全部删除）
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`metalPhotoView.swift` 不再含 `pinchStartZoom`/`pinchStartMagnification`/`photoLoadError`/`photoSource`；`handlePinch` 为累积乘逻辑。

---

### Task 3: exifReader 用免费桥接替代 unsafeBitCast

**目标：** 消除 `unsafeBitCast` 转换 CFDate 的隐患，改用 CFDate↔Date 免费桥接（`value as? Date`），更安全且等价。

**涉及的文件：**

- `rawViewer/services/exifReader.swift` — 当前 v1.2，本任务 → v1.3

---

#### Step 1 — 实现

定位 `readSpotlightShootingTime(_:source:)` 函数体内这段：

```swift
        guard CFGetTypeID(value) == CFDateGetTypeID() else {
            return .notFound
        }
        let date = unsafeBitCast(value, to: CFDate.self)
        let absolute = CFDateGetAbsoluteTime(date)
        let seconds = Int64((absolute + kCFAbsoluteTimeIntervalSince1970).rounded())
```

替换为：

```swift
        guard CFGetTypeID(value) == CFDateGetTypeID() else {
            return .notFound
        }
        // CFDate 与 Date 是免费桥接（toll-free bridged），直接 as? Date 即可，
        // 无需 unsafeBitCast / CFDateGetAbsoluteTime / 手动加 kCFAbsoluteTimeIntervalSince1970。
        guard let date = value as? Date else {
            return .notFound
        }
        let seconds = Int64(date.timeIntervalSince1970.rounded())
```

更新文件头：版本号 `1.2` → `1.3`，Description 末尾追加：`v1.3 readSpotlightShootingTime 用 CFDate↔Date 免费桥接替代 unsafeBitCast`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -n "unsafeBitCast\|CFDateGetAbsoluteTime\|kCFAbsoluteTimeIntervalSince1970" rawViewer/services/exifReader.swift
# 预期：无输出
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`exifReader.swift` 不再含 `unsafeBitCast`/`CFDateGetAbsoluteTime`/`kCFAbsoluteTimeIntervalSince1970`。

---

### Task 4: 删曝光直方图 exposureBuffer 白算 + p999Code 改名

**目标：** 删除全局曝光计数（`exposureBuffer`/`exposureCounts`）这条"GPU 算了但 CPU 从不读回"的白算链路（含 Metal kernel 参数、2 个 config struct 字段、2 处 absOver/absUnder 计算、2 处 setBuffer）。同时把误导性变量名 `p999Code`（实际取 `p99Norm`）改为 `p99Code`。

> **说明（为何只删 exposureBuffer、不动 4 通道直方图）：** 审查报告指出 RAW 全局直方图算了 4 通道但只用绿色通道。本任务只删除**完全白算**的曝光计数（exposureBuffer 整条链，CPU 零读取，经 grep 确认）。4 通道直方图保留不动——简化为单通道会改变评分所依赖的绿色直方图统计样本集，有改变分析结果的风险，属 YAGNI 范畴，不在此处理。

**涉及的文件：**

- `rawViewer/metal/rawAnalysisShaders.metal` — `BayerHistConfig`/`JpgHistConfig` 删字段、`bayerHistogramKernel`/`jpgHistogramKernel` 删 exposureCounts 参数与写入
- `rawViewer/services/rawBayerAnalyzer.swift` — 当前 v1.6 → v1.7；删 `bayerHistConfig.overThreshold/underThreshold`、`absOver/absUnder`、`exposureBuffer` 分配/memset/setBuffer；`p999Code`→`p99Code`
- `rawViewer/services/jpgAnalyzer.swift` — 当前 v1.7 → v1.8；同上对应改动

---

#### Step 1 — 实现

##### 4.1 修改 `metal/rawAnalysisShaders.metal`

**4.1.1 删 `BayerHistConfig` 的两个阈值字段。** 定位：

```cpp
struct BayerHistConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint visibleWidth; uint visibleHeight;
    uint binCount; uint blackLevel; uint whiteLevel;
    uint overThreshold; uint underThreshold;
};
```

把最后一行 `uint overThreshold; uint underThreshold;` 删除（即 struct 变为不含这两个字段）。

**4.1.2 删 `bayerHistogramKernel` 的 exposureCounts 参数和两行写入。** 定位该 kernel 签名与结尾。当前：

```cpp
kernel void bayerHistogramKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
    constant BayerHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
```

删除 `device atomic_uint* exposureCounts [[buffer(2)]],` 这一行。

再定位 kernel 末尾这两行：

```cpp
    if (rawValue >= config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 0], 1u, memory_order_relaxed);
    if (rawValue <= config.underThreshold && rawValue > 0) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 1], 1u, memory_order_relaxed);
}
```

删除这两行 `if (... exposureCounts ...)`，保留 kernel 的结束 `}`。

**4.1.3 删 `JpgHistConfig` 的两个阈值字段。** 定位：

```cpp
struct JpgHistConfig { uint totalPixels; uint overThreshold; uint underThreshold; };
```

替换为：

```cpp
struct JpgHistConfig { uint totalPixels; };
```

**4.1.4 删 `jpgHistogramKernel` 的 exposureCounts 参数和两行写入。** 定位该 kernel 签名：

```cpp
kernel void jpgHistogramKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
    constant JpgHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
```

删除 `device atomic_uint* exposureCounts [[buffer(2)]],` 这一行。

再定位 kernel 末尾两行：

```cpp
    if (gray > config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    if (gray < config.underThreshold) atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
}
```

删除这两行 `if (... exposureCounts ...)`，保留结束 `}`。

##### 4.2 修改 `services/rawBayerAnalyzer.swift`

**4.2.1 删 `bayerHistConfig` struct 的两个阈值字段。** 定位：

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
    var overThreshold: UInt32
    var underThreshold: UInt32
}
```

删除最后两行 `var overThreshold: UInt32` 和 `var underThreshold: UInt32`。

**4.2.2 删 `absOver`/`absUnder` 计算。** 定位：

```swift
        let absOver = UInt32(black) + UInt32(Double(white - black) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(black) + UInt32(Double(white - black) * config.exposure.underexposePixelThreshold)
```

整段删除（2 行）。

**4.2.3 删 `exposureBuffer` 分配与 memset。** 定位：

```swift
        guard let exposureBuffer = context.device.makeBuffer(
            length: 8 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 8 * MemoryLayout<UInt32>.size)
```

整段删除。

**4.2.4 删 `histConfig` 初始化里的两个阈值字段。** 定位 `var histConfig = bayerHistConfig(` 这个调用：

```swift
        var histConfig = bayerHistConfig(
            rawWidth: UInt32(rawW), rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX), visibleOffsetY: UInt32(data.visibleOffsetY),
            visibleWidth: UInt32(visibleW), visibleHeight: UInt32(visibleH),
            binCount: binCount, blackLevel: UInt32(black), whiteLevel: UInt32(white),
            overThreshold: absOver, underThreshold: absUnder
        )
```

把最后一行 `overThreshold: absOver, underThreshold: absUnder` 删除，使调用匹配新的 struct（无这两个字段）。

**4.2.5 删 bayerHistogramKernel dispatch 里的 `setBuffer(exposureBuffer...)`。** 定位第一个 dispatch（`context.bayerHistogramPipeline`）块内：

```swift
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            encoder.setBytes(&histConfig, length: MemoryLayout<bayerHistConfig>.size, index: 3)
```

删除 `encoder.setBuffer(exposureBuffer, offset: 0, index: 2)` 这一行。（kernel 不再有 buffer(2)，但 buffer index 0/1/3 仍正确——Metal 允许 buffer index 不连续。）

**4.2.6 改名 `p999Code` → `p99Code`。** 定位动态范围计算处：

```swift
        let p01Code = globalFeatures.p01Norm * range
        let p999Code = globalFeatures.p99Norm * range
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
```

把三处 `p999Code` 改为 `p99Code`（变量名修正——它取的是 `p99Norm`，原命名误导）：

```swift
        let p01Code = globalFeatures.p01Norm * range
        let p99Code = globalFeatures.p99Norm * range
        let sceneSpreadEv = p01Code > 0 ? log2(p99Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
```

更新文件头：版本号 `1.6` → `1.7`，Description 末尾追加：`v1.7 删除全局曝光计数 exposureBuffer 白算链、p999Code 改名为 p99Code`

##### 4.3 修改 `services/jpgAnalyzer.swift`

**4.3.1 删 `jpgHistConfig` struct 的两个阈值字段。** 定位：

```swift
struct jpgHistConfig {
    var totalPixels: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}
```

删除 `var overThreshold: UInt32` 和 `var underThreshold: UInt32`。

**4.3.2 删 `exposureBuffer` 分配与 memset。** 定位：

```swift
        guard let exposureBuffer = context.device.makeBuffer(length: 2 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)
```

整段删除（2 行）。

**4.3.3 删 `absOver`/`absUnder` 计算。** 定位：

```swift
        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)
```

整段删除。

**4.3.4 删 jpgHistogramKernel dispatch 里的 `setBuffer(exposureBuffer...)`。** 定位 jpgHistogram dispatch 块内：

```swift
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            var histConfig = jpgHistConfig(totalPixels: UInt32(totalPixels), overThreshold: absOver, underThreshold: absUnder)
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
```

把 `encoder.setBuffer(exposureBuffer, offset: 0, index: 2)` 删除，并把 `var histConfig = jpgHistConfig(...)` 那行改为（去掉两个阈值参数，匹配新 struct）：

```swift
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            var histConfig = jpgHistConfig(totalPixels: UInt32(totalPixels))
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
```

**4.3.5 改名 `p999Code` → `p99Code`。** 定位动态范围计算处：

```swift
        let p01Code = Double(globalFeatures.p01Norm) * range
        let p999Code = Double(globalFeatures.p99Norm) * range
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
```

把三处 `p999Code` 改为 `p99Code`。

更新文件头：版本号 `1.7` → `1.8`，Description 末尾追加：`v1.8 删除全局曝光计数 exposureBuffer 白算链、p999Code 改名为 p99Code`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "exposureBuffer\|exposureCounts\|absOver\|absUnder\|p999Code" rawViewer/services/rawBayerAnalyzer.swift rawViewer/services/jpgAnalyzer.swift rawViewer/metal/rawAnalysisShaders.metal
# 预期：无输出（所有白算链路与旧命名已清除）
```

> 关键：Metal kernel 删了 `buffer(2)` 参数后，Swift 端不再 `setBuffer(..., index: 2)`，但 `buffer(3)` 的 config 仍按 index 3 传入——Metal 允许 buffer index 不连续，这是安全的。构建通过即证明 struct 字段与调用一致。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；三个文件不再含 `exposureBuffer`/`exposureCounts`/`absOver`/`absUnder`/`p999Code`。

---

## 阶段 B — 死代码与杂项清理

---

### Task 5: 删除旧 Metal reduce pipeline（依赖 Task 4）

**目标：** 删除过渡期保留、现已无引用的旧全局 Laplacian 规约 kernel 及其 pipeline（审查报告 Low 2）。`reduceLaplacianPerTileKernel`（每格规约）是现行实现，不受影响。

**涉及的文件：**

- `rawViewer/metal/metalAnalysisContext.swift` — 当前 v1.3 → v1.4；删 `reducePipeline` 属性与构造
- `rawViewer/metal/rawAnalysisShaders.metal` — 删 `PartialStats` struct 与 `reduceLaplacianKernel`

> ⚠️ **依赖 Task 4**：本任务与 Task 4 都改 `rawAnalysisShaders.metal`，必须 Task 4 完成后再执行，避免 anchor 冲突。

---

#### Step 1 — 实现

**5.1 修改 `metal/metalAnalysisContext.swift`**

定位属性声明：

```swift
    public let reducePipeline: MTLComputePipelineState
```

删除该行。

定位构造里的：

```swift
        self.reducePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
```

删除该行。

更新文件头：版本号 `1.3` → `1.4`，Description 末尾追加：`v1.4 删除过渡期保留的旧全局 reducePipeline（reduceLaplacianKernel），现由 reduceLaplacianPerTilePipeline 取代`

**5.2 修改 `metal/rawAnalysisShaders.metal`**

定位旧 reduce 注释块、`PartialStats` struct、`reduceLaplacianKernel` 整个 kernel（这三者是连续的一段）：

```cpp
// 旧全局 reduce 过渡期保留，直到 RAW/JPG analyzer 都不再引用 reducePipeline
struct PartialStats { float sum; float sumSq; float minVal; float maxVal; };

kernel void reduceLaplacianKernel(
    ...
    }
}
```

整段删除（从 `// 旧全局 reduce 过渡期保留` 注释，到 `reduceLaplacianKernel` 的结束 `}`）。**注意保留其后的 `reduceLaplacianPerTileKernel`（每格规约，现行实现）**——只删旧的全局 `reduceLaplacianKernel` 和 `PartialStats`。

> 实现者请通读删除区域，确认删除的是 `PartialStats` + `reduceLaplacianKernel`，而不是 `PerTileStats` + `reduceLaplacianPerTileKernel`。两者名称相似，勿误删。

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "reducePipeline\|reduceLaplacianKernel\|PartialStats" rawViewer/metal/ rawViewer/services/
# 预期：无输出（reduceLaplacianPerTileKernel / perTileStats 仍在，不受影响）
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；不再含 `reducePipeline`/`reduceLaplacianKernel`/`PartialStats`；`reduceLaplacianPerTileKernel`/`PerTileStats` 仍在。

---

### Task 6: 删除 photoAnalysisService.runJpgFallback

**目标：** 删除无调用方的私有死方法 `runJpgFallback`（其逻辑已由 `makeJpgFallbackRunner` 闭包承担，审查报告 Low 1）。

**涉及的文件：**

- `rawViewer/services/photoAnalysisService.swift` — 当前 v1.7（T2 已改）→ v1.8

---

#### Step 1 — 实现

定位私有方法（`makeJpgFallbackRunner` 之后）：

```swift
    private func runJpgFallback(pair: photoFilePair, config: analysisConfig) -> rawAnalysisResult {
        guard pair.hasJpg, let jpgPath = pair.jpgPath else {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "failed",
                dynamicRange: nil,
                blackLevel: 0,
                whiteLevel: 0,
                analysisSource: "jpg_failed"
            )
        }
        do {
            let result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
            return rawAnalysisResult(
                isBlurry: result.isBlurry,
                exposureStatus: result.exposureStatus,
                dynamicRange: result.dynamicRange,
                blackLevel: result.blackLevel,
                whiteLevel: result.whiteLevel,
                analysisSource: "jpg_fallback"
            )
        } catch {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "failed",
                dynamicRange: nil,
                blackLevel: 0,
                whiteLevel: 0,
                analysisSource: "jpg_failed"
            )
        }
    }
```

整段删除（该方法经 grep 确认零调用方，是 `makeJpgFallbackRunner` 的重复逻辑）。

更新文件头：版本号 `1.7` → `1.8`，Description 末尾追加：`v1.8 删除无调用方的 runJpgFallback 死方法`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "runJpgFallback" rawViewer/
# 预期：无输出
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；不再含 `runJpgFallback`。

---

### Task 7: 删除图片加载死代码（loadImage/scaleToThumbnail/photoImageKind）

**目标：** 删除无调用方的 `photoImageService.loadImage(for:kind:)` 及其私有 helper `scaleToThumbnail`，以及仅被它使用的 `photoImageKind` 枚举（审查报告 Low 3）。实际加载走 `loadThumbnail`（返回 NSImage）和 `preloadDisplayPair`。

**涉及的文件：**

- `rawViewer/services/photoImageService.swift` — 当前 v2.0 → v2.1
- `rawViewer/models/photoImageCache.swift` — 当前 v1.2 → v1.3

---

#### Step 1 — 实现

**7.1 修改 `services/photoImageService.swift`**

定位并删除整个 `loadImage(for:kind:)` 方法：

```swift
    /// 加载指定类型的图像（displayJpg/displayRaw 由 displayService 处理；thumbnail 向后兼容走 display + 缩放）
    public func loadImage(for photo: photoItem, kind: photoImageKind) async -> photoImageResult {
        switch kind {
        case .thumbnail(let width, let height):
            let result = await displayService.loadDisplayJpg(for: photo)
            guard case .image(let image) = result else { return result }
            return scaleToThumbnail(image: image, width: width, height: height)
        case .displayJpg:
            return await displayService.loadDisplayJpg(for: photo)
        case .displayRaw:
            return await displayService.loadDisplayRaw(for: photo)
        }
    }
```

定位并删除整个私有 helper `scaleToThumbnail`：

```swift
    private func scaleToThumbnail(image: CIImage, width: Int, height: Int) -> photoImageResult {
        ...
    }
```

更新文件头：版本号 `2.0` → `2.1`，Description 里把"对外保持 loadImage/preloadDisplayPair 接口不变，新增 loadThumbnail 返回 NSImage"改为"loadImage/scaleToThumbnail 已删除（零调用方），对外保留 loadThumbnail + preloadDisplayPair"。

**7.2 修改 `models/photoImageCache.swift`**

定位并删除整个 `photoImageKind` 枚举：

```swift
nonisolated public enum photoImageKind: Hashable, Sendable {
    case thumbnail(width: Int, height: Int)
    case displayJpg
    case displayRaw
}
```

> 确认：`photoImageKind` 仅被 `loadImage` 的参数类型引用，删 `loadImage` 后它零引用。

更新文件头：版本号 `1.2` → `1.3`，Description 末尾追加：`v1.3 删除无引用的 photoImageKind 枚举（随 loadImage 一并清理）`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "loadImage\|scaleToThumbnail\|photoImageKind" rawViewer/
# 预期：无输出（仅文件头 Description 注释里可能残留文字描述，代码符号应全部清除）
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；代码符号 `loadImage`/`scaleToThumbnail`/`photoImageKind` 全部清除。

---

### Task 8: 删除 groupGrid 死代码（route / previewPhotos）

**目标：** 删除无调用方的顶层 `route(for:)` 函数和 `groupGridViewModel.route(for:)`/`previewPhotos(for:)`（审查报告 Low 4）。路由实际由 `appCoordinator.navigateToGroup` 决定。

**涉及的文件：**

- `rawViewer/groupGrid/groupGridViewController.swift` — 当前 v4.3 → v4.4；删顶层 `route(for:)` 和 `visibleGroupCards` 保留
- `rawViewer/groupGrid/groupGridViewModel.swift` — 当前 v1.2 → v1.3；删 `route(for:)` 和 `previewPhotos(for:)`

---

#### Step 1 — 实现

**8.1 修改 `groupGrid/groupGridViewController.swift`**

定位并删除顶层函数（文件级，非类内）：

```swift
public func route(for group: photoGroup) -> groupRoute {
    group.kind.isDuplicate ? .duplicateCompare : .browser
}
```

> 注意：`visibleGroupCards(from:)` 顶层函数**保留**（被 `groupGridViewModel` 调用）。只删 `route(for:)`。

更新文件头：版本号 `4.3` → `4.4`，Description 末尾追加：`v4.4 删除无调用方的顶层 route(for:)`

**8.2 修改 `groupGrid/groupGridViewModel.swift`**

定位并删除这两个方法：

```swift
    public func previewPhotos(for group: photoGroup) -> [photoItem] {
        Array(group.photos.prefix(5))
    }

    public func route(for group: photoGroup) -> groupRoute {
        group.kind.isDuplicate ? .duplicateCompare : .browser
    }
```

> 注意：`groupRoute` 枚举类型本身仍在使用（其它地方），不删；只删这两个方法。

更新文件头：版本号 `1.2` → `1.3`，Description 末尾追加：`v1.3 删除无调用方的 route(for:)/previewPhotos(for:)`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "\.route(\|previewPhotos(for" rawViewer/
# 预期：无输出（groupCollectionViewItem 里的局部变量 let previewPhotos 不算，它是 Array(group.photos.prefix(5))）
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`route(for:)`/`previewPhotos(for:)` 方法定义全部清除（局部变量 `previewPhotos` 保留无碍）。

---

### Task 9: 删除 photoModels 死代码（displayUrl / displayAvailability）

**目标：** 删除无调用方的 `displayUrl(for:source:)` 函数和 `displayAvailability` 枚举（审查报告 Low 5）。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 当前 v1.11 → v1.12

---

#### Step 1 — 实现

定位并删除这两个定义（位于文件末尾）：

```swift
public enum displayAvailability: Equatable {
    case available(URL)
    case unavailable
}

public func displayUrl(for photo: photoItem, source: displaySource) -> displayAvailability {
    switch source {
    case .jpg:
        guard photo.hasExistingJpgFile() else { return .unavailable }
        return .available(URL(fileURLWithPath: photo.jpgPath))
    case .raw:
        guard photo.hasExistingRawFile(), let rawPath = photo.rawPath else { return .unavailable }
        return .available(URL(fileURLWithPath: rawPath))
    }
}
```

整段删除。`displaySource` 枚举本身**保留**（仍被多处使用）。

更新文件头：版本号 `1.11` → `1.12`，Description 末尾追加：`v1.12 删除无调用方的 displayUrl/displayAvailability`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -rn "displayUrl\|displayAvailability" rawViewer/
# 预期：无输出
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；不再含 `displayUrl`/`displayAvailability`。

---

### Task 10: 删 analysisScoring 死变量 + appDebugLogger isEnabled 缓存

**目标：** (a) 删除 `buildBlurFeatures` 里从未累加的死变量 `usable` 及其 `_ = usable` 占位（审查报告 Low 7，循环实际累加的是 `usableCount`/`usableSum`）；(b) 把 `appDebugLogger.isEnabled` 的 `CommandLine.arguments.contains` 改为一次性缓存的 `static let`，避免热路径（draw、numberOfItems）每次线性扫描（审查报告 Low 9）。

**涉及的文件：**

- `rawViewer/services/analysisScoring.swift` — 当前 v1.0 → v1.1
- `rawViewer/services/appDebugLogger.swift` — 当前 v1.0 → v1.1

---

#### Step 1 — 实现

**10.1 修改 `services/analysisScoring.swift`**

定位 `buildBlurFeatures` 内这行（变量声明）：

```swift
    var sharp = 0, lowContrast = 0, usable = 0
```

替换为（删除 `usable`）：

```swift
    var sharp = 0, lowContrast = 0
```

定位循环后的占位行：

```swift
    _ = usable
```

整行删除。

> 确认：循环内 `if t.isUsable { usableSum += ...; usableCount += 1; ... }` 累加的是 `usableCount`，`usable` 从未被 `+= 1`，永远是 0，是死变量。删除安全。

更新文件头：版本号 `1.0` → `1.1`，Description 末尾追加：`v1.1 删除 buildBlurFeatures 中从未累加的死变量 usable`

**10.2 修改 `services/appDebugLogger.swift`**

定位：

```swift
public enum appDebugLogger {
    public static var isEnabled: Bool {
        CommandLine.arguments.contains("--debug")
    }
```

替换为（用 `static let` 一次性缓存，`isEnabled` 保留为计算属性以维持调用方不变）：

```swift
public enum appDebugLogger {
    private static let isDebugEnabled: Bool = CommandLine.arguments.contains("--debug")
    public static var isEnabled: Bool { isDebugEnabled }
```

> 说明：`static let` 在 Swift 中是 lazy + 线程安全（dispatch_once 语义），首次访问时计算一次并缓存，后续热路径调用零开销。

更新文件头：版本号 `1.0` → `1.1`，Description 末尾追加：`v1.1 isEnabled 用 static let 缓存 --debug 检测结果，避免热路径重复扫描 CommandLine.arguments`

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -n "_ = usable" rawViewer/services/analysisScoring.swift
# 预期：无输出
```

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`analysisScoring` 不再含 `_ = usable`；`appDebugLogger` 含 `isDebugEnabled` 缓存。

---

### Task 11: groupCollectionViewItem 复用重构（groupCardView 拆 create/configure）

**目标：** 让 `NSCollectionView` 的 item 复用机制真正生效——`groupCardView` 拆为"一次性创建持久容器" + "configure 更新数据并重建扇形卡片"，`groupCollectionViewItem` 不再每次 `removeFromSuperview` + `new`（审查报告 Low 10）。

**涉及的文件：**

- `rawViewer/views/groupCardView.swift` — 当前 v2.7 → v2.8；重构为 init(imageService:) + configure(group:previewPhotos:)
- `rawViewer/views/groupCollectionViewItem.swift` — 当前 v1.1 → v1.2；复用 cardView 实例

> ⚠️ 这是阶段 B 唯一需要重构（非纯删除）的任务，复杂度最高。请仔细对照完整代码实现。

---

#### Step 1 — 实现

**11.1 重写 `views/groupCardView.swift`**

把 `groupCardView` 改为：init 只创建持久容器（`stackContainer`/`nameLabel`/`countLabel`/点击手势），`configure(group:previewPhotos:)` 负责取消旧 task、移除旧卡片、按新数据重建扇形卡片并启动加载。完整替换整个类（保留文件头格式，更新版本与 Description）：

```swift
/*
Author: wilbur
Version: 2.8
Date: 2026-06-25
Description: 收窄扑克牌扇形角度与水平偏移，避免分组缩略图散开过度。v2.8 拆分为 init(imageService:) 创建持久容器 + configure(group:previewPhotos:) 更新数据，使 NSCollectionViewItem 复用真正生效（不再每次 removeFromSuperview+new）
*/

import AppKit

private struct fanCardLayout {
    let rotationDegrees: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    let zPosition: CGFloat
}

public final class groupCardView: NSView {
    public var onTap: (() -> Void)?

    private let stackContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var cardContainers: [NSView] = []
    private var loadTasks: [Task<Void, Never>] = []
    private let imageService: photoImageService

    public init(imageService: photoImageService) {
        self.imageService = imageService
        super.init(frame: .zero)
        setupContainer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelLoads()
    }

    // MARK: - 一次性容器

    private func setupContainer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8

        stackContainer.wantsLayer = true
        stackContainer.layer?.masksToBounds = false
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            stackContainer.topAnchor.constraint(equalTo: topAnchor),
            stackContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackContainer.heightAnchor.constraint(equalToConstant: 120),

            nameLabel.topAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    // MARK: - 数据更新（复用时重复调用）

    /// 取消旧加载任务、移除旧扇形卡片，按新分组数据重建。
    public func configure(group: photoGroup, previewPhotos: [photoItem]) {
        cancelLoads()
        for container in cardContainers { container.removeFromSuperview() }
        cardContainers.removeAll()

        nameLabel.stringValue = group.kind.title
        countLabel.stringValue = "\(group.photos.count)"

        let count = min(5, previewPhotos.count)
        let layouts = fanLayouts(for: count)

        for index in 0..<count {
            let layout = layouts[index]
            let cardContainer = NSView()
            cardContainer.wantsLayer = true
            cardContainer.layer?.backgroundColor = NSColor.clear.cgColor
            cardContainer.layer?.zPosition = layout.zPosition
            cardContainer.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(cardContainer)

            let imgView = NSImageView()
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.backgroundColor = NSColor.clear.cgColor
            imgView.layer?.cornerRadius = 0
            imgView.layer?.borderWidth = 0
            imgView.layer?.borderColor = nil
            imgView.layer?.shadowOpacity = 0
            imgView.translatesAutoresizingMaskIntoConstraints = false
            cardContainer.addSubview(imgView)

            NSLayoutConstraint.activate([
                cardContainer.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor, constant: layout.xOffset),
                cardContainer.centerYAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: layout.yOffset),
                cardContainer.widthAnchor.constraint(equalToConstant: 82),
                cardContainer.heightAnchor.constraint(equalToConstant: 216),

                imgView.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),
                imgView.bottomAnchor.constraint(equalTo: cardContainer.centerYAnchor),
                imgView.widthAnchor.constraint(equalToConstant: 82),
                imgView.heightAnchor.constraint(equalToConstant: 108)
            ])

            cardContainer.frameCenterRotation = layout.rotationDegrees

            let photo = previewPhotos[index]
            let targetView = imgView
            let task = Task { [weak self] in
                let image = await self?.imageService.loadThumbnail(for: photo, maxWidth: 164, maxHeight: 216)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self, self.cardContainers.contains(targetView.superview ?? NSView()) else { return }
                    targetView.image = image
                }
            }
            loadTasks.append(task)
            cardContainers.append(cardContainer)
        }
    }

    private func cancelLoads() {
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
    }

    private func fanLayouts(for count: Int) -> [fanCardLayout] {
        switch count {
        case 1:
            return [
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -8, zPosition: 1)
            ]
        case 2:
            return [
                fanCardLayout(rotationDegrees: 10, xOffset: -6, yOffset: -8, zPosition: 1),
                fanCardLayout(rotationDegrees: -10, xOffset: 6, yOffset: -8, zPosition: 2)
            ]
        case 3:
            return [
                fanCardLayout(rotationDegrees: 18, xOffset: -10, yOffset: -8, zPosition: 1),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -10, zPosition: 3),
                fanCardLayout(rotationDegrees: -18, xOffset: 10, yOffset: -8, zPosition: 2)
            ]
        case 4:
            return [
                fanCardLayout(rotationDegrees: 24, xOffset: -14, yOffset: -7, zPosition: 1),
                fanCardLayout(rotationDegrees: 8, xOffset: -5, yOffset: -10, zPosition: 3),
                fanCardLayout(rotationDegrees: -8, xOffset: 5, yOffset: -10, zPosition: 4),
                fanCardLayout(rotationDegrees: -24, xOffset: 14, yOffset: -7, zPosition: 2)
            ]
        default:
            return [
                fanCardLayout(rotationDegrees: 26, xOffset: -18, yOffset: -6, zPosition: 1),
                fanCardLayout(rotationDegrees: 13, xOffset: -8, yOffset: -9, zPosition: 3),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: -11, zPosition: 5),
                fanCardLayout(rotationDegrees: -13, xOffset: 8, yOffset: -9, zPosition: 4),
                fanCardLayout(rotationDegrees: -26, xOffset: 18, yOffset: -6, zPosition: 2)
            ]
        }
    }

    @objc private func handleClick() {
        onTap?()
    }
}
```

> 关键变化：
> - `init` 从 `init(group:previewPhotos:imageService:)` 改为 `init(imageService:)`，只建持久容器。
> - 新增 `configure(group:previewPhotos:)`：先 `cancelLoads()` + 移除旧 `cardContainers`，再重建。
> - `previewImageViews` 数组改为 `cardContainers`（重建时按需增减，复用 nameLabel/countLabel/stackContainer）。
> - loadTask 守卫改为 `self.cardContainers.contains(targetView.superview ...)`，判断 imgView 是否还挂在当前卡片上（避免 configure 后旧 task 写入已移除的 view）。

**11.2 重写 `views/groupCollectionViewItem.swift`**

改为复用 cardView 实例（init 时创建一次，configure 时更新数据，prepareForReuse 清理）：

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-25
Description: NSCollectionViewItem 子类，封装 groupCardView，预览图最多传入 5 张并支持 prepareForReuse 取消缩略图加载 Task。v1.2 复用 cardView 实例（init 时创建一次），configure 只更新数据，不再每次 removeFromSuperview+new
*/

import AppKit

public final class groupCollectionViewItem: NSCollectionViewItem {
    private var cardView: groupCardView?

    public func configure(imageService: photoImageService) {
        if cardView == nil {
            let card = groupCardView(imageService: imageService)
            card.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: view.topAnchor),
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                card.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            cardView = card
        }
    }

    public func update(group: photoGroup) {
        let previewPhotos = Array(group.photos.prefix(5))
        cardView?.configure(group: group, previewPhotos: previewPhotos)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // groupCardView.configure 内部会取消旧 task，这里无需额外清理
    }

    public func setOnTap(_ handler: @escaping () -> Void) {
        cardView?.onTap = handler
    }
}
```

**11.3 修改 `groupGrid/groupGridViewController.swift` 的 item 创建调用**

> 注意：Task 8 已改过此文件（删顶层 route），本任务的 anchor 基于 Task 8 之后的状态。若 Task 8 未执行，先确认 route 已删；若本任务先于 Task 8 执行，也只需改下面这一处（不冲突）。

定位 `collectionView(_:itemForRepresentedObjectAt:)` 内：

```swift
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("groupCard")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! groupCollectionViewItem
        let group = viewModel.groups[indexPath.item]
        appDebugLogger.log("display groups configure index=\(indexPath.item) title=\(group.kind.title) count=\(group.photos.count) first=\(group.photos.first?.photoId ?? "")")
        item.configure(with: group, imageService: imageService)

        if let card = item.view.subviews.first as? groupCardView {
            card.onTap = { [weak self] in
                self?.onSelectGroup?(group)
            }
        }

        return item
    }
```

替换为：

```swift
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("groupCard")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! groupCollectionViewItem
        let group = viewModel.groups[indexPath.item]
        appDebugLogger.log("display groups configure index=\(indexPath.item) title=\(group.kind.title) count=\(group.photos.count) first=\(group.photos.first?.photoId ?? "")")
        item.configure(imageService: imageService)
        item.update(group: group)
        item.setOnTap { [weak self] in
            self?.onSelectGroup?(group)
        }

        return item
    }
```

更新 `groupGridViewController.swift` 文件头：在当前版本号基础上 +1，Description 末尾追加：`配合 groupCardView 复用重构，item 改为 configure(imageService:)+update(group:)`（若 Task 8 已把版本升到 4.4，此处 → 4.5）。

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
$ grep -n "init(group:" rawViewer/views/groupCardView.swift
# 预期：无输出（旧 init 已移除）
$ grep -n "configure(with:" rawViewer/groupGrid/groupGridViewController.swift
# 预期：无输出（旧调用已替换）
```

构建通过后，手动验证（`--debug` 启动）：加载含照片文件夹 → 进入分组页 → 扇形卡片正常显示、点击进入分组正常、来回滚动分组页缩略图正常显示（无错位、无残留）。

---

✅ **完成标志：** 构建 `** BUILD SUCCEEDED **`；`groupCardView` 用 `init(imageService:)` + `configure(group:previewPhotos:)`；`groupCollectionViewItem` 复用实例；分组页扇形卡片显示与点击正常。

---

## 自我复审

**1. 规范覆盖（对照 review 报告剩余 16 项）：**
- 🟡 Medium 2（YAML 解析）→ Task 1。✅
- 🟡 Medium 3（捏合缩放）→ Task 2。✅
- 🟡 Medium 4（CFDate）→ Task 3。✅
- 🟡 Medium 6（直方图白算）→ Task 4（删 exposureBuffer；4 通道直方图保留并说明理由）。✅
- 🔵 Low 1（runJpgFallback）→ Task 6。✅
- 🔵 Low 2（reducePipeline）→ Task 5。✅
- 🔵 Low 3（loadImage）→ Task 7。✅
- 🔵 Low 4（route）→ Task 8。✅
- 🔵 Low 5（displayUrl）→ Task 9。✅
- 🔵 Low 6（photoSource/photoLoadError）→ Task 2（合并，同文件）。✅
- 🔵 Low 7（_ = usable）→ Task 10。✅
- 🔵 Low 9（isEnabled 缓存）→ Task 10（合并，琐碎单点）。✅
- 🔵 Low 10（复用）→ Task 11。✅
- 🔵 Low 11（p999Code）→ Task 4（合并，同 analyzer 文件）。✅
- 🔵 Low 12（双触发）→ Task 2（合并，同文件，保守处理）。✅
- 🔵 Low 8（print→appFileLogger）→ **已在上一轮 Top3 修复的 Task 1 微调中完成**，不纳入本计划。✅

**未纳入（已说明）：** 🟡 Medium 1（全量 JSON 重写 → debounced 内存模型）和 🟡 Medium 5（analysisStore 改 actor）——前者需单独评估持久化权衡，后者是 YAGNI，不在本计划。

**2. 占位符扫描：** 全文无 TODO / "稍后实现" / "类似 Task N"。每个 Step 1 都给出完整可粘贴代码或精确删除定位。Task 11 的完整类重写已给出。✅

**3. 类型一致性：**
- Task 4：`bayerHistConfig`/`jpgHistConfig` 删字段 → Metal `BayerHistConfig`/`JpgHistConfig` 同步删字段 → kernel 删参数 → Swift 删 setBuffer + absOver/absUnder，四处联动一致。✅
- Task 11：`groupCardView.init(imageService:)` + `configure(group:previewPhotos:)` → `groupCollectionViewItem.configure(imageService:)` + `update(group:)` + `setOnTap(_:)` → `groupGridViewController` 调用三者，签名一致。✅
- Task 2：`handlePinch` 改累积后 `pinchStartZoom`/`pinchStartMagnification` 无引用 → 同任务删除，闭环。✅

**4. 验证完整性：** 每个任务都有 `xcodebuild ... build` + `** BUILD SUCCEEDED **` + grep 验证（删代码任务）或行为验证（改逻辑任务）。✅

**5. 文件冲突与依赖：** 唯一跨任务文件冲突是 `rawAnalysisShaders.metal`（Task 4 + Task 5），Task 5 显式 `dependsOn Task 4`。其余文件唯一归属。Task 8 与 Task 11 都触及 `groupGridViewController.swift`，但 Task 8 删顶层 route、Task 11 改 `itemForRepresentedObjectAt` 内部，区域不同；计划已标注 Task 11 anchor 基于 Task 8 之后状态。✅

**6. 版本号一致性：** 所有文件的当前版本号已核对（基于 Top3 修复后的状态），递增量已在各任务标明。✅

---

## 执行交接

计划已完成并保存到 `docs/flare/20260625_robustness_cleanup.md`。两种执行选项：

1. **子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代。本计划 11 个任务，Task 5 依赖 Task 4，其余独立，可用 `sdd_subagents` 按依赖批次调度。
2. **内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理。

选择哪种方式？
