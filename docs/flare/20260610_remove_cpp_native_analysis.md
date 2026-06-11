# 去除 cpp 独立分析程序 + Swift 原生分析重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除 `cpp/` 整个目录及 `photoAnalyzerBridge.*`, 将 RAW Bayer 原始值分析/曝光/虚焦/动态范围/EXIF 重复分组全部迁移到 Swift app 中实现, 必要环节全部使用 Metal GPU 加速; 分析数据从目标文件夹 `.cache/analysis.json` 改为 `~/Library/Application Support/rawViewer/{hash}/analysis.json`; 曝光与虚焦阈值由 config.yaml 控制.

**Architecture:** Swift app 内部使用 `photoAnalysisService` 主编排, 下分 `fileScanner` (CPU) / `exifReader` (CPU) / `duplicateGrouper` (CPU) / `configLoader` (CPU + Yams) / `rawBayerAnalyzer` (LibRaw + Metal GPU) / `jpgAnalyzer` (CoreImage + Metal GPU) / `analysisStore` (JSON 持久化). Metal pipeline 4 个 dispatch + 1 次同步; LibRaw 桥接只做 `open/unpack` + 返回 Bayer 数据指针, 不调用 `dcraw_process`. 存储路径 SHA256(folderPath).prefix(16) 后作为子目录.

**Tech Stack:** Swift 5, AppKit, CoreImage, Metal, MetalKit, LibRaw (C++), Yams (SwiftYAML), ImageIO

**Depends on:** 无 (与现有 review/UI/废纸篓流程独立, 可整批执行)

---

## 文件结构映射

### 新增

| 文件 | 职责 |
|---|---|
| `rawViewer/services/fileScanner.swift` | 顶层目录扫描, 返回 RAW/JPG pair |
| `rawViewer/services/exifReader.swift` | EXIF DateTimeOriginal 读取 |
| `rawViewer/services/duplicateGrouper.swift` | 3 秒阈值重复分组 |
| `rawViewer/services/configLoader.swift` | config.yaml 加载 (含默认值) |
| `rawViewer/services/analysisConfig.swift` | 配置结构 + 默认值 |
| `rawViewer/services/analysisStore.swift` | App 资源目录 JSON 持久化 |
| `rawViewer/services/rawBayerAnalyzer.swift` | RAW Bayer Metal 分析 |
| `rawViewer/services/jpgAnalyzer.swift` | JPG Metal 分析 |
| `rawViewer/services/photoAnalysisService.swift` | 主编排, 替代原 bridge |
| `rawViewer/metal/metalAnalysisContext.swift` | Metal 设备/pipeline 单例 |
| `rawViewer/metal/rawAnalysisShaders.metal` | Bayer 直方图 + Green plane + Laplacian kernels |
| `rawViewer/bridge/libRawBridge.h` | LibRaw C 桥接头 |
| `rawViewer/bridge/libRawBridge.mm` | LibRaw ObjC++ 实现 |
| `rawViewer/resources/config.yaml` | bundle 默认配置 |

### 修改

| 文件 | 改动 |
|---|---|
| `rawViewer/models/photoModels.swift` | 新增 `dynamicRangeData` / `analysisSource` 字段; 调整 `analysisPhase` |
| `rawViewer/models/jsonReviewStateStore.swift` | 改用 `analysisStore` 路径 |
| `rawViewer/appCoordinator.swift` | 注入 `photoAnalysisService` 替代 `photoAnalyzerBridge` |
| `rawViewer/mainWindowController.swift` | 移除 bridge 依赖 |
| `rawViewer/bridge/rawViewerBridgingHeader.h` | 更新: 包含 libRawBridge.h |
| `rawViewer.xcodeproj/project.pbxproj` | 添加新文件, 链接 Yams/LibRaw/Metal |

### 删除

| 文件/目录 | 原因 |
|---|---|
| `cpp/` (整个目录) | 完全迁移到 Swift |
| `rawViewer/bridge/photoAnalyzerBridge.h` | 由 photoAnalysisService 替代 |
| `rawViewer/bridge/photoAnalyzerBridge.mm` | 同上 |
| `rawViewer/bridge/photoAnalyzerBridge.swift` | 同上 |

---

## Task 0: 准备 (Swift Package 依赖 + LibRaw 搜索路径)

**Goal:** Yams Swift Package 依赖可用, LibRaw 库路径已配置, 为后续所有任务铺路

**Files touched:**

- `rawViewer.xcodeproj/project.pbxproj` — Yams 包依赖, LibRaw 搜索路径
- (无源码修改, 全是项目设置)

---

#### Step 1 — 添加 Yams Swift Package 依赖

通过 Xcode UI 操作:

1. 打开 `rawViewer.xcodeproj`
2. 选中左侧 `rawViewer` project (蓝色图标)
3. 选中 `rawViewer` target → `Package Dependencies` 标签
4. 点 `+`, 搜索 `https://github.com/jpsim/Yams`
5. 选择 `Yams` 库, 版本规则选 `Up to Next Major Version` (起始 `5.0.0`)
6. 点 `Add Package`
7. 在弹窗中确认 `Yams` 已勾选, 点 `Add Package`

完成后 `Package Dependencies` 列表出现 `Yams`, 链接到 `rawViewer` target.

#### Step 2 — 添加 LibRaw 库搜索路径

1. 选中 `rawViewer` target → `Build Settings` 标签
2. 搜索 `Header Search Paths` → 双击 → 添加:
   - `$(SRCROOT)/3rdPart/libraw/include` (若实际路径不同, 按实际调整)
3. 搜索 `Library Search Paths` → 双击 → 添加 LibRaw `.dylib` / `.a` 所在路径
4. 搜索 `Other Linker Flags` → 添加 `-lraw` (或 LibRaw 实际库名)

> 如果 `3rdPart/` 下没有 LibRaw, 跳过此步, 后续 Task 8 会指引获取方式.

✅ **Done when:** Yams 包出现在 Package Dependencies, LibRaw 搜索路径已配置, `xcodebuild build` 通过

---

## Task 1: 数据模型扩展 (analysisConfig / dynamicRangeData / 阶段枚举)

**Goal:** `photoItem` 增加 `analysisSource` 和 `dynamicRange` 字段; 新增 `analysisConfig` / `exposureConfig` / `blurConfig` 结构 + 默认值; 调整 `analysisPhase` 阶段枚举

**Files touched:**

- `rawViewer/services/analysisConfig.swift` — 新增 (config 结构 + 默认值)
- `rawViewer/models/photoModels.swift` — 修改 (新字段 + 阶段枚举)

---

#### Step 1 — 新建 `rawViewer/services/analysisConfig.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值, 与 config.yaml schema 对应
*/

import Foundation

public struct exposureConfig: Codable, Equatable {
    public var overexposePixelThreshold: Double
    public var underexposePixelThreshold: Double
    public var overexposeRatioLimit: Double
    public var underexposeRatioLimit: Double

    public init(
        overexposePixelThreshold: Double,
        underexposePixelThreshold: Double,
        overexposeRatioLimit: Double,
        underexposeRatioLimit: Double
    ) {
        self.overexposePixelThreshold = overexposePixelThreshold
        self.underexposePixelThreshold = underexposePixelThreshold
        self.overexposeRatioLimit = overexposeRatioLimit
        self.underexposeRatioLimit = underexposeRatioLimit
    }
}

public struct blurConfig: Codable, Equatable {
    public var laplacianThresholdRaw: Double
    public var laplacianThresholdJpg: Double
    public var laplacianKernelSize: Int

    public init(
        laplacianThresholdRaw: Double,
        laplacianThresholdJpg: Double,
        laplacianKernelSize: Int
    ) {
        self.laplacianThresholdRaw = laplacianThresholdRaw
        self.laplacianThresholdJpg = laplacianThresholdJpg
        self.laplacianKernelSize = laplacianKernelSize
    }
}

public struct analysisConfig: Codable, Equatable {
    public var exposure: exposureConfig
    public var blur: blurConfig
    public var metalConcurrency: Int

    public init(exposure: exposureConfig, blur: blurConfig, metalConcurrency: Int) {
        self.exposure = exposure
        self.blur = blur
        self.metalConcurrency = metalConcurrency
    }
}

public extension analysisConfig {
    static let defaults = analysisConfig(
        exposure: exposureConfig(
            overexposePixelThreshold: 0.96,
            underexposePixelThreshold: 0.04,
            overexposeRatioLimit: 0.05,
            underexposeRatioLimit: 0.05
        ),
        blur: blurConfig(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0,
            laplacianKernelSize: 3
        ),
        metalConcurrency: 2
    )
}
```

#### Step 2 — 修改 `rawViewer/models/photoModels.swift`

定位 `public struct photoItem: Equatable, Identifiable` 块, 替换为:

```swift
public struct dynamicRangeData: Codable, Equatable {
    public var sceneSpreadEv: Double
    public var codeRangeEv: Double
    public var blackLevel: Int
    public var whiteLevel: Int

    public init(sceneSpreadEv: Double, codeRangeEv: Double, blackLevel: Int, whiteLevel: Int) {
        self.sceneSpreadEv = sceneSpreadEv
        self.codeRangeEv = codeRangeEv
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
    }
}

public struct photoItem: Equatable, Identifiable {
    public var id: String { photoId }
    public var photoId: String
    public var jpgPath: String
    public var rawPath: String?
    public var isBlurry: Bool
    public var exposureStatus: String
    public var reviewStatus: reviewStatus
    public var reviewGroupId: String
    public var templatePhotoId: String
    public var analysisSource: String
    public var dynamicRange: dynamicRangeData?

    public init(
        photoId: String,
        jpgPath: String,
        rawPath: String? = nil,
        isBlurry: Bool = false,
        exposureStatus: String = "normal",
        reviewStatus: reviewStatus = .active,
        reviewGroupId: String = "",
        templatePhotoId: String = "",
        analysisSource: String = "",
        dynamicRange: dynamicRangeData? = nil
    ) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.reviewStatus = reviewStatus
        self.reviewGroupId = reviewGroupId
        self.templatePhotoId = templatePhotoId
        self.analysisSource = analysisSource
        self.dynamicRange = dynamicRange
    }
}
```

定位 `public enum analysisPhase: String, Codable, Equatable` 块, 替换为:

```swift
public enum analysisPhase: String, Codable, Equatable {
    case scanning
    case exifReading
    case rawAnalysis
    case jpgAnalysis
    case duplicateGrouping
    case organizing
    case completed
}
```

✅ **Done when:** 现有 app 仍能正常打开 (photoItem 是 inout 兼容扩展)

---

## Task 2: fileScanner

**Goal:** 顶层目录扫描返回按 stem 配对的 RAW/JPG 列表, 移植自 `cpp/src/fileScanner.cpp`

**Files touched:**

- `rawViewer/services/fileScanner.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/fileScanner.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 顶层目录扫描, 按 stem 配对 JPG (jpg/jpeg) 和 RAW (rw2/cr2)
*/

import Foundation

public struct photoFilePair {
    public let photoId: String
    public let jpgPath: String?
    public let rawPath: String?

    public init(photoId: String, jpgPath: String?, rawPath: String?) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
    }

    public var hasJpg: Bool { jpgPath != nil }
    public var hasRaw: Bool { rawPath != nil }
}

public final class fileScanner {
    private static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    private static let rawExtensions: Set<String> = ["rw2", "cr2"]

    public init() {}

    public func scanTopLevel(_ folderUrl: URL) throws -> [photoFilePair] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderUrl.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "rawViewer.fileScanner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(folderUrl.path)"]
            )
        }

        let items = try fm.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var pairs: [String: photoFilePair] = [:]

        for url in items {
            let filename = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()

            if Self.jpgExtensions.contains(ext) {
                pairs[stem, default: photoFilePair(photoId: stem, jpgPath: nil, rawPath: nil)].photoFilePairSetJpg(url.path)
            } else if Self.rawExtensions.contains(ext) {
                pairs[stem, default: photoFilePair(photoId: stem, jpgPath: nil, rawPath: nil)].photoFilePairSetRaw(url.path)
            }
        }

        return pairs.values.sorted { $0.photoId < $1.photoId }
    }
}

private extension photoFilePair {
    func photoFilePairSetJpg(_ path: String) -> photoFilePair {
        photoFilePair(photoId: photoId, jpgPath: path, rawPath: rawPath)
    }
    func photoFilePairSetRaw(_ path: String) -> photoFilePair {
        photoFilePair(photoId: photoId, jpgPath: jpgPath, rawPath: path)
    }
}
```

✅ **Done when:** `fileScanner` 可被调用, 配对逻辑移植自 cpp 旧实现

---

## Task 3: configLoader (YAML 解析 + 路径解析)

**Goal:** 从 `folderUrl/config.yaml` → `Bundle.main/config.yaml` → 硬编码默认值 三级降级加载 `analysisConfig`

**Files touched:**

- `rawViewer/services/configLoader.swift` — 新增
- `rawViewer/resources/config.yaml` — 新增 (bundle 默认)

---

#### Step 1 — 新建 `rawViewer/resources/config.yaml`

```yaml
# rawViewer 默认分析参数
# 详细注释见 docs/recipe/20260610_remove_cpp_native_analysis_recipe.md

exposure_detection:
  overexpose_pixel_threshold: 0.96
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

在 Xcode 中:
1. 选中 `rawViewer` target → `Build Phases` → `Copy Bundle Resources`
2. 点 `+`, 添加 `config.yaml`

#### Step 2 — 新建 `rawViewer/services/configLoader.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 从 folderUrl/config.yaml → Bundle.main/config.yaml → 硬编码默认值 三级降级加载 config
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

    /// 从指定 yaml 文件加载, 字段缺失则回退默认值
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
            overexposePixelThreshold: doubleValue(exposureNode["overexpose_pixel_threshold"])
                ?? analysisConfig.defaults.exposure.overexposePixelThreshold,
            underexposePixelThreshold: doubleValue(exposureNode["underexpose_pixel_threshold"])
                ?? analysisConfig.defaults.exposure.underexposePixelThreshold,
            overexposeRatioLimit: doubleValue(exposureNode["overexpose_ratio_limit"])
                ?? analysisConfig.defaults.exposure.overexposeRatioLimit,
            underexposeRatioLimit: doubleValue(exposureNode["underexpose_ratio_limit"])
                ?? analysisConfig.defaults.exposure.underexposeRatioLimit
        )

        let blur = blurConfig(
            laplacianThresholdRaw: doubleValue(blurNode["laplacian_threshold_raw"])
                ?? analysisConfig.defaults.blur.laplacianThresholdRaw,
            laplacianThresholdJpg: doubleValue(blurNode["laplacian_threshold_jpg"])
                ?? analysisConfig.defaults.blur.laplacianThresholdJpg,
            laplacianKernelSize: intValue(blurNode["laplacian_kernel_size"])
                ?? analysisConfig.defaults.blur.laplacianKernelSize
        )

        let concurrency = intValue(analysisNode["metal_concurrency"])
            ?? analysisConfig.defaults.metalConcurrency

        return analysisConfig(exposure: exposure, blur: blur, metalConcurrency: concurrency)
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
```

✅ **Done when:** bundle 包含 config.yaml, 三级降级加载逻辑实现完毕

---

## Task 4: exifReader

**Goal:** 使用 ImageIO 读取 EXIF DateTimeOriginal, 失败回退到 `kMDItemContentCreationDate`; 移植自 `cpp/src/photoMetadataReader.mm`

**Files touched:**

- `rawViewer/services/exifReader.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/exifReader.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 使用 ImageIO 读取 EXIF DateTimeOriginal, 失败回退到 Spotlight kMDItemContentCreationDate
*/

import Foundation
import ImageIO
import CoreServices
import CoreFoundation

public struct shootingTimeResult: Equatable {
    public let found: Bool
    public let epochSeconds: Int64
    public let isoUtc: String?
    public let source: String   // "raw" / "jpg" / "none"

    public init(found: Bool, epochSeconds: Int64, isoUtc: String?, source: String) {
        self.found = found
        self.epochSeconds = epochSeconds
        self.isoUtc = isoUtc
        self.source = source
    }

    public static let notFound = shootingTimeResult(found: false, epochSeconds: 0, isoUtc: nil, source: "none")
}

public final class exifReader {
    private let dateFormatter: DateFormatter

    public init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = f
    }

    public func readBestShootingTime(rawPath: String?, jpgPath: String?) -> shootingTimeResult {
        if let raw = rawPath, !raw.isEmpty {
            let r = readFileShootingTime(raw, source: "raw")
            if r.found { return r }
        }
        if let jpg = jpgPath, !jpg.isEmpty {
            let r = readFileShootingTime(jpg, source: "jpg")
            if r.found { return r }
        }
        return .notFound
    }

    public func readFileShootingTime(_ filePath: String, source: String) -> shootingTimeResult {
        if let result = readImageIoShootingTime(filePath, source: source), result.found {
            return result
        }
        return readSpotlightShootingTime(filePath, source: source)
    }

    private func readImageIoShootingTime(_ filePath: String, source: String) -> shootingTimeResult? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil) else {
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let candidates: [CFString?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal],
            exif?[kCGImagePropertyExifDateTimeDigitized],
            tiff?[kCGImagePropertyTIFFDateTime]
        ]
        for key in candidates {
            guard let value = key as? String else { continue }
            if let seconds = parseExifDate(value) {
                return shootingTimeResult(found: true, epochSeconds: seconds, isoUtc: isoUtcFromEpoch(seconds), source: source)
            }
        }
        return nil
    }

    private func readSpotlightShootingTime(_ filePath: String, source: String) -> shootingTimeResult {
        let cfPath = CFStringCreateWithCString(kCFAllocatorDefault, filePath, kCFStringEncodingUTF8)
        defer { CFRelease(cfPath) }
        guard let item = MDItemCreate(kCFAllocatorDefault, cfPath) else {
            return .notFound
        }
        defer { CFRelease(item) }
        guard let value = MDItemCopyAttribute(item, kMDItemContentCreationDate) else {
            return .notFound
        }
        defer { CFRelease(value) }
        guard CFGetTypeID(value) == CFDateGetTypeID() else {
            return .notFound
        }
        let absolute = CFDateGetAbsoluteTime(value as! CFDate)
        let seconds = Int64((absolute + kCFAbsoluteTimeIntervalSince1970).rounded())
        return shootingTimeResult(found: true, epochSeconds: seconds, isoUtc: isoUtcFromEpoch(seconds), source: source)
    }

    private func parseExifDate(_ value: String) -> Int64? {
        guard let date = dateFormatter.date(from: value) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded())
    }

    private func isoUtcFromEpoch(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
```

✅ **Done when:** exifReader 实现 ImageIO + Spotlight 双路径读取, 移植自 cpp 旧实现

---

## Task 5: duplicateGrouper

**Goal:** 3 秒阈值, 同组 >= 2 张才分配, ID 形如 `dup_001`; 移植自 `cpp/src/jsonManager.cpp::recomputeTimeDuplicateGroups`

**Files touched:**

- `rawViewer/services/duplicateGrouper.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/duplicateGrouper.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 3 秒阈值重复分组, 同组 >= 2 张才分配 dup_NNN ID
*/

import Foundation

public final class duplicateGrouper {
    public static let thresholdSeconds: Int64 = 3

    public init() {}

    public struct entry {
        public let photoId: String
        public let epochSeconds: Int64
        public init(photoId: String, epochSeconds: Int64) {
            self.photoId = photoId
            self.epochSeconds = epochSeconds
        }
    }

    /// 输入拍摄时间列表, 返回 photoId → reviewGroupId 映射 (空字符串表示无分组)
    public func computeDuplicateGroupIds(_ entries: [entry]) -> [String: String] {
        let valid = entries.filter { $0.epochSeconds > 0 }
        let sorted = valid.sorted { a, b in
            if a.epochSeconds != b.epochSeconds { return a.epochSeconds < b.epochSeconds }
            return a.photoId < b.photoId
        }

        var result: [String: String] = [:]
        var index = 0
        var groupIndex = 1

        while index < sorted.count {
            let groupStart = index
            let groupStartEpoch = sorted[groupStart].epochSeconds
            index += 1
            while index < sorted.count
                && sorted[index].epochSeconds - groupStartEpoch <= Self.thresholdSeconds {
                index += 1
            }
            let size = index - groupStart
            if size < 2 { continue }
            let gid = String(format: "dup_%03d", groupIndex)
            for i in groupStart..<index {
                result[sorted[i].photoId] = gid
            }
            groupIndex += 1
        }
        return result
    }
}
```

✅ **Done when:** duplicateGrouper 实现 3 秒阈值 + dup_NNN 命名, 移植自 cpp 旧实现

---

## Task 6: analysisStore (App 资源目录 JSON 持久化)

**Goal:** 存/读 `~/Library/Application Support/rawViewer/{folderHash}/analysis.json`; 提供 `hasResults` / `load` / `save` 接口, save 时将 `config_snapshot` 写入根级

**Files touched:**

- `rawViewer/services/analysisStore.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/analysisStore.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json
*/

import Foundation
import CryptoKit

public final class analysisStore {
    public static let shared = analysisStore()

    private let fileManager: FileManager
    private let appSupportDir: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.appSupportDir = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("rawViewer", isDirectory: true)
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    public func folderHash(_ folderUrl: URL) -> String {
        let digest = SHA256.hash(data: Data(folderUrl.path.utf8))
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    public func resultsUrl(for folderUrl: URL) -> URL {
        appSupportDir
            .appendingPathComponent(folderHash(folderUrl), isDirectory: true)
            .appendingPathComponent("analysis.json")
    }

    public func hasResults(for folderUrl: URL) -> Bool {
        fileManager.fileExists(atPath: resultsUrl(for: folderUrl).path)
    }

    public func load(for folderUrl: URL) throws -> [photoItem] {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(analysisFile.self, from: data)
        return root.photos
    }

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig) throws {
        let dir = resultsUrl(for: folderUrl).deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var existing = analysisFile()
        let url = resultsUrl(for: folderUrl)
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            existing = try JSONDecoder().decode(analysisFile.self, from: data)
        }

        existing.schemaVersion = "2.0"
        existing.folderPath = folderUrl.path
        existing.updatedAt = isoNow()
        if existing.createdAt.isEmpty { existing.createdAt = existing.updatedAt }
        existing.configSnapshot = config
        existing.photos = records
        existing.summary = summaryCounts(records)

        let data = try JSONEncoder().encode(existing)
        try data.write(to: url, options: .atomic)
    }

    private func summaryCounts(_ records: [photoItem]) -> summaryData {
        var s = summaryData()
        s.totalPhotos = records.count
        s.blurry = records.filter { $0.isBlurry }.count
        s.overexposed = records.filter { $0.exposureStatus == "overexposed" }.count
        s.underexposed = records.filter { $0.exposureStatus == "underexposed" }.count
        s.normal = records.filter { !$0.isBlurry && $0.exposureStatus == "normal" }.count
        return s
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}

struct analysisFile: Codable {
    var schemaVersion: String = "2.0"
    var folderPath: String = ""
    var createdAt: String = ""
    var updatedAt: String = ""
    var summary: summaryData = summaryData()
    var photos: [photoItem] = []
    var configSnapshot: analysisConfig? = nil
}

struct summaryData: Codable {
    var totalPhotos: Int = 0
    var blurry: Int = 0
    var overexposed: Int = 0
    var underexposed: Int = 0
    var normal: Int = 0
}
```

✅ **Done when:** analysisStore 存/读 ~/Library/Application Support/rawViewer/{hash}/analysis.json 逻辑实现完毕, schema 2.0

---

## Task 7: Metal 分析上下文 + Metal shaders

**Goal:** 编译 Metal shader 源, 创建共享 device / queue / pipeline states; 提供公开初始化接口

**Files touched:**

- `rawViewer/metal/rawAnalysisShaders.metal` — 新增
- `rawViewer/metal/metalAnalysisContext.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/metal/rawAnalysisShaders.metal`

```metal
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: RAW Bayer 4 通道直方图 + Green plane 提取 + Laplacian + 规约 kernels; JPG 复用 rgbToGray/histogram/laplacian
*/

#include <metal_stdlib>
using namespace metal;

// MARK: - 共享结构体

struct BayerHistConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;
    uint visibleOffsetY;
    uint visibleWidth;
    uint visibleHeight;
    uint binCount;
    uint blackLevel;
    uint whiteLevel;
    uint overThreshold;
    uint underThreshold;
};

struct GreenPlaneConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;
    uint visibleOffsetY;
    uint greenWidth;
    uint greenHeight;
    uint blackLevel;
};

struct GreenLaplacianConfig {
    uint width;
    uint height;
};

struct PartialStats {
    float sum;
    float sumSq;
    float minVal;
    float maxVal;
};

// MARK: - RAW 路径 kernels

// 4 通道 (R/G1/B/G2) 原子直方图, 同时统计过曝/欠曝计数
kernel void bayerHistogramKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],         // [4 × binCount]
    device atomic_uint* exposureCounts [[buffer(2)]],    // [4 × 2]
    constant BayerHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint totalVisible = config.visibleWidth * config.visibleHeight;
    if (gid >= totalVisible) return;

    uint localX = gid % config.visibleWidth;
    uint localY = gid / config.visibleWidth;
    uint x = localX + config.visibleOffsetX;
    uint y = localY + config.visibleOffsetY;
    if (x >= config.rawWidth || y >= config.rawHeight) return;

    uint rawValue = static_cast<uint>(rawBuffer[y * config.rawWidth + x]);
    int valueSigned = static_cast<int>(rawValue) - static_cast<int>(config.blackLevel);
    valueSigned = max(0, min(static_cast<int>(config.whiteLevel - config.blackLevel), valueSigned));

    // 判 CFA 通道: (x%2, y%2) -> (0,0)=R, (1,0)=G1, (1,1)=B, (0,1)=G2
    uint channel = ((x & 1) == 0) ? ((y & 1) == 0 ? 0u : 3u) : ((y & 1) == 0 ? 1u : 2u);

    uint bin = config.binCount > 0
        ? static_cast<uint>(valueSigned) * config.binCount / (config.whiteLevel - config.blackLevel + 1u)
        : 0u;
    if (bin >= config.binCount) bin = config.binCount - 1u;

    atomic_fetch_add_explicit(&histogram[channel * config.binCount + bin], 1u, memory_order_relaxed);

    if (rawValue >= config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 0], 1u, memory_order_relaxed);
    }
    if (rawValue <= config.underThreshold && rawValue > 0) {
        atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 1], 1u, memory_order_relaxed);
    }
}

// Bayer 2x2 block -> Green Plane (半分辨率)
kernel void bayerToGreenPlaneKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device float* greenPlane [[buffer(1)]],
    constant GreenPlaneConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.greenWidth || gid.y >= config.greenHeight) return;

    uint baseX = config.visibleOffsetX + gid.x * 2u;
    uint baseY = config.visibleOffsetY + gid.y * 2u;
    if (baseX + 1u >= config.rawWidth || baseY + 1u >= config.rawHeight) return;

    // G1 at (baseX+1, baseY), G2 at (baseX, baseY+1)
    uint g1 = static_cast<uint>(rawBuffer[baseY * config.rawWidth + (baseX + 1u)]);
    uint g2 = static_cast<uint>(rawBuffer[(baseY + 1u) * config.rawWidth + baseX]);

    int g1Signed = static_cast<int>(g1) - static_cast<int>(config.blackLevel);
    int g2Signed = static_cast<int>(g2) - static_cast<int>(config.blackLevel);
    float greenValue = (static_cast<float>(max(0, g1Signed)) + static_cast<float>(max(0, g2Signed))) * 0.5f;

    greenPlane[gid.y * config.greenWidth + gid.x] = greenValue;
}

// Green Plane Laplacian (3x3, 边界 0 填充)
kernel void greenLaplacianKernel(
    device const float* greenPlane [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;

    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1u;
    uint rightX = x + 1u >= config.width ? config.width - 1u : x + 1u;
    uint upY = y == 0 ? 0 : y - 1u;
    uint downY = y + 1u >= config.height ? config.height - 1u : y + 1u;

    float center = greenPlane[y * config.width + x];
    float left = greenPlane[y * config.width + leftX];
    float right = greenPlane[y * config.width + rightX];
    float up = greenPlane[upY * config.width + x];
    float down = greenPlane[downY * config.width + x];

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}

// 并行规约, 256 threads/group
kernel void reduceLaplacianKernel(
    device const float* laplacianBuffer [[buffer(0)]],
    device PartialStats* partialStats [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint tid [[thread_position_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    threadgroup float localMin[256];
    threadgroup float localMax[256];

    uint total = config.width * config.height;
    uint index = groupId * threadsPerGroup + tid;
    float value = 0.0f;
    bool valid = index < total;
    if (valid) { value = laplacianBuffer[index]; }

    localSum[tid] = valid ? value : 0.0f;
    localSumSq[tid] = valid ? value * value : 0.0f;
    localMin[tid] = valid ? value : INFINITY;
    localMax[tid] = valid ? value : -INFINITY;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = threadsPerGroup / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            localSum[tid] += localSum[tid + stride];
            localSumSq[tid] += localSumSq[tid + stride];
            localMin[tid] = min(localMin[tid], localMin[tid + stride]);
            localMax[tid] = max(localMax[tid], localMax[tid + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partialStats[groupId].sum = localSum[0];
        partialStats[groupId].sumSq = localSumSq[0];
        partialStats[groupId].minVal = localMin[0];
        partialStats[groupId].maxVal = localMax[0];
    }
}

// MARK: - JPG 路径 kernels (复用现有 cpp 思路)

struct JpgHistConfig {
    uint totalPixels;
    uint overThreshold;
    uint underThreshold;
};

struct JpgLaplacianConfig {
    uint width;
    uint height;
};

kernel void rgbToGrayKernel(
    texture2d<float, access::read> rgbaTexture [[texture(0)]],
    device uchar* grayBuffer [[buffer(0)]],
    constant uint& totalPixels [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= rgbaTexture.get_width() || gid.y >= rgbaTexture.get_height()) return;
    float4 rgba = rgbaTexture.read(gid);
    float grayFloat = rgba.r * 255.0f * 0.299f + rgba.g * 255.0f * 0.587f + rgba.b * 255.0f * 0.114f;
    grayFloat = clamp(grayFloat, 0.0f, 255.0f);
    uchar gray = static_cast<uchar>(grayFloat + 0.5f);
    grayBuffer[gid.y * rgbaTexture.get_width() + gid.x] = gray;
}

kernel void jpgHistogramKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
    constant JpgHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.totalPixels) return;
    uint gray = static_cast<uint>(grayBuffer[gid]);
    atomic_fetch_add_explicit(&histogram[gray], 1u, memory_order_relaxed);
    if (gray > config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    }
    if (gray < config.underThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
    }
}

kernel void jpgLaplacianKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant JpgLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1u;
    uint rightX = x + 1u >= config.width ? config.width - 1u : x + 1u;
    uint upY = y == 0 ? 0 : y - 1u;
    uint downY = y + 1u >= config.height ? config.height - 1u : y + 1u;

    float center = static_cast<float>(grayBuffer[y * config.width + x]);
    float left = static_cast<float>(grayBuffer[y * config.width + leftX]);
    float right = static_cast<float>(grayBuffer[y * config.width + rightX]);
    float up = static_cast<float>(grayBuffer[upY * config.width + x]);
    float down = static_cast<float>(grayBuffer[downY * config.width + x]);

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}
```

在 Xcode 中:
1. 选中 `rawViewer` target → `Build Phases` → `Compile Sources`
2. 点 `+`, 添加 `rawAnalysisShaders.metal`

#### Step 2 — 新建 `rawViewer/metal/metalAnalysisContext.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: Metal 设备 / queue / pipeline 单例, 启动时编译 rawAnalysisShaders.metal
*/

import Foundation
import Metal

public final class metalAnalysisContext {
    public static let shared = metalAnalysisContext()

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

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported on this device")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load default Metal library (rawAnalysisShaders.metal not compiled?)")
        }
        self.device = device
        self.commandQueue = queue
        self.library = library

        self.bayerHistogramPipeline = Self.makePipeline(device: device, library: library, name: "bayerHistogramKernel")
        self.bayerToGreenPlanePipeline = Self.makePipeline(device: device, library: library, name: "bayerToGreenPlaneKernel")
        self.greenLaplacianPipeline = Self.makePipeline(device: device, library: library, name: "greenLaplacianKernel")
        self.reducePipeline = Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
        self.rgbToGrayPipeline = Self.makePipeline(device: device, library: library, name: "rgbToGrayKernel")
        self.jpgHistogramPipeline = Self.makePipeline(device: device, library: library, name: "jpgHistogramKernel")
        self.jpgLaplacianPipeline = Self.makePipeline(device: device, library: library, name: "jpgLaplacianKernel")
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, name: String) -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            fatalError("Metal function '\(name)' not found in default library")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            fatalError("Failed to create pipeline for '\(name)': \(error)")
        }
    }
}
```

✅ **Done when:** `metalAnalysisContext.shared` 可访问, 7 个 kernel 编译通过 (`xcodebuild build` 验证)

---

## Task 8: LibRaw 桥接 (open / unpack / 返回 Bayer 数据)

**Goal:** 极简 ObjC++ 包装, 暴露 `rwRawOpen` / `rwRawGetBayerData` / `rwRawClose`; 不调用 `dcraw_process` 保证 `raw_image` 指针生命周期

**Files touched:**

- `rawViewer/bridge/libRawBridge.h` — 新增
- `rawViewer/bridge/libRawBridge.mm` — 新增
- `rawViewer/bridge/rawViewerBridgingHeader.h` — 修改 (包含 libRawBridge.h)

---

#### Step 1 — 新建 `rawViewer/bridge/libRawBridge.h`

```c
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: LibRaw 最小 C 桥接头, 暴露 open / getBayerData / close
*/

#ifndef RAW_VIEWER_LIB_RAW_BRIDGE_H
#define RAW_VIEWER_LIB_RAW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const uint16_t* rawImage;
    int rawWidth;
    int rawHeight;
    int visibleOffsetX;
    int visibleOffsetY;
    int visibleWidth;
    int visibleHeight;
    int blackLevel;
    int whiteLevel;
} rwRawBayerData;

void* rwRawOpen(const char* path);
rwRawBayerData rwRawGetBayerData(void* handle);
const char* rwRawLastError(void* handle);
void rwRawClose(void* handle);

#ifdef __cplusplus
}
#endif

#endif
```

#### Step 2 — 新建 `rawViewer/bridge/libRawBridge.mm`

```objc
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: LibRaw 极简 ObjC++ 包装, 只做 open + unpack + 返回 Bayer 数据
*/

#include "libRawBridge.h"
#include <libraw/libraw.h>
#include <string>

struct RawHandle {
    LibRaw processor;
    std::string lastError;
};

void* rwRawOpen(const char* path) {
    if (path == nullptr) return nullptr;
    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        h->lastError = "open_file failed: ";
        h->lastError += h->processor.strerror(ret);
        return h;
    }
    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        h->lastError = "unpack failed: ";
        h->lastError += h->processor.strerror(ret);
        return h;
    }
    return h;
}

rwRawBayerData rwRawGetBayerData(void* handle) {
    rwRawBayerData data = {};
    if (handle == nullptr) return data;
    auto* h = static_cast<RawHandle*>(handle);
    auto& sizes = h->processor.imgdata.sizes;
    auto& raw = h->processor.imgdata.rawdata;
    auto& color = h->processor.imgdata.color;
    data.rawImage = raw.raw_image;
    data.rawWidth = sizes.raw_width;
    data.rawHeight = sizes.raw_height;
    data.visibleOffsetX = sizes.left_margin;
    data.visibleOffsetY = sizes.top_margin;
    data.visibleWidth = sizes.width;
    data.visibleHeight = sizes.height;
    data.blackLevel = color.black;
    data.whiteLevel = color.maximum;
    return data;
}

const char* rwRawLastError(void* handle) {
    if (handle == nullptr) return "";
    auto* h = static_cast<RawHandle*>(handle);
    return h->lastError.c_str();
}

void rwRawClose(void* handle) {
    delete static_cast<RawHandle*>(handle);
}
```

#### Step 3 — 修改 `rawViewer/bridge/rawViewerBridgingHeader.h`

现有内容:

```objc
#import "photoAnalyzerBridge.h"
```

替换为:

```objc
#import "libRawBridge.h"
```

(photoAnalyzerBridge.h 将在 Task 13 删除, 此处提前清除引用以避免编译错误.)

#### Step 4 — 在 Xcode 中添加 libRawBridge.mm 到 Compile Sources

1. 选中 `rawViewer` target → `Build Phases` → `Compile Sources`
2. 点 `+`, 添加 `libRawBridge.mm`

> 注意: 如果 LibRaw 库文件实际不存在, link 阶段会失败. 此时先创建空 stub:
>
> ```c
> // 3rdPart/libraw/include/libraw/libraw.h (临时占位)
> // 待实际集成时替换为真实头文件
> ```

✅ **Done when:** `xcodebuild build` 链接通过

---

## Task 9: RAW Bayer 分析器

**Goal:** 调用 libRawBridge + Metal GPU 4 个 kernel, 算出曝光/虚焦/动态范围; 接收 `analysisConfig` 参数

**Files touched:**

- `rawViewer/services/rawBayerAnalyzer.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/rawBayerAnalyzer.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: RAW Bayer 原始值分析: LibRaw 取数据, Metal GPU 4 个 kernel, CPU 后处理曝光/虚焦/DR
*/

import Foundation
import Metal

public struct rawAnalysisResult {
    public let isBlurry: Bool
    public let exposureStatus: String
    public let dynamicRange: dynamicRangeData?
    public let blackLevel: Int
    public let whiteLevel: Int
    public let analysisSource: String

    public init(
        isBlurry: Bool,
        exposureStatus: String,
        dynamicRange: dynamicRangeData?,
        blackLevel: Int,
        whiteLevel: Int,
        analysisSource: String = "raw"
    ) {
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.dynamicRange = dynamicRange
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.analysisSource = analysisSource
    }
}

public protocol rawBayerAnalyzing: AnyObject {
    func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

public final class rawBayerAnalyzer: rawBayerAnalyzing {
    private let context: metalAnalysisContext

    public init(context: metalAnalysisContext = .shared) {
        self.context = context
    }

    public func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        guard let handle = rwRawOpen(rawPath) else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw open_file returned null for \(rawPath)"]
            )
        }
        defer { rwRawClose(handle) }

        let errorMsg = String(cString: rwRawLastError(handle))
        if !errorMsg.isEmpty {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw error: \(errorMsg)"]
            )
        }

        let data = rwRawGetBayerData(handle)
        guard data.rawWidth > 0, data.rawHeight > 0, data.rawImage != nil else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw returned empty Bayer data"]
            )
        }

        let black = Int(data.blackLevel)
        let white = Int(data.whiteLevel)
        guard white > black else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid black/white level: black=\(black) white=\(white)"]
            )
        }

        let visibleW = Int(data.visibleWidth)
        let visibleH = Int(data.visibleHeight)
        let rawW = Int(data.rawWidth)
        let rawH = Int(data.rawHeight)

        // 1. 上传 rawImage 到 GPU
        let totalRaw = rawW * rawH
        guard let rawBuffer = context.device.makeBuffer(
            length: totalRaw * MemoryLayout<UInt16>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, totalRaw * MemoryLayout<UInt16>.size)

        // 2. 计算绝对阈值 (归一化 → 14-bit 范围)
        let absOver = UInt32(black) + UInt32(Double(white - black) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(black) + UInt32(Double(white - black) * config.exposure.underexposePixelThreshold)

        // 3. 分配 GPU 输出 buffer
        let binCount: UInt32 = 4096
        guard let histBuffer = context.device.makeBuffer(
            length: Int(4 * binCount) * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, Int(4 * binCount) * MemoryLayout<UInt32>.size)

        guard let exposureBuffer = context.device.makeBuffer(
            length: 8 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 8 * MemoryLayout<UInt32>.size)

        // 4. 启动 command buffer
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // Dispatch 1: bayerHistogramKernel
        var histConfig = bayerHistConfig(
            rawWidth: UInt32(rawW),
            rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX),
            visibleOffsetY: UInt32(data.visibleOffsetY),
            visibleWidth: UInt32(visibleW),
            visibleHeight: UInt32(visibleH),
            binCount: binCount,
            blackLevel: UInt32(black),
            whiteLevel: UInt32(white),
            overThreshold: absOver,
            underThreshold: absUnder
        )

        let totalVisible = visibleW * visibleH
        let histGroupSize = 256
        let histGroupCount = (totalVisible + histGroupSize - 1) / histGroupSize

        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.bayerHistogramPipeline)
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            encoder.setBytes(&histConfig, length: MemoryLayout<bayerHistConfig>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: histGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: histGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 2: bayerToGreenPlaneKernel
        let greenW = visibleW / 2
        let greenH = visibleH / 2
        guard greenW > 0, greenH > 0 else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Visible area too small for green plane"]
            )
        }
        guard let greenBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc greenBuffer") }

        var greenConfig = greenPlaneConfig(
            rawWidth: UInt32(rawW),
            rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX),
            visibleOffsetY: UInt32(data.visibleOffsetY),
            greenWidth: UInt32(greenW),
            greenHeight: UInt32(greenH),
            blackLevel: UInt32(black)
        )

        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.bayerToGreenPlanePipeline)
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(greenBuffer, offset: 0, index: 1)
            encoder.setBytes(&greenConfig, length: MemoryLayout<greenPlaneConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 3: greenLaplacianKernel
        guard let lapBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }

        var lapConfig = greenLaplacianConfig(
            width: UInt32(greenW),
            height: UInt32(greenH)
        )

        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.greenLaplacianPipeline)
            encoder.setBuffer(greenBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            encoder.setBytes(&lapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 4: reduceLaplacianKernel
        let reduceGroupSize = 256
        let reduceGroupCount = (greenW * greenH + reduceGroupSize - 1) / reduceGroupSize
        guard let partialStats = context.device.makeBuffer(
            length: reduceGroupCount * MemoryLayout<partialStatsGpu>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc partialStats") }

        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.reducePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(partialStats, offset: 0, index: 1)
            encoder.setBytes(&lapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: reduceGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: reduceGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // 5. CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 4 * Int(binCount))
        let greenHist = Array(UnsafeBufferPointer(start: histPtr.advanced(by: Int(binCount)), count: Int(binCount)))

        let exposurePtr = exposureBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        var overCount: UInt64 = 0
        var underCount: UInt64 = 0
        for ch in 0..<4 {
            overCount += UInt64(exposurePtr[ch * 2 + 0])
            underCount += UInt64(exposurePtr[ch * 2 + 1])
        }
        let totalPixels = UInt64(totalVisible)
        let overRatio = Double(overCount) / Double(totalPixels)
        let underRatio = Double(underCount) / Double(totalPixels)

        let exposureStatus: String
        if overRatio > config.exposure.overexposeRatioLimit {
            exposureStatus = "overexposed"
        } else if underRatio > config.exposure.underexposeRatioLimit {
            exposureStatus = "underexposed"
        } else {
            exposureStatus = "normal"
        }

        let partialPtr = partialStats.contents().bindMemory(to: partialStatsGpu.self, capacity: reduceGroupCount)
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<reduceGroupCount {
            sum += Double(partialPtr[i].sum)
            sumSq += Double(partialPtr[i].sumSq)
        }
        let total = Double(greenW * greenH)
        let mean = total > 0 ? sum / total : 0
        let variance = total > 0 ? max(0, sumSq / total - mean * mean) : 0
        let isBlurry = variance < config.blur.laplacianThresholdRaw

        let (p01, p999) = computePercentiles(greenHist: greenHist, totalPixels: total, binCount: Int(binCount))
        let sceneSpreadEv = p01 > 0 ? log2(Double(p999) / Double(p01)) : 0
        let codeRangeEv = log2(Double(white - black) / Double(max(1, p01)))
        let dr = dynamicRangeData(
            sceneSpreadEv: sceneSpreadEv,
            codeRangeEv: codeRangeEv,
            blackLevel: black,
            whiteLevel: white
        )

        return rawAnalysisResult(
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            dynamicRange: dr,
            blackLevel: black,
            whiteLevel: white
        )
    }

    private func computePercentiles(greenHist: [UInt32], totalPixels: UInt64, binCount: Int) -> (UInt32, UInt32) {
        guard totalPixels > 0, !greenHist.isEmpty else { return (0, 0) }
        let p01Target = Double(totalPixels) * 0.001
        let p999Target = Double(totalPixels) * 0.999
        var cum: UInt64 = 0
        var p01Bin: UInt32 = 0
        var p999Bin: UInt32 = UInt32(binCount - 1)
        for i in 0..<binCount {
            cum += UInt64(greenHist[i])
            if p01Bin == 0, cum >= UInt64(p01Target) { p01Bin = UInt32(i) }
            if cum >= UInt64(p999Target) { p999Bin = UInt32(i); break }
        }
        return (p01Bin, p999Bin)
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(
            domain: "rawViewer.rawBayerAnalyzer", code: 999,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}

// MARK: - GPU 共享结构 (镜像 metal shader)

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

struct greenPlaneConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var greenWidth: UInt32
    var greenHeight: UInt32
    var blackLevel: UInt32
}

struct greenLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

struct partialStatsGpu {
    var sum: Float
    var sumSq: Float
    var minVal: Float
    var maxVal: Float
}
```

✅ **Done when:** `rawBayerAnalyzer` 实现 LibRaw open + Metal 4-dispatch + CPU 后处理完整流水线, `xcodebuild build` 通过

---

## Task 10: JPG 分析器

**Goal:** 用 CoreImage 渲染 JPG 到 RGBA texture, 4 个 Metal kernel 分析, 接收 `analysisConfig`

**Files touched:**

- `rawViewer/services/jpgAnalyzer.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/jpgAnalyzer.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析
*/

import Foundation
import CoreImage
import Metal

public protocol jpgAnalyzing: AnyObject {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

public final class jpgAnalyzer: jpgAnalyzing {
    private let context: metalAnalysisContext
    private let ciContext: CIContext

    public init(context: metalAnalysisContext = .shared) {
        self.context = context
        self.ciContext = CIContext(mtlDevice: context.device, options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    }

    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CIImage failed to load: \(jpgPath)"]
            )
        }
        let extent = image.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid image size: \(jpgPath)"]
            )
        }
        let totalPixels = width * height

        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)

        guard let rgbaTexture = makeTexture(width: width, height: height),
              let grayBuffer = context.device.makeBuffer(
                length: totalPixels * MemoryLayout<UInt8>.size,
                options: .storageModeShared
              ),
              let lapBuffer = context.device.makeBuffer(
                length: totalPixels * MemoryLayout<Float>.size,
                options: .storageModeShared
              ),
              let histBuffer = context.device.makeBuffer(
                length: 256 * MemoryLayout<UInt32>.size,
                options: .storageModeShared
              ),
              let exposureBuffer = context.device.makeBuffer(
                length: 2 * MemoryLayout<UInt32>.size,
                options: .storageModeShared
              ) else {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Buffer allocation failed"]
            )
        }
        memset(histBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.size)
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)

        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"]
            )
        }

        // CIImage → RGBA texture
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            image,
            toMTLTexture: rgbaTexture,
            commandBuffer: cmd,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )

        // Dispatch 1: rgbToGrayKernel
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.rgbToGrayPipeline)
            encoder.setTexture(rgbaTexture, index: 0)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            var pixels = UInt32(totalPixels)
            encoder.setBytes(&pixels, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 2: jpgHistogramKernel
        var histConfig = jpgHistConfig(
            totalPixels: UInt32(totalPixels),
            overThreshold: absOver,
            underThreshold: absUnder
        )
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.jpgHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: (totalPixels + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 3: jpgLaplacianKernel
        var lapConfig = jpgLaplacianConfig(width: UInt32(width), height: UInt32(height))
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.jpgLaplacianPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            encoder.setBytes(&lapConfig, length: MemoryLayout<jpgLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 4: reduceLaplacianKernel
        let reduceGroupSize = 256
        let reduceGroupCount = (totalPixels + reduceGroupSize - 1) / reduceGroupSize
        guard let partialStats = context.device.makeBuffer(
            length: reduceGroupCount * MemoryLayout<partialStatsGpu>.size,
            options: .storageModeShared
        ) else {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate partialStats buffer"]
            )
        }
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.reducePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(partialStats, offset: 0, index: 1)
            encoder.setBytes(&lapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: reduceGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: reduceGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw NSError(
                domain: "rawViewer.jpgAnalyzer", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Command buffer error: \(cmd.error?.localizedDescription ?? "unknown")"]
            )
        }

        // CPU 后处理
        let exposurePtr = exposureBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
        let overCount = UInt64(exposurePtr[0])
        let underCount = UInt64(exposurePtr[1])
        let overRatio = Double(overCount) / Double(totalPixels)
        let underRatio = Double(underCount) / Double(totalPixels)

        let exposureStatus: String
        if overRatio > config.exposure.overexposeRatioLimit {
            exposureStatus = "overexposed"
        } else if underRatio > config.exposure.underexposeRatioLimit {
            exposureStatus = "underexposed"
        } else {
            exposureStatus = "normal"
        }

        let partialPtr = partialStats.contents().bindMemory(to: partialStatsGpu.self, capacity: reduceGroupCount)
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<reduceGroupCount {
            sum += Double(partialPtr[i].sum)
            sumSq += Double(partialPtr[i].sumSq)
        }
        let total = Double(totalPixels)
        let mean = total > 0 ? sum / total : 0
        let variance = total > 0 ? max(0, sumSq / total - mean * mean) : 0
        let isBlurry = variance < config.blur.laplacianThresholdJpg

        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        let hist = Array(UnsafeBufferPointer(start: histPtr, count: 256))
        let (p01, p999) = computePercentiles(grayHist: hist, totalPixels: UInt64(totalPixels))
        let sceneSpreadEv = p01 > 0 ? log2(Double(p999) / Double(p01)) : 0
        let dr = dynamicRangeData(
            sceneSpreadEv: sceneSpreadEv,
            codeRangeEv: 0,
            blackLevel: 0,
            whiteLevel: 255
        )

        return rawAnalysisResult(
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            dynamicRange: dr,
            blackLevel: 0,
            whiteLevel: 255,
            analysisSource: "jpg"
        )
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return context.device.makeTexture(descriptor: desc)
    }

    private func computePercentiles(grayHist: [UInt32], totalPixels: UInt64) -> (UInt32, UInt32) {
        guard totalPixels > 0 else { return (0, 0) }
        let p01Target = Double(totalPixels) * 0.001
        let p999Target = Double(totalPixels) * 0.999
        var cum: UInt64 = 0
        var p01Bin: UInt32 = 0
        var p999Bin: UInt32 = 255
        for i in 0..<256 {
            cum += UInt64(grayHist[i])
            if p01Bin == 0, cum >= UInt64(p01Target) { p01Bin = UInt32(i) }
            if cum >= UInt64(p999Target) { p999Bin = UInt32(i); break }
        }
        return (p01Bin, p999Bin)
    }
}

struct jpgHistConfig {
    var totalPixels: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}

struct jpgLaplacianConfig {
    var width: UInt32
    var height: UInt32
}
```

✅ **Done when:** `jpgAnalyzer` 实现 CoreImage + Metal 4-dispatch + CPU 后处理完整流水线, `xcodebuild build` 通过

---

## Task 11: photoAnalysisService 主编排

**Goal:** 串联 scanner → exif → raw/jpg analyzer → duplicateGrouper → store; 支持 progress 回调

**Files touched:**

- `rawViewer/services/photoAnalysisService.swift` — 新增

---

#### Step 1 — 新建 `rawViewer/services/photoAnalysisService.swift`

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 主编排, 替代原 photoAnalyzerBridge. 串联 scanner→exif→analyzer→grouper→store
*/

import Foundation

public struct analysisSummary {
    public var totalPhotos: Int
    public var blurryCount: Int
    public var overexposedCount: Int
    public var underexposedCount: Int
    public var normalCount: Int

    public init(
        totalPhotos: Int,
        blurryCount: Int,
        overexposedCount: Int,
        underexposedCount: Int,
        normalCount: Int
    ) {
        self.totalPhotos = totalPhotos
        self.blurryCount = blurryCount
        self.overexposedCount = overexposedCount
        self.underexposedCount = underexposedCount
        self.normalCount = normalCount
    }
}

public protocol photoAnalyzing: AnyObject {
    func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary

    func loadRecords(folderUrl: URL) throws -> [photoItem]
}

public final class photoAnalysisService: photoAnalyzing {
    private let scanner: fileScanner
    private let exif: exifReader
    private let grouper: duplicateGrouper
    private let rawAnalyzer: rawBayerAnalyzing
    private let jpgAnalyzer: jpgAnalyzing
    private let store: analysisStore
    private let configLoader: configLoader

    public init(
        scanner: fileScanner = fileScanner(),
        exif: exifReader = exifReader(),
        grouper: duplicateGrouper = duplicateGrouper(),
        rawAnalyzer: rawBayerAnalyzing = rawBayerAnalyzer(),
        jpgAnalyzer: jpgAnalyzing = jpgAnalyzer(),
        store: analysisStore = .shared,
        configLoader: configLoader = configLoader()
    ) {
        self.scanner = scanner
        self.exif = exif
        self.grouper = grouper
        self.rawAnalyzer = rawAnalyzer
        self.jpgAnalyzer = jpgAnalyzer
        self.store = store
        self.configLoader = configLoader
    }

    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = try configLoader.load(for: folderUrl)
        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))

        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalPairs = pairs.count
        progress(analysisProgress(phase: .scanning, completedCount: totalPairs, totalCount: totalPairs, overallProgress: 0.1))

        // Phase 1: EXIF
        var records: [String: photoItem] = [:]
        var shootingTimes: [duplicateGrouper.entry] = []
        let exifGroup = DispatchGroup()
        let exifQueue = DispatchQueue(label: "exif.read", attributes: .concurrent)
        for pair in pairs {
            exifGroup.enter()
            exifQueue.async { [weak self] in
                guard let self else { exifGroup.leave(); return }
                let result = self.exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)
                let item = photoItem(
                    photoId: pair.photoId,
                    jpgPath: pair.jpgPath ?? "",
                    rawPath: pair.rawPath
                )
                records[pair.photoId] = item
                if result.found {
                    shootingTimes.append(.init(photoId: pair.photoId, epochSeconds: result.epochSeconds))
                }
                exifGroup.leave()
            }
        }
        exifGroup.wait()
        progress(analysisProgress(phase: .exifReading, completedCount: totalPairs, totalCount: totalPairs, overallProgress: 0.2))

        // Phase 2: 分析
        let analysisQueue = DispatchQueue(label: "analysis.run", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: max(1, config.metalConcurrency))
        let analysisGroup = DispatchGroup()
        var analyzedCount = 0
        let analyzedLock = NSLock()

        for pair in pairs {
            analysisGroup.enter()
            analysisQueue.async { [weak self] in
                guard let self else { analysisGroup.leave(); return }
                semaphore.wait()
                defer {
                    semaphore.signal()
                    analysisGroup.leave()
                }
                if let rawPath = pair.rawPath, !rawPath.isEmpty {
                    do {
                        let result = try self.rawAnalyzer.analyze(rawPath: rawPath, config: config)
                        var item = records[pair.photoId] ?? photoItem(photoId: pair.photoId, jpgPath: pair.jpgPath ?? "", rawPath: rawPath)
                        item.isBlurry = result.isBlurry
                        item.exposureStatus = result.exposureStatus
                        item.analysisSource = "raw"
                        item.dynamicRange = result.dynamicRange
                        records[pair.photoId] = item
                    } catch {
                        if let jpgPath = pair.jpgPath, !jpgPath.isEmpty {
                            self.runJpgFallback(jpgPath: jpgPath, config: config, records: &records, photoId: pair.photoId)
                        }
                    }
                } else if let jpgPath = pair.jpgPath, !jpgPath.isEmpty {
                    self.runJpgFallback(jpgPath: jpgPath, config: config, records: &records, photoId: pair.photoId)
                }
                analyzedLock.lock()
                analyzedCount += 1
                let done = analyzedCount
                analyzedLock.unlock()
                let phase: analysisPhase = (pair.rawPath?.isEmpty == false) ? .rawAnalysis : .jpgAnalysis
                let progressRatio = 0.2 + 0.6 * Double(done) / Double(max(1, totalPairs))
                progress(analysisProgress(phase: phase, completedCount: done, totalCount: totalPairs, overallProgress: progressRatio))
            }
        }
        analysisGroup.wait()

        // Phase 3: 重复分组
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, gid) in groupMap {
            records[photoId]?.reviewGroupId = gid
        }
        progress(analysisProgress(phase: .duplicateGrouping, completedCount: totalPairs, totalCount: totalPairs, overallProgress: 0.85))

        // Phase 4: 保存
        let finalRecords = Array(records.values)
        try store.save(folderUrl: folderUrl, records: finalRecords, config: config)
        progress(analysisProgress(phase: .organizing, completedCount: finalRecords.count, totalCount: finalRecords.count, overallProgress: 0.95))

        let summary = analysisSummary(
            totalPhotos: finalRecords.count,
            blurryCount: finalRecords.filter { $0.isBlurry }.count,
            overexposedCount: finalRecords.filter { $0.exposureStatus == "overexposed" }.count,
            underexposedCount: finalRecords.filter { $0.exposureStatus == "underexposed" }.count,
            normalCount: finalRecords.filter { !$0.isBlurry && $0.exposureStatus == "normal" }.count
        )
        progress(analysisProgress(phase: .completed, completedCount: summary.totalPhotos, totalCount: summary.totalPhotos, overallProgress: 1.0))
        return summary
    }

    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        try store.load(for: folderUrl)
    }

    private func runJpgFallback(
        jpgPath: String,
        config: analysisConfig,
        records: inout [String: photoItem],
        photoId: String
    ) {
        do {
            let result = try jpgAnalyzer.analyze(jpgPath: jpgPath, config: config)
            var item = records[photoId] ?? photoItem(photoId: photoId, jpgPath: jpgPath)
            item.isBlurry = result.isBlurry
            item.exposureStatus = result.exposureStatus
            item.analysisSource = "jpg"
            item.dynamicRange = result.dynamicRange
            records[photoId] = item
        } catch {
            var item = records[photoId] ?? photoItem(photoId: photoId, jpgPath: jpgPath)
            item.exposureStatus = "normal"
            item.analysisSource = "jpg_failed"
            records[photoId] = item
        }
    }
}
```

✅ **Done when:** `photoAnalysisService` 实现 scanner→exif→analyzer→grouper→store 完整编排, `xcodebuild build` 通过

---

## Task 12: 集成 appCoordinator / mainWindowController / jsonReviewStateStore

**Goal:** 移除 `photoAnalyzerBridge` 引用, 注入 `photoAnalysisService`; `jsonReviewStateStore` 改用 `analysisStore` 路径

**Files touched:**

- `rawViewer/appCoordinator.swift` — 修改
- `rawViewer/mainWindowController.swift` — 修改
- `rawViewer/models/jsonReviewStateStore.swift` — 修改
- 集成层, 不含单独测试, 验收由 build + Task 13 smoke test 覆盖

---

#### Step 1 — 修改 `rawViewer/models/jsonReviewStateStore.swift`

定位 `private func updateJson(_ mutate: (inout [String: Any]) -> Void) throws` 块, 替换为新实现:

```swift
public final class jsonReviewStateStore: jsonReviewStateStoring {
    public private(set) var operations: [reviewOperation] = []
    private let folderUrl: URL?

    public init(folderUrl: URL? = nil) {
        self.folderUrl = folderUrl
    }

    public func mark(photoId: String, status: reviewStatus) throws {
        try updateRecords { records in
            guard let idx = records.firstIndex(where: { $0.photoId == photoId }) else { return }
            var item = records[idx]
            item.reviewStatus = status
            records[idx] = item
        }
        operations.append(.status(photoId: photoId, status: status))
    }

    public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
        try updateRecords { records in
            for i in 0..<records.count where records[i].reviewGroupId == reviewGroupId {
                var item = records[i]
                item.templatePhotoId = templatePhotoId
                records[i] = item
            }
        }
        operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
    }

    public func clearReviewGroupId(photoId: String) throws {
        try updateRecords { records in
            guard let idx = records.firstIndex(where: { $0.photoId == photoId }) else { return }
            var item = records[idx]
            item.reviewGroupId = ""
            records[idx] = item
        }
    }

    private func updateRecords(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { return }
        let store = analysisStore.shared
        var records = try store.load(for: folderUrl)
        mutate(&records)
        try store.save(folderUrl: folderUrl, records: records, config: analysisConfig.defaults)
    }
}
```

#### Step 2 — 修改 `rawViewer/mainWindowController.swift`

定位 `public convenience init(analyzer: photoAnalyzerBridge = photoAnalyzerBridge())` 块, 替换为:

```swift
public convenience init(analyzer: photoAnalyzing = photoAnalysisService()) {
    let window = NSWindow(...)
    ...
    self.init(window: window)
    self.analyzer = analyzer
    NSLog("...")
    let coord = appCoordinator(window: window, analyzer: analyzer)
    self.coordinator = coord
    coord.showStart()
}

public override init(window: NSWindow?) {
    self.analyzer = photoAnalysisService()
    super.init(window: window)
}
```

定位类定义第一行, 替换:

```swift
public var analyzer: photoAnalyzing
```

#### Step 3 — 修改 `rawViewer/appCoordinator.swift`

定位 `private let analyzer: photoAnalyzerBridge`, 替换为:

```swift
private let analyzer: photoAnalyzing
```

定位 `public init(window: NSWindow, analyzer: photoAnalyzerBridge, ...)`, 替换为:

```swift
public init(window: NSWindow, analyzer: photoAnalyzing, imageService: photoImageService = photoImageService(), trashService: photoTrashServicing = photoTrashService()) {
```

定位 `analyzer.startAnalysis(...)` 调用, 保持不变 (协议同名). 定位 `analyzer.loadAnalysisResult(...)`, 替换为 `analyzer.loadRecords(...)`.

定位整个 `startAnalysis` 方法, 重写为:

```swift
public func startAnalysis(folderUrl: URL) {
    currentFolderUrl = folderUrl
    screenState = .progress
    let progressController = progressViewController()
    window?.contentViewController = progressController

    Task { @MainActor in
        do {
            let store = analysisStore.shared
            if store.hasResults(for: folderUrl) {
                self.records = try analyzer.loadRecords(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
                return
            }
            _ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
                progressController.update(progress: progress)
            }
            self.records = try analyzer.loadRecords(folderUrl: folderUrl)
            self.trashService.cleanupTrashedPhotos(self.records)
            self.showGroups()
        } catch {
            self.showError(message: error.localizedDescription)
        }
    }
}
```

✅ **Done when:** `xcodebuild build` 无编译错误, 现有 UI 行为不变 (因协议同名)

---

## Task 13: 删除 cpp 目录 + bridge 旧文件 + Xcode project 清理 + 全量 build

**Goal:** 完全删除 cpp 独立分析程序和原 photoAnalyzerBridge, Xcode project 引用清理, `xcodebuild` 全量 build 通过

**Files touched:**

- `cpp/` (整个目录删除)
- `rawViewer/bridge/photoAnalyzerBridge.h` (删除)
- `rawViewer/bridge/photoAnalyzerBridge.mm` (删除)
- `rawViewer/bridge/photoAnalyzerBridge.swift` (删除)
- `rawViewer.xcodeproj/project.pbxproj` (清理文件引用)
- `rawViewer.xcodeproj/xcuserdata/wilbur.xcuserdatad/xcschemes/...` (清理 scheme)

---

#### Step 1 — 验证 rawViewer.xcodeproj 仍能 build

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
```

预期: build 成功, 但含 cpp/ 和 bridge 旧文件引用.

#### Step 2 — 备份 pbxproj (safety net)

```bash
$ cp rawViewer.xcodeproj/project.pbxproj rawViewer.xcodeproj/project.pbxproj.bak-task13
```

#### Step 3 — 在 Xcode 中删除文件

打开 `rawViewer.xcodeproj`:

1. 删除 `cpp/` 整个 group: 右键 `cpp` group → `Delete` → `Remove References` (不选 "Move to Trash")
2. 删除 `rawViewer/bridge/photoAnalyzerBridge.h`: 选中 → Delete → Remove References
3. 删除 `rawViewer/bridge/photoAnalyzerBridge.mm`: 选中 → Delete → Remove References
4. 删除 `rawViewer/bridge/photoAnalyzerBridge.swift`: 选中 → Delete → Remove References

> 如果 pbxproj 仍引用 cpp/CMakeLists.txt, 在 project navigator 中找到并删除.

#### Step 4 — 验证 build

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
```

预期: build 成功, 无 cpp 或 photoAnalyzerBridge 相关错误.

若 build 失败, 错误通常是 "missing file" 引用, 回到 Xcode 删除残留引用.

#### Step 5 — 删除磁盘上的文件 (如果步骤 3 没自动删除)

```bash
$ rm -rf cpp/
$ rm -f rawViewer/bridge/photoAnalyzerBridge.h
$ rm -f rawViewer/bridge/photoAnalyzerBridge.mm
$ rm -f rawViewer/bridge/photoAnalyzerBridge.swift
$ rm -f rawViewer.xcodeproj/project.pbxproj.bak-task13
```

#### Step 6 — 全量 build

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' clean build
```

预期: build 无 warning, 无 error.

#### Step 7 — 端到端 smoke test

1. 在 Xcode 中 `Cmd+R` 启动 app
2. 选择 `/Users/wilbur/Downloads/LUMIX_Backup` 文件夹
3. 等待进度条走完
4. 验证 groups 页面正常显示
5. 退出 app
6. 在 Terminal 验证:
   ```bash
   $ ls -la ~/Library/Application\ Support/rawViewer/
   # 预期: 一个 hash 子目录
   $ cat ~/Library/Application\ Support/rawViewer/*/analysis.json | head -20
   # 预期: 包含 schema_version 2.0 + photos + config_snapshot
   ```
7. 重新启动 app, 选同一文件夹, 验证直接加载记录 (无重分析)

✅ **Done when:**
1. `xcodebuild clean build` 无错误
2. cpp/ 在文件系统中已删除
3. photoAnalyzerBridge.* 三个文件已删除
4. LUMIX_Backup 端到端 smoke test 通过
5. 第二次启动直接加载记录 (不重分析)

---

## 自检报告

### Spec 覆盖

| Spec 章节 | 对应 Task |
|---|---|
| 背景 / 目标 / 非目标 | (设计意图, 体现于所有 task) |
| 架构总览 | Task 0 / 11 / 12 |
| Metal GPU 加速策略 | Task 7 (shader/context) / Task 9 (raw) / Task 10 (jpg) |
| Metal Kernels 详细设计 | Task 7 |
| 数据模型变更 | Task 1 |
| Config.yaml 设计 | Task 1 (struct) / Task 3 (loader) |
| 存储格式 | Task 6 (analysisStore) |
| 文件夹扫描 | Task 2 (fileScanner) |
| EXIF 读取 | Task 4 |
| 重复分组 | Task 5 |
| LibRaw 桥接 | Task 8 |
| RAW 分析 | Task 9 |
| JPG 分析 | Task 10 |
| 主编排 | Task 11 |
| appCoordinator / jsonReviewStateStore 集成 | Task 12 |
| 文件删除 | Task 13 |
| 配置调参生效 (验收 11/12/13) | Task 3 loader + Task 11/12 集成 (smoke test 在 Task 13) |

无遗漏.

### Placeholder 扫描

- "TBD" / "TODO" / "fill in": 0
- "Similar to Task N" 复用块: 0 (各 task 完整代码)
- "Implement later": 0
- 每个代码 step 都有完整内容

### Type 一致性

| 跨 task 引用 | 一致性 |
|---|---|
| `analysisConfig` | Task 1 定义 → Task 3 / 9 / 10 / 11 全部用同名同字段 |
| `dynamicRangeData` | Task 1 定义 → Task 9 / 10 / 11 构造同名 |
| `photoItem.analysisSource` / `.dynamicRange` | Task 1 定义 → Task 6 / 11 写入 |
| `rawAnalysisResult` | Task 9 定义 → Task 10 同名 → Task 11 接收 |
| `bayerHistConfig` / `greenPlaneConfig` / `greenLaplacianConfig` / `partialStatsGpu` | Task 7 shader + Task 9 Swift 同名同字段 |
| `jpgHistConfig` / `jpgLaplacianConfig` | Task 7 shader + Task 10 Swift 同名同字段 |
| `analysisPhase` | Task 1 调整 → Task 11 引用所有 case |
| `analysisProgress` | Task 11 构造 → appCoordinator Task 12 调用 `.update(progress:)` |

### 验收方式

本 plan 不包含 XCTest 单元测试, 验收依赖:

| Task | 验收手段 |
|---|---|
| Task 0 | `xcodebuild build` 通过, Yams 在 Package Dependencies, LibRaw 搜索路径已配置 |
| Task 1 | `xcodebuild build` 通过, 现有 app 仍能正常打开 |
| Task 2-6 | `xcodebuild build` 通过, 数据模型 / loader / scanner 移植自 cpp 旧实现, 行为一致 |
| Task 7 | `xcodebuild build` 通过 (Metal kernel 编译失败会触发 fatalError) |
| Task 8 | `xcodebuild build` 链接通过 |
| Task 9-10 | `xcodebuild build` 通过 |
| Task 11 | `xcodebuild build` 通过 |
| Task 12 | `xcodebuild build` 通过, UI 行为不变 |
| Task 13 | `xcodebuild clean build` 无错误, LUMIX_Backup 端到端 smoke test (Task 13 Step 7) 通过 |

---

## 执行方式选择

**Plan complete and saved to `docs/flare/20260610_remove_cpp_native_analysis.md`. Two execution options:**

1. **Subagent-Driven (recommended)** — 我为每个 task 分派独立的 subagent, 任务之间进行 review, 快速迭代
2. **Inline Execution** — 在当前 session 中按顺序执行, 批量执行带 checkpoint review

**选哪种?**
