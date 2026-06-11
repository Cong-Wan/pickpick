# 全量代码审查问题修复 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复全量代码审查中发现的 17 个问题，使 pickpick 在配置错误、大图资源、并发分析、删除/重复比较状态同步、错误展示等路径上稳定可恢复。

**架构：** 采用定向重构，不引入大规模新架构。配置校验集中在 `configLoader`，Metal 初始化和 GPU 编码错误通过 throwing 路径上抛，review 状态通过 `jsonReviewStateStore.update` 单次读写，UI 错误展示留在 ViewController 层，coordinator 负责全局 records 刷新。

**技术栈：** Swift 5 / AppKit / Metal / CoreImage / ImageIO / Objective-C++ LibRaw bridge / Yams / Xcode project build。

---

## 文件结构与职责

### 新增文件

- `rawViewer/services/appDebugLogger.swift` — 读取 `CommandLine.arguments` 中的 `--debug`，提供受控 debug 日志入口。新增日志必须通过此文件输出。

### 修改文件

- `rawViewer/appDelegate.swift` — 清理启动日志，去除不必要强制解包，启动日志受 `--debug` 控制。
- `rawViewer/services/configLoader.swift` — 校验 YAML 配置边界，防止非法 ratio、blur threshold、metalConcurrency 进入分析层。
- `rawViewer/metal/metalAnalysisContext.swift` — 将 Metal 初始化和 pipeline 创建失败从 `fatalError` 改为 throwing 错误。
- `rawViewer/services/rawBayerAnalyzer.swift` — 延迟获取 Metal context，替换 compute encoder 强制解包，修正 RAW DR bin 到码值转换。
- `rawViewer/services/jpgAnalyzer.swift` — 延迟获取 Metal context，替换 compute encoder 强制解包，加入 JPG 像素数上限。
- `rawViewer/services/photoDisplayService.swift` — JPG 显示路径加入 extent 和像素数保护。
- `rawViewer/services/exifReader.swift` — 移除共享 `DateFormatter`，避免并发访问。
- `rawViewer/services/photoAnalysisService.swift` — 修复 progress 回调计数、EXIF 并发限流、DispatchGroup leave 安全性。
- `rawViewer/appCoordinator.swift` — progress UI 回 MainActor；损坏 analysis.json 时重新分析；返回分组前刷新全局 records。
- `rawViewer/models/jsonReviewStateStore.swift` — 新增批量 `update`，让 review 操作一次 load/save。
- `rawViewer/browser/photoBrowserViewModel.swift` — 删除操作使用单次 JSON mutation。
- `rawViewer/browser/photoBrowserViewController.swift` — 删除失败显示 alert，Browser source 切换持久化。
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — keepLeft/keepRight/keepBoth 使用单次 JSON mutation，并修正 keepBoth groupId 语义。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 去掉 `try?` 吞错，失败时 alert。
- `rawViewer/views/photoMetalViewController.swift` — 添加 AppKit 错误 label，错误路径不再黑屏。

### 不修改

- 不新增 XCTest target。
- 不新增 Git 操作。
- 不重写为 structured concurrency。
- 不引入 error presenter 抽象。
- 不实现 JPG 降采样分析。

---

### Task 1: Debug 基础设施与启动日志清理

**目标：** 应用启动时不再使用不必要强制解包；新增日志统一受 `--debug` 控制，未传 `--debug` 时不输出新增详细日志。

**涉及的文件：**

- `rawViewer/services/appDebugLogger.swift` — 新增 debug 日志基础设施
- `rawViewer/appDelegate.swift` — 使用 debug logger，清理强制解包和临时日志

------

#### Step 1 — 实现

新建 `rawViewer/services/appDebugLogger.swift`，完整内容如下：

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 提供受 --debug 参数控制的轻量日志工具，用于关键路径调试输出
*/

import Foundation

public enum appDebugLogger {
    public static var isEnabled: Bool {
        CommandLine.arguments.contains("--debug")
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[pickpick debug] %@", message())
    }
}
```

将 `rawViewer/appDelegate.swift` 替换为完整内容：

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 使用 AppKit application delegate 创建并持有 pickpick 主窗口控制器；清理启动强制解包，启动调试日志改为 --debug 控制
*/

import AppKit

final class appDelegate: NSObject, NSApplicationDelegate {
    private var mainController: mainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDebugLogger.log("applicationDidFinishLaunching")
        let controller = mainWindowController()
        mainController = controller
        guard let window = controller.window else {
            appDebugLogger.log("main window is nil")
            return
        }
        appDebugLogger.log("showWindow before visible=\(window.isVisible)")
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        appDebugLogger.log("showWindow after visible=\(window.isVisible)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动启动带 debug 参数的 app：

```bash
$ /Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-hanoqkjmyestuveeygokcbvdwvnd/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug
# 预期：应用窗口出现；控制台出现 [pickpick debug] applicationDidFinishLaunching 和 showWindow 日志；运行无崩溃
```

手动启动不带 debug 参数的 app：

```bash
$ /Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-hanoqkjmyestuveeygokcbvdwvnd/Build/Products/Debug/pickpick
# 预期：应用窗口出现；不输出新增 [pickpick debug] 日志；运行无崩溃
```

✅ **完成的标志：** 构建通过；带 `--debug` 时有受控日志，不带时无新增 debug 日志；窗口正常显示。

------

### Task 2: 配置校验与 JPG 显示资源保护

**目标：** 非法 YAML 不再导致卡死或数值转换崩溃；超大 JPG 不再进入显示解码热路径。

**涉及的文件：**

- `rawViewer/services/configLoader.swift` — 集中校验 config
- `rawViewer/services/photoDisplayService.swift` — JPG 显示路径 extent 和像素上限保护

------

#### Step 1 — 实现

将 `rawViewer/services/configLoader.swift` 替换为完整内容：

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 从 folderUrl/config.yaml → Bundle.main/config.yaml → 硬编码默认值三级降级加载 config；校验 ratio、blur threshold 和 Metal 并发边界，避免非法 YAML 导致崩溃或卡死
*/

import Foundation
import Yams

public final class configLoader {
    public init() {}

    /// 加载顺序: folderUrl/config.yaml > Bundle.main/config.yaml > defaults
    public func load(for folderUrl: URL) throws -> analysisConfig {
        let folderConfig = folderUrl.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: folderConfig.path) {
            return try load(from: folderConfig)
        }
        if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
            return try load(from: bundleConfig)
        }
        return analysisConfig.defaults
    }

    /// 从指定 yaml 文件加载, 字段缺失或非法则回退默认值/安全边界
    public func load(from url: URL) throws -> analysisConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let raw = try Yams.load(yaml: text) as? [String: Any] else {
            return analysisConfig.defaults
        }
        return parse(raw)
    }

    private func parse(_ root: [String: Any]) -> analysisConfig {
        let exposureNode = root["exposure_detection"] as? [String: Any] ?? [:]
        let blurNode = root["blur_detection"] as? [String: Any] ?? [:]
        let analysisNode = root["analysis"] as? [String: Any] ?? [:]

        let exposure = exposureConfig(
            overexposePixelThreshold: ratioValue(
                exposureNode["overexpose_pixel_threshold"],
                default: analysisConfig.defaults.exposure.overexposePixelThreshold
            ),
            underexposePixelThreshold: ratioValue(
                exposureNode["underexpose_pixel_threshold"],
                default: analysisConfig.defaults.exposure.underexposePixelThreshold
            ),
            overexposeRatioLimit: ratioValue(
                exposureNode["overexpose_ratio_limit"],
                default: analysisConfig.defaults.exposure.overexposeRatioLimit
            ),
            underexposeRatioLimit: ratioValue(
                exposureNode["underexpose_ratio_limit"],
                default: analysisConfig.defaults.exposure.underexposeRatioLimit
            )
        )

        let blur = blurConfig(
            laplacianThresholdRaw: nonNegativeValue(
                blurNode["laplacian_threshold_raw"],
                default: analysisConfig.defaults.blur.laplacianThresholdRaw
            ),
            laplacianThresholdJpg: nonNegativeValue(
                blurNode["laplacian_threshold_jpg"],
                default: analysisConfig.defaults.blur.laplacianThresholdJpg
            )
        )

        let rawConcurrency = intValue(analysisNode["metal_concurrency"])
            ?? analysisConfig.defaults.metalConcurrency
        let concurrency = min(max(rawConcurrency, 1), 4)

        return analysisConfig(exposure: exposure, blur: blur, metalConcurrency: concurrency)
    }

    private func ratioValue(_ any: Any?, default defaultValue: Double) -> Double {
        guard let value = doubleValue(any), value.isFinite else { return defaultValue }
        return min(1.0, max(0.0, value))
    }

    private func nonNegativeValue(_ any: Any?, default defaultValue: Double) -> Double {
        guard let value = doubleValue(any), value.isFinite, value >= 0 else { return defaultValue }
        return value
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double, d.isFinite { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
```

在 `rawViewer/services/photoDisplayService.swift` 中做以下精确修改。

在类属性区域加入像素上限：

```swift
private let maxDisplayJpgPixels = 100_000_000
```

将 `loadJpg(jpgPath:)` 函数替换为完整函数：

```swift
private func loadJpg(jpgPath: String) -> photoImageResult {
    guard fileManager.fileExists(atPath: jpgPath) else {
        return .unavailable("Missing JPG")
    }
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
        return .unavailable("Cannot decode JPG")
    }
    let extent = image.extent
    guard extent.width > 0, extent.height > 0,
          extent.width.isFinite, extent.height.isFinite else {
        return .unavailable("Invalid JPG extent")
    }
    let totalPixels = extent.width * extent.height
    guard totalPixels <= CGFloat(maxDisplayJpgPixels) else {
        return .unavailable("JPG too large")
    }
    return .image(image)
}
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动验证非法配置：

```bash
$ mkdir -p /tmp/pickpick_bad_config
$ cat > /tmp/pickpick_bad_config/config.yaml <<'YAML'
exposure_detection:
  overexpose_pixel_threshold: -1
  underexpose_pixel_threshold: 2
  overexpose_ratio_limit: -0.5
  underexpose_ratio_limit: 8
blur_detection:
  laplacian_threshold_raw: -5
  laplacian_threshold_jpg: -1
analysis:
  metal_concurrency: 0
YAML
# 预期：文件创建成功
```

用应用选择 `/tmp/pickpick_bad_config` 文件夹。

预期：应用不会卡死；若文件夹无照片，进度能完成并进入空分组状态或显示无结果状态；不出现崩溃。

✅ **完成的标志：** 构建通过；非法配置不导致卡死或崩溃；JPG 显示路径对非法 extent 和超大像素返回 unavailable。

------

### Task 3: Metal 初始化可恢复、Analyzer 资源保护与 DR 修正

**目标：** Metal 不支持、shader 缺失、pipeline 创建失败、encoder 创建失败时应用不直接退出；RAW DR 计算使用真实码值；JPG 分析拒绝超大图片。

**涉及的文件：**

- `rawViewer/metal/metalAnalysisContext.swift` — throwing 初始化和缓存
- `rawViewer/services/rawBayerAnalyzer.swift` — contextProvider、encoder guard、DR 修正
- `rawViewer/services/jpgAnalyzer.swift` — contextProvider、encoder guard、JPG 像素上限

------

#### Step 1 — 实现

将 `rawViewer/metal/metalAnalysisContext.swift` 替换为完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: Metal 设备 / queue / pipeline 上下文；初始化失败改为 throws，避免设备或 shader 异常时 fatalError 退出
*/

import Foundation
import Metal

public enum metalAnalysisContextError: Error, LocalizedError {
    case metalNotSupported
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(name: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .metalNotSupported:
            return "Metal is not supported on this device"
        case .commandQueueUnavailable:
            return "Failed to create Metal command queue"
        case .libraryUnavailable:
            return "Failed to load default Metal library"
        case .functionUnavailable(let name):
            return "Metal function '\(name)' was not found"
        case .pipelineCreationFailed(let name, let underlying):
            return "Failed to create Metal pipeline '\(name)': \(underlying.localizedDescription)"
        }
    }
}

public final class metalAnalysisContext {
    private static let cachedResult: Result<metalAnalysisContext, Error> = Result {
        try metalAnalysisContext()
    }

    public static func shared() throws -> metalAnalysisContext {
        try cachedResult.get()
    }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public let bayerHistogramPipeline: MTLComputePipelineState
    public let bayerToGreenPlanePipeline: MTLComputePipelineState
    public let greenLaplacianPipeline: MTLComputePipelineState
    public let reducePipeline: MTLComputePipelineState

    public let rgbToGrayPipeline: MTLComputePipelineState
    public let jpgHistogramPipeline: MTLComputePipelineState
    public let jpgLaplacianPipeline: MTLComputePipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw metalAnalysisContextError.metalNotSupported
        }
        guard let queue = device.makeCommandQueue() else {
            throw metalAnalysisContextError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw metalAnalysisContextError.libraryUnavailable
        }
        self.device = device
        self.commandQueue = queue
        self.library = library

        self.bayerHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "bayerHistogramKernel")
        self.bayerToGreenPlanePipeline = try Self.makePipeline(device: device, library: library, name: "bayerToGreenPlaneKernel")
        self.greenLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "greenLaplacianKernel")
        self.reducePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
        self.rgbToGrayPipeline = try Self.makePipeline(device: device, library: library, name: "rgbToGrayKernel")
        self.jpgHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgHistogramKernel")
        self.jpgLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "jpgLaplacianKernel")
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw metalAnalysisContextError.functionUnavailable(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw metalAnalysisContextError.pipelineCreationFailed(name: name, underlying: error)
        }
    }
}
```

在 `rawViewer/services/rawBayerAnalyzer.swift` 中修改构造和 context 获取：

1. 将属性：

```swift
private let context: metalAnalysisContext
```

替换为：

```swift
private let contextProvider: () throws -> metalAnalysisContext
```

2. 将 init 替换为：

```swift
public init(contextProvider: @escaping () throws -> metalAnalysisContext = metalAnalysisContext.shared) {
    self.contextProvider = contextProvider
}
```

3. 在 `analyze(rawPath:config:)` 第一行加入：

```swift
let context = try contextProvider()
```

4. 将所有 `let encoder = cmd.makeComputeCommandEncoder()!` 替换为：

```swift
guard let encoder = cmd.makeComputeCommandEncoder() else {
    throw makeError("makeComputeCommandEncoder failed")
}
```

5. 将 RAW DR 计算块：

```swift
let (p01, p999) = computePercentiles(greenHist: greenHist, totalPixels: UInt64(greenW * greenH), binCount: Int(binCount))
let sceneSpreadEv = p01 > 0 ? log2(Double(p999) / Double(p01)) : 0
let codeRangeEv = log2(Double(white - black) / Double(max(1, p01)))
```

替换为：

```swift
let (p01, p999) = computePercentiles(greenHist: greenHist, totalPixels: UInt64(greenW * greenH), binCount: Int(binCount))
let maxBin = Double(binCount - 1)
let p01Code = Double(p01) / maxBin * Double(white - black)
let p999Code = Double(p999) / maxBin * Double(white - black)
let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
let codeRangeEv = p01Code > 0 ? log2(Double(white - black) / p01Code) : 0
```

在 `rawViewer/services/jpgAnalyzer.swift` 中修改：

1. 将属性：

```swift
private let context: metalAnalysisContext
private let ciContext: CIContext
```

替换为：

```swift
private let contextProvider: () throws -> metalAnalysisContext
private let maxJpgPixels: Int
```

2. 将 init 替换为：

```swift
public init(
    contextProvider: @escaping () throws -> metalAnalysisContext = metalAnalysisContext.shared,
    maxJpgPixels: Int = 100_000_000
) {
    self.contextProvider = contextProvider
    self.maxJpgPixels = maxJpgPixels
}
```

3. 在 `analyze(jpgPath:config:)` 开始处加入：

```swift
let context = try contextProvider()
let ciContext = CIContext(mtlDevice: context.device)
```

4. 在 `let totalPixels = width * height` 后加入：

```swift
guard totalPixels <= maxJpgPixels else {
    throw makeError("JPG too large: \(width)x\(height)")
}
```

5. 将所有 `let encoder = cmd.makeComputeCommandEncoder()!` 替换为：

```swift
guard let encoder = cmd.makeComputeCommandEncoder() else {
    throw makeError("makeComputeCommandEncoder failed")
}
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动验证：启动应用，选择一个包含 JPG 或 RAW 的目录。

预期：

- 支持 Metal 的机器上分析流程正常进入进度页并完成或显示可读错误。
- 不出现 `fatalError` 终止。
- 控制台无 Swift force unwrap 崩溃信息。

✅ **完成的标志：** 构建通过；Analyzer 初始化和 Metal 编码异常路径通过 throws 处理；应用不因 Metal context 初始化失败路径直接退出。

------

### Task 4: 分析并发、进度和主线程边界修复

**目标：** 分析进度单调递增，EXIF 读取无共享 DateFormatter 数据竞争，AppKit UI 更新回到 MainActor。

**涉及的文件：**

- `rawViewer/services/exifReader.swift` — 局部 DateFormatter
- `rawViewer/services/photoAnalysisService.swift` — EXIF 限流、真实完成计数、leave defer
- `rawViewer/appCoordinator.swift` — progress UI 回 MainActor

------

#### Step 1 — 实现

在 `rawViewer/services/exifReader.swift` 中：

1. 删除属性：

```swift
private let dateFormatter: DateFormatter
```

2. 将 init 替换为：

```swift
public init() {}
```

3. 将 `parseExifDate(_:)` 替换为完整函数：

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

在 `rawViewer/services/photoAnalysisService.swift` 中：

1. 在 EXIF 阶段变量区域加入：

```swift
var exifCompletedCount = 0
```

2. 在 `let exifGroup = DispatchGroup()` 后加入：

```swift
let exifSemaphore = DispatchSemaphore(value: 8)
```

3. 将 EXIF queue block 的开头：

```swift
exifQueue.async {
    let timeResult = self.exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)
```

替换为：

```swift
exifQueue.async {
    exifSemaphore.wait()
    defer {
        exifSemaphore.signal()
        exifGroup.leave()
    }

    let timeResult = self.exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)
```

4. 删除 EXIF block 末尾原有 `exifGroup.leave()`。

5. 将 EXIF completed 计算：

```swift
let completed = index + 1
let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
```

替换为：

```swift
recordsLock.lock()
exifCompletedCount += 1
let completed = exifCompletedCount
recordsLock.unlock()
let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
```

6. 在分析阶段变量区域加入：

```swift
var analysisCompletedCount = 0
```

7. 将分析 queue block 的开头：

```swift
analysisQueue.async {
    gpuSemaphore.wait()
    defer { gpuSemaphore.signal() }
```

替换为：

```swift
analysisQueue.async {
    gpuSemaphore.wait()
    defer {
        gpuSemaphore.signal()
        analysisGroup.leave()
    }
```

8. 删除分析 block 末尾原有 `analysisGroup.leave()`。

9. 将分析 completed 计算：

```swift
let completed = index + 1
let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
let phase: analysisPhase = pair.hasRaw ? .rawAnalysis : .jpgAnalysis
progress(analysisProgress(phase: phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))
```

替换为：

```swift
recordsLock.lock()
analysisCompletedCount += 1
let completed = analysisCompletedCount
recordsLock.unlock()
let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
let phase: analysisPhase = pair.hasRaw ? .rawAnalysis : .jpgAnalysis
progress(analysisProgress(phase: phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))
```

在 `rawViewer/appCoordinator.swift` 中，将 analyze progress 闭包：

```swift
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    progressController.update(progress: progress)
}
```

替换为：

```swift
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    Task { @MainActor in
        progressController.update(progress: progress)
    }
}
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动验证：选择一个包含多张照片的目录启动分析。

预期：

- 进度 `completed / total` 单调递增。
- 百分比不倒退。
- UI 不出现主线程异常。
- 分析流程运行无崩溃。

✅ **完成的标志：** 构建通过；分析进度单调；EXIF 和 progress 修改运行无异常。

------

### Task 5: Review 状态事务、删除同步与重复比较错误处理

**目标：** 删除和重复比较操作使用单次 JSON mutation；失败不再静默吞掉；返回分组页时全局 records 与 JSON 同步。

**涉及的文件：**

- `rawViewer/models/jsonReviewStateStore.swift` — 批量 update
- `rawViewer/browser/photoBrowserViewModel.swift` — 删除单次 JSON mutation
- `rawViewer/browser/photoBrowserViewController.swift` — 删除错误 alert
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — keep 操作单次 JSON mutation
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 移除 try?，错误 alert
- `rawViewer/appCoordinator.swift` — 返回分组前 reloadData

------

#### Step 1 — 实现

在 `rawViewer/models/jsonReviewStateStore.swift` 中：

1. 在协议中加入：

```swift
func update(_ mutate: (inout [photoItem]) -> Void) throws
```

2. 将私有 `updateRecords` 改为 public，并保留现有方法复用。最终相关代码应为：

```swift
public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
    func update(_ mutate: (inout [photoItem]) -> Void) throws
}
```

```swift
public func mark(photoId: String, status: reviewStatus) throws {
    try update { items in
        guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
        items[index].reviewStatus = status
    }
    operations.append(.status(photoId: photoId, status: status))
}

public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
    try update { items in
        for index in items.indices where items[index].reviewGroupId == reviewGroupId {
            items[index].templatePhotoId = templatePhotoId
        }
    }
    operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
}

public func clearReviewGroupId(photoId: String) throws {
    try update { items in
        guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
        items[index].reviewGroupId = ""
    }
}

public func update(_ mutate: (inout [photoItem]) -> Void) throws {
    guard let folderUrl else { return }
    var records = try analysisStore.shared.load(for: folderUrl)
    mutate(&records)
    try analysisStore.shared.save(folderUrl: folderUrl, records: records)
}
```

在 `rawViewer/browser/photoBrowserViewModel.swift` 中，将 `confirmDelete()` 替换为完整函数：

```swift
public func confirmDelete() throws {
    let targets = deleteTargets()
    for photo in targets {
        try trashService.trash(photo)
    }

    let ids = Set(targets.map(\.photoId))
    try store.update { items in
        for index in items.indices where ids.contains(items[index].photoId) {
            items[index].reviewStatus = .trashed
        }
    }

    photos.removeAll { ids.contains($0.photoId) }
    checkedPhotoIds.subtract(ids)
    currentIndex = min(currentIndex, max(photos.count - 1, 0))
    currentRequestId += 1
}
```

在 `rawViewer/browser/photoBrowserViewController.swift` 中加入私有 alert helper：

```swift
private func showErrorAlert(message: String) {
    let alert = NSAlert()
    alert.messageText = "Operation failed"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

将 delete catch：

```swift
} catch {
    print("Delete failed: \(error)")
}
```

替换为：

```swift
} catch {
    showErrorAlert(message: error.localizedDescription)
}
```

将 `rawViewer/duplicate/duplicateCompareViewModel.swift` 中 keep 函数重写为以下完整函数组：

```swift
public func keepLeft() throws -> duplicateCompareActionResult {
    guard let left = mainPhoto else { return .finished }
    guard let right = candidatePhoto else {
        try markFinalKept(left)
        return .finished
    }
    try trashService.trash(right)
    photos.removeAll { $0.photoId == right.photoId }
    let shouldFinish = photos.count == 1
    try store.update { items in
        if let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
            items[rightIndex].reviewStatus = .trashed
        }
        if shouldFinish, let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
            items[leftIndex].reviewStatus = .kept
            if !left.reviewGroupId.isEmpty {
                for index in items.indices where items[index].reviewGroupId == left.reviewGroupId {
                    items[index].templatePhotoId = left.photoId
                }
                items[leftIndex].reviewGroupId = ""
            }
        }
    }
    if shouldFinish { return .finished }
    mainIndex = 0
    candidateIndex = min(1, photos.count - 1)
    return .continueComparing
}

public func keepRight() throws -> duplicateCompareActionResult {
    guard let left = mainPhoto else { return .finished }
    guard let right = candidatePhoto else {
        try markFinalKept(left)
        return .finished
    }
    try trashService.trash(left)
    photos.removeAll { $0.photoId == left.photoId }
    let shouldFinish = photos.count == 1
    try store.update { items in
        if let leftIndex = items.firstIndex(where: { $0.photoId == left.photoId }) {
            items[leftIndex].reviewStatus = .trashed
        }
        if shouldFinish, let rightIndex = items.firstIndex(where: { $0.photoId == right.photoId }) {
            items[rightIndex].reviewStatus = .kept
            if !right.reviewGroupId.isEmpty {
                for index in items.indices where items[index].reviewGroupId == right.reviewGroupId {
                    items[index].templatePhotoId = right.photoId
                }
                items[rightIndex].reviewGroupId = ""
            }
        }
    }
    if shouldFinish { return .finished }
    mainIndex = 0
    candidateIndex = min(1, photos.count - 1)
    return .continueComparing
}

public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
    let left = mainPhoto
    let right = candidatePhoto
    let originalGroupId = left?.reviewGroupId.isEmpty == false ? left?.reviewGroupId : right?.reviewGroupId
    let keptIds = Set([left, right].compactMap { $0?.photoId })

    photos.removeAll { keptIds.contains($0.photoId) }
    let remainingCount = photos.count
    let remainingLast = photos.first

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

    switch remainingCount {
    case 0:
        return .finished
    case 1:
        return .finished
    default:
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
}

private func markFinalKept(_ photo: photoItem) throws {
    try store.update { items in
        guard let index = items.firstIndex(where: { $0.photoId == photo.photoId }) else { return }
        items[index].reviewStatus = .kept
        if !photo.reviewGroupId.isEmpty {
            for itemIndex in items.indices where items[itemIndex].reviewGroupId == photo.reviewGroupId {
                items[itemIndex].templatePhotoId = photo.photoId
            }
            items[index].reviewGroupId = ""
        }
    }
}
```

在 `rawViewer/duplicate/duplicateCompareViewController.swift` 中加入私有 alert helper：

```swift
private func showErrorAlert(message: String) {
    let alert = NSAlert()
    alert.messageText = "Operation failed"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

将 keepBoth 中所有 `try?` 调用改为 `do/catch`。例如两张以内分支替换为：

```swift
if viewModel.photos.count <= 2 {
    do {
        let result = try viewModel.keepBoth(templatePhotoId: left.photoId)
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
    return
}
```

Left 分支替换为：

```swift
if response == .alertFirstButtonReturn {
    do {
        let result = try viewModel.keepBoth(templatePhotoId: left.photoId)
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
} else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
    do {
        let result = try viewModel.keepBoth(templatePhotoId: right.photoId)
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
}
```

将 keyDown keepLeft/keepRight 分支替换为：

```swift
case 123:
    do {
        let result = try viewModel.keepLeft()
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
case 124:
    do {
        let result = try viewModel.keepRight()
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
```

在 `rawViewer/appCoordinator.swift` 中加入 helper：

```swift
private func reloadDataIgnoringError() {
    do {
        try reloadData()
    } catch {
        appDebugLogger.log("reloadData failed: \(error.localizedDescription)")
    }
}
```

将 browser onBack 替换为：

```swift
browser.onBack = { [weak self] in
    guard let self else { return }
    self.reloadDataIgnoringError()
    self.showGroups()
}
```

将 duplicate onBack 替换为：

```swift
duplicate.onBack = { [weak self] in
    guard let self else { return }
    self.reloadDataIgnoringError()
    self.showGroups()
}
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动验证浏览器删除：

1. 启动应用。
2. 选择有多张照片的目录。
3. 进入普通分组。
4. 删除当前照片。
5. 返回分组页。

预期：已删除照片不再出现在当前分组，返回分组页后不再出现旧数据。

手动验证重复比较：

1. 选择包含重复拍摄时间的目录。
2. 进入 duplicate 分组。
3. 分别触发 Left arrow、Right arrow、Keep both。

预期：操作成功时 UI 正常推进；失败时弹出 Operation failed alert；返回分组页后数据与 JSON 状态一致。

✅ **完成的标志：** 构建通过；删除和重复比较操作无静默失败；返回分组页时 records 已刷新。

------

### Task 6: 错误显示、source 持久化和缓存损坏恢复

**目标：** 图片不可用时主图区域显示可读错误；Browser 和 Duplicate 的 JPG/RAW 选择一致持久化；损坏 analysis.json 可重新分析。

**涉及的文件：**

- `rawViewer/views/photoMetalViewController.swift` — AppKit 错误 label
- `rawViewer/browser/photoBrowserViewController.swift` — source 持久化
- `rawViewer/appCoordinator.swift` — 损坏缓存时重新分析

------

#### Step 1 — 实现

在 `rawViewer/views/photoMetalViewController.swift` 中新增属性：

```swift
private let errorLabel = NSTextField(labelWithString: "")
```

在 `loadView()` 中，`container.addSubview(metalView)` 后加入：

```swift
errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
errorLabel.textColor = .secondaryLabelColor
errorLabel.alignment = .center
errorLabel.isHidden = true
errorLabel.translatesAutoresizingMaskIntoConstraints = false
container.addSubview(errorLabel)
```

在约束数组中加入：

```swift
errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
errorLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
```

将状态 API 三个函数替换为：

```swift
public func load(image: CIImage?) {
    errorLabel.isHidden = true
    errorLabel.stringValue = ""
    if let image {
        metalView.setImage(image)
        hasImage = true
    } else {
        metalView.clearImage()
        hasImage = false
    }
}

public func reset() {
    errorLabel.isHidden = true
    errorLabel.stringValue = ""
    metalView.clearImage()
    metalView.resetZoom()
    metalView.resetPan()
    panOffset = .zero
    hasImage = false
}

public func showError(_ message: String) {
    metalView.showError(message)
    errorLabel.stringValue = message
    errorLabel.isHidden = false
    hasImage = false
}
```

在 `rawViewer/browser/photoBrowserViewController.swift` 中，将 `sourceChanged(_:)` 替换为：

```swift
@objc private func sourceChanged(_ sender: NSSegmentedControl) {
    let source: displaySource = (sender.selectedSegment == 0) ? .jpg : .raw
    displaySourceStore().current = source
    viewModel.setDisplaySource(source)
    loadCurrentPhoto()
}
```

在 `rawViewer/appCoordinator.swift` 中重构 `startAnalysis(folderUrl:)` 的缓存加载分支。

将：

```swift
if analysisStore.shared.hasResults(for: folderUrl) {
    let loadedRecords = try analyzer.loadRecords(folderUrl: folderUrl)
    self.records = loadedRecords
    self.trashService.cleanupTrashedPhotos(self.records)
    self.showGroups()
    return
}
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    Task { @MainActor in
        progressController.update(progress: progress)
    }
}
self.records = try analyzer.loadRecords(folderUrl: folderUrl)
```

替换为：

```swift
if analysisStore.shared.hasResults(for: folderUrl) {
    do {
        let loadedRecords = try analyzer.loadRecords(folderUrl: folderUrl)
        self.records = loadedRecords
        self.trashService.cleanupTrashedPhotos(self.records)
        self.showGroups()
        return
    } catch {
        appDebugLogger.log("cached analysis load failed, reanalyzing: \(error.localizedDescription)")
    }
}
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    Task { @MainActor in
        progressController.update(progress: progress)
    }
}
self.records = try analyzer.loadRecords(folderUrl: folderUrl)
```

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

手动验证错误显示：

1. 打开一个只有 JPG 没有 RAW 的目录。
2. 进入 Browser。
3. 切换到 RAW。

预期：主图区域显示 `No image available` 或对应错误文本，不是纯黑屏。

手动验证 source 持久化：

1. 在 Browser 切到 RAW。
2. 返回分组页。
3. 进入另一个分组。

预期：source 控件保持 RAW，与 Duplicate 页面行为一致。

手动验证缓存损坏恢复：

1. 先对一个目录完成一次分析。
2. 找到该目录对应的 `analysis.json` 并写入非法内容。
3. 重新选择同一目录。

预期：应用不直接停留在错误页，进入重新分析流程；若重新分析成功则进入分组页。

✅ **完成的标志：** 构建通过；错误文本可见；source 持久化；损坏缓存可重新分析。

------

### Task 7: 全量手动验收

**目标：** 确认前 6 个任务合并后满足完整修复目标，且没有引入构建失败、运行崩溃或关键路径回归。

**涉及的文件：**

- 所有前序任务修改过的文件 — 进行集成验证

------

#### Step 1 — 实现

本任务不修改代码。只进行集成验证。若验证失败，回到对应任务修复实现，然后重新运行本任务验证。

------

#### Step 2 — 运行验证

运行构建：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：** BUILD SUCCEEDED **
```

运行不带 debug 参数：

```bash
$ /Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-hanoqkjmyestuveeygokcbvdwvnd/Build/Products/Debug/pickpick
# 预期：应用窗口出现；无新增 [pickpick debug] 日志；运行无崩溃
```

运行带 debug 参数：

```bash
$ /Users/wilbur/Library/Developer/Xcode/DerivedData/rawViewer-hanoqkjmyestuveeygokcbvdwvnd/Build/Products/Debug/pickpick --debug
# 预期：应用窗口出现；关键节点出现 [pickpick debug] 日志；运行无崩溃
```

手动验收清单：

1. 非法 `config.yaml`：`metal_concurrency: 0`、ratio 负数或大于 1 时不崩溃不卡死。
2. 多照片分析：进度 completedCount 和百分比单调递增。
3. 普通 Browser 删除：删除后返回分组页不再显示旧照片。
4. Duplicate keepLeft / keepRight / keepBoth：操作成功推进；失败弹 alert；返回分组页状态一致。
5. RAW 不存在或无法解码：主图区域显示错误文本。
6. Browser source 切换：重新进入其他组后选择保持一致。
7. 损坏 `analysis.json`：重新分析而不是直接错误页。

✅ **完成的标志：** 构建通过；应用启动无异常；以上 7 项手动验收全部符合预期。

---

## 自我复审记录

### 规范覆盖

- 配置校验、JPG 资源保护：Task 2
- Metal context throwing、encoder guard、RAW DR：Task 3
- EXIF DateFormatter、进度计数、MainActor UI：Task 4
- Review 事务、删除同步、重复比较错误：Task 5
- 错误文本、source 持久化、损坏缓存恢复：Task 6
- 构建与手动验收：Task 7
- Debug 日志基础设施：Task 1

### 占位符扫描

计划中没有占位符、未定义任务、测试框架命令或 Git 命令。

### 类型一致性

- `appDebugLogger.log` 在 Task 1 定义，并在后续 task 使用。
- `jsonReviewStateStoring.update` 在 Task 5 定义，并在 browser/duplicate ViewModel 中使用。
- `metalAnalysisContext.shared` 从属性改为 throwing 方法，raw/jpg analyzer 通过 `contextProvider` 获取。

### 验证完整性

每个任务都包含构建命令；涉及运行行为的任务包含手动验证步骤和明确预期。未安排 XCTest、Pytest、Jest、Vitest、unittest 或其他测试框架。
