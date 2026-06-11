# 去除 cpp 原生分析重构审查问题修复实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复 `docs/codeReview/20260610_remove_cpp_native.md` 中 Critical + High 问题，使 Swift 原生分析链路的配置、持久化、RAW 错误处理和 percentile 计算达到发布前可接受状态。

**架构：** 本计划只在现有 Swift 原生分析架构上做收口修复，不恢复 cpp，不重写 Metal pipeline。先修配置 schema 与 bundle 资源，再简化 Codable 持久化和 review 写回，随后修 LibRaw bridge、percentile 计算和 `pickpick.` 前缀残留。

**技术栈：** Swift 5、AppKit、Metal、CoreImage、LibRaw ObjC++ bridge、Yams、Xcode project.pbxproj、bash/python 静态验证。

---

## 日志与调试策略

本计划默认不新增 app 运行时打印输出，也不引入 `--debug` 参数基础设施。原因是本轮修复均为配置、模型、持久化、桥接语义和纯函数逻辑收口，不需要新增命令行或运行期诊断输出。

验证阶段使用 `xcodebuild`、`rg`、`python3` 等终端命令输出结果；这些不是 app 运行时打印，不需要接入 `--debug`。

如果后续实施者临时加入 app 运行时诊断日志，必须先实现 `--debug` 控制，并确保无 `--debug` 时不会输出详细日志。

---

## 范围与边界

本轮必须完成：

1. `config.yaml` 改为 Swift ratio schema，并加入 bundle resources。
2. 删除 `laplacianKernelSize` 死配置。
3. `photoItem` 直接 `Codable`，`analysisStore` 删除 `photoItemRecord`。
4. `analysisStore.save` 支持 `config: nil` 保留既有 `configSnapshot`。
5. `jsonReviewStateStore` review 写回不覆盖真实 config。
6. `libRawBridge` 打开或 unpack 失败时释放 handle 并返回 `nullptr`。
7. `rawBayerAnalyzer` / `jpgAnalyzer` percentile 计算改用 Optional 哨兵和最小 target 1。
8. 去掉业务源码中不必要的 `pickpick.` 模块名前缀。

本轮不做：

1. 不引入任何测试框架。
2. 不创建 XCTest、`.test`、`.spec` 文件。
3. 不执行或编排任何 Git 操作。
4. 不重写 Metal shader。
5. 不实现可配置 Laplacian kernel size。
6. 不改 UI 页面结构。
7. 不做旧 `.cache/analysis.json` 迁移。

---

## 文件结构

### 修改文件

| 文件 | 职责 |
|---|---|
| `rawViewer/config.yaml` | app bundle 默认分析配置，改为 Swift ratio schema 2.0 |
| `rawViewer.xcodeproj/project.pbxproj` | 将 `rawViewer/config.yaml` 加入 Copy Bundle Resources |
| `rawViewer/services/analysisConfig.swift` | 分析配置模型，删除未生效的 `laplacianKernelSize` |
| `rawViewer/services/configLoader.swift` | YAML 配置加载，停止解析死配置字段 |
| `rawViewer/models/photoModels.swift` | 让 `photoItem` 直接实现 `Codable` |
| `rawViewer/services/analysisStore.swift` | 删除中间 record，支持保存时保留既有 `configSnapshot`，可选修复 `try!` |
| `rawViewer/models/jsonReviewStateStore.swift` | review 写回调用 `analysisStore.save` 时不覆盖 config |
| `rawViewer/bridge/libRawBridge.h` | 说明 `rawImage` 指针生命周期 |
| `rawViewer/bridge/libRawBridge.mm` | 修复失败返回非空 handle 的错误语义 |
| `rawViewer/services/rawBayerAnalyzer.swift` | 修复 RAW percentile 计算 |
| `rawViewer/services/jpgAnalyzer.swift` | 修复 JPG percentile 计算 |
| `rawViewer/services/photoAnalysisService.swift` | 去掉 `pickpick.jpgAnalyzer()` 前缀，并避免命名遮蔽 |

### 不新增源码文件

本轮不创建新的 Swift/C/ObjC++ 源码文件。

---

## Task 1: 配置 schema 与 bundle 资源收口

**目标：** app 默认配置使用 Swift ratio schema，`Bundle.main.url(forResource: "config", withExtension: "yaml")` 在构建产物中能找到 `config.yaml`。

**涉及的文件：**

- `rawViewer/config.yaml` — 默认配置文件
- `rawViewer/services/analysisConfig.swift` — 配置模型
- `rawViewer/services/configLoader.swift` — 配置解析
- `rawViewer.xcodeproj/project.pbxproj` — Copy Bundle Resources 配置

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/config.yaml` 改为以下完整内容：

```yaml
# pickpick 默认分析参数
# Swift 原生分析 schema 2.0
# exposure_detection 中的像素阈值均为 0.0~1.0 ratio。
# 本文件会被打包进 app bundle，文件夹内 config.yaml 优先级高于本文件。

exposure_detection:
  # 高亮像素阈值，归一化 [0, 1]。
  # RAW: pixel >= blackLevel + threshold * (whiteLevel - blackLevel) 计为高亮。
  # JPG: gray > threshold * 255 计为高亮。
  overexpose_pixel_threshold: 0.96

  # 暗部像素阈值，归一化 [0, 1]。
  # RAW: pixel <= blackLevel + threshold * (whiteLevel - blackLevel) 计为暗部。
  # JPG: gray < threshold * 255 计为暗部。
  underexpose_pixel_threshold: 0.04

  # 高亮像素占比超过该值时判定为过曝。
  overexpose_ratio_limit: 0.05

  # 暗部像素占比超过该值时判定为欠曝。
  underexpose_ratio_limit: 0.05

blur_detection:
  # RAW Bayer Green Plane 拉普拉斯方差阈值。
  # variance < 此值时判定为虚焦。
  laplacian_threshold_raw: 5000.0

  # JPG 8-bit 灰度拉普拉斯方差阈值。
  # variance < 此值时判定为虚焦。
  laplacian_threshold_jpg: 10.0

analysis:
  # 同时进行 Metal 分析的并发数。
  metal_concurrency: 2
```

- [ ] 将 `rawViewer/services/analysisConfig.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值。v1.1 移除未生效的 laplacianKernelSize 死配置，保持 config schema 与 Metal 3x3 kernel 行为一致
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

    public init(
        laplacianThresholdRaw: Double,
        laplacianThresholdJpg: Double
    ) {
        self.laplacianThresholdRaw = laplacianThresholdRaw
        self.laplacianThresholdJpg = laplacianThresholdJpg
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
            laplacianThresholdJpg: 10.0
        ),
        metalConcurrency: 2
    )
}
```

- [ ] 将 `rawViewer/services/configLoader.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 从 folderUrl/config.yaml → Bundle.main/config.yaml → 硬编码默认值三级降级加载 config。v1.1 移除未生效的 laplacian_kernel_size 解析
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
                ?? analysisConfig.defaults.blur.laplacianThresholdJpg
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

- [ ] 使用以下脚本将 `rawViewer/config.yaml` 加入 `rawViewer.xcodeproj/project.pbxproj` 的 Resources build phase。该脚本是幂等的；如果条目已存在，不会重复添加。

```bash
python3 - <<'PY'
from pathlib import Path

path = Path('rawViewer.xcodeproj/project.pbxproj')
text = path.read_text()

build_file_id = 'AA000010000000000000B001'
file_ref_id = 'AA000010000000000000B002'
build_file_line = f'\t\t{build_file_id} /* config.yaml in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* config.yaml */; }};\n'
file_ref_line = f'\t\t{file_ref_id} /* config.yaml */ = {{isa = PBXFileReference; lastKnownFileType = text.yaml; path = rawViewer/config.yaml; sourceTree = SOURCE_ROOT; }};\n'

if build_file_id not in text:
    marker = '/* Begin PBXBuildFile section */\n'
    text = text.replace(marker, marker + build_file_line)

if file_ref_id not in text:
    marker = '/* Begin PBXFileReference section */\n'
    text = text.replace(marker, marker + file_ref_line)

resources_old = '''\t\tD8DB712E2FC92FEA00F93F82 /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
'''
resources_new = resources_old + f'\t\t\t\t{build_file_id} /* config.yaml in Resources */,\n'

if f'{build_file_id} /* config.yaml in Resources */,' not in text:
    text = text.replace(resources_old, resources_new)

path.write_text(text)
PY
```

------

#### Step 2 — 运行验证

- [ ] 验证死配置字段已从 Swift 配置模型和 loader 中删除：

```bash
rg -n "laplacianKernelSize|laplacian_kernel_size" rawViewer/services/analysisConfig.swift rawViewer/services/configLoader.swift rawViewer/config.yaml
# 预期：无输出
```

- [ ] 验证 project 文件中存在 `config.yaml in Resources`：

```bash
rg -n "config.yaml in Resources|path = rawViewer/config.yaml" rawViewer.xcodeproj/project.pbxproj
# 预期：输出包含 config.yaml in Resources 和 path = rawViewer/config.yaml
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

- [ ] 验证构建产物包含 bundle config：

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*pickpick.app/Contents/Resources/config.yaml' -print | tail -n 1
# 预期：输出一个以 pickpick.app/Contents/Resources/config.yaml 结尾的路径
```

如果任一验证失败，先修复本任务涉及文件，再重新运行本任务全部验证命令。

------

✅ **完成的标志：** 构建通过，`laplacianKernelSize` / `laplacian_kernel_size` 不再出现在配置链路，app bundle 中存在 `config.yaml`。

------

## Task 2: 持久化模型改为直接 Codable

**目标：** `analysisStore` 直接读写 `[photoItem]`，不再依赖 `photoItemRecord` 中间结构，也不再出现 `pickpick.reviewStatus`。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — `photoItem` 增加 `Codable`
- `rawViewer/services/analysisStore.swift` — 删除中间 record，保留 configSnapshot 可选写入

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/models/photoModels.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.4
Date: 2026-06-11
Description: 修复 makeVisiblePhotoGroups 中单张 orphan 重复分组的问题，并让 photoItem 支持 Codable 以简化 analysisStore 持久化 schema
*/

import Foundation

public enum displaySource: String, Codable, Equatable {
    case jpg
    case raw
}

public enum reviewStatus: String, Codable, Equatable {
    case active
    case kept
    case passed
    case trashed
}

public enum analysisPhase: String, Codable, Equatable {
    case scanning
    case exifReading
    case rawAnalysis
    case jpgAnalysis
    case duplicateGrouping
    case organizing
    case completed
}

public struct analysisProgress: Equatable {
    public var phase: analysisPhase
    public var completedCount: Int
    public var totalCount: Int
    public var overallProgress: Double

    public init(phase: analysisPhase, completedCount: Int, totalCount: Int, overallProgress: Double) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.overallProgress = overallProgress
    }
}

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

public struct photoItem: Codable, Equatable, Identifiable {
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

public enum photoGroupKind: Equatable {
    case overexposed
    case underexposed
    case blurry
    case normal
    case duplicate(reviewGroupId: String)

    public var title: String {
        switch self {
        case .overexposed: return "Overexposed"
        case .underexposed: return "Underexposed"
        case .blurry: return "Blurry"
        case .normal: return "Normal"
        case .duplicate(let reviewGroupId): return "Duplicate \(reviewGroupId)"
        }
    }

    public var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

public enum groupRoute: Equatable {
    case browser
    case duplicateCompare
}

public struct photoGroup: Equatable, Identifiable {
    public var id: String {
        switch kind {
        case .overexposed: return "overexposed"
        case .underexposed: return "underexposed"
        case .blurry: return "blurry"
        case .normal: return "normal"
        case .duplicate(let reviewGroupId): return "duplicate-\(reviewGroupId)"
        }
    }

    public var kind: photoGroupKind
    public var photos: [photoItem]

    public init(kind: photoGroupKind, photos: [photoItem]) {
        self.kind = kind
        self.photos = photos
    }
}

public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    let groupCounts = Dictionary(grouping: visiblePhotos, by: \.reviewGroupId)
        .filter { !$0.key.isEmpty }
        .mapValues { $0.count }
    let validDuplicateIds = Set(groupCounts.filter { $0.value >= 2 }.keys)

    func isInValidDuplicateGroup(_ photo: photoItem) -> Bool {
        !photo.reviewGroupId.isEmpty && validDuplicateIds.contains(photo.reviewGroupId)
    }

    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter { $0.isBlurry && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && !isInValidDuplicateGroup($0) }, into: &groups)

    for reviewGroupId in validDuplicateIds.sorted() {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}

private func appendGroup(_ kind: photoGroupKind, photos: [photoItem], into groups: inout [photoGroup]) {
    guard !photos.isEmpty else { return }
    groups.append(photoGroup(kind: kind, photos: photos))
}

public final class displaySourceStore {
    private let defaults: UserDefaults
    private let key = "rawViewer.displaySource"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var current: displaySource {
        get {
            guard let value = defaults.string(forKey: key), let source = displaySource(rawValue: value) else {
                return .jpg
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

public enum displayAvailability: Equatable {
    case available(URL)
    case unavailable
}

public func displayUrl(for photo: photoItem, source: displaySource) -> displayAvailability {
    switch source {
    case .jpg:
        return .available(URL(fileURLWithPath: photo.jpgPath))
    case .raw:
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else { return .unavailable }
        return .available(URL(fileURLWithPath: rawPath))
    }
}
```

- [ ] 将 `rawViewer/services/analysisStore.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json。v1.1 直接持久化 Codable photoItem，保存 review 状态时可保留既有 configSnapshot，并避免 Application Support 初始化 try! 崩溃
*/

import Foundation
import CryptoKit

struct analysisFile: Codable {
    var schemaVersion: String = "2.0"
    var folderPath: String = ""
    var createdAt: String = ""
    var updatedAt: String = ""
    var summary: summaryData = summaryData()
    var photos: [photoItem] = []
    var configSnapshot: analysisConfig?
}

struct summaryData: Codable {
    var totalPhotos: Int = 0
    var blurry: Int = 0
    var overexposed: Int = 0
    var underexposed: Int = 0
    var normal: Int = 0
}

public final class analysisStore {
    public static let shared = analysisStore()

    private let fileManager: FileManager
    private let appSupportDir: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        do {
            self.appSupportDir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("rawViewer", isDirectory: true)
        } catch {
            self.appSupportDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rawViewer", isDirectory: true)
        }
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

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
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
        if let config {
            existing.configSnapshot = config
        }
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
```

------

#### Step 2 — 运行验证

- [ ] 验证 `photoItemRecord` 和 `pickpick.reviewStatus` 已删除：

```bash
rg -n "photoItemRecord|pickpick\.reviewStatus" rawViewer/services/analysisStore.swift rawViewer/models/photoModels.swift
# 预期：无输出
```

- [ ] 验证 `photoItem` 已声明为 `Codable`：

```bash
rg -n "public struct photoItem: Codable, Equatable, Identifiable" rawViewer/models/photoModels.swift
# 预期：输出 photoItem 声明所在行
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

如果验证不通过，修复本任务涉及文件后重新运行全部验证命令。

------

✅ **完成的标志：** 构建通过，`analysisStore` 不再包含 `photoItemRecord`，`photoItem` 直接 `Codable`。

------

## Task 3: review 写回保留真实 configSnapshot

**目标：** 用户在 UI 中修改 review 状态或模板照片时，只更新照片记录，不把既有 `configSnapshot` 覆盖成 `analysisConfig.defaults`。

**涉及的文件：**

- `rawViewer/models/jsonReviewStateStore.swift` — review 状态写回
- `rawViewer/services/analysisStore.swift` — 已在 Task 2 提供 `config: analysisConfig? = nil`

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/models/jsonReviewStateStore.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-11
Description: 提供 Swift 侧 review 状态更新接口，使用 analysisStore 替代直接 JSON 文件操作。v1.5 review 状态写回时保留既有 configSnapshot，避免覆盖真实分析配置
*/

import Foundation

public enum reviewOperation: Equatable {
    case status(photoId: String, status: reviewStatus)
    case template(reviewGroupId: String, templatePhotoId: String)
}

public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
}

public final class jsonReviewStateStore: jsonReviewStateStoring {
    public private(set) var operations: [reviewOperation] = []
    private let folderUrl: URL?

    public init(folderUrl: URL? = nil) {
        self.folderUrl = folderUrl
    }

    public func mark(photoId: String, status: reviewStatus) throws {
        try updateRecords { items in
            guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
            items[index].reviewStatus = status
        }
        operations.append(.status(photoId: photoId, status: status))
    }

    public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
        try updateRecords { items in
            for index in items.indices where items[index].reviewGroupId == reviewGroupId {
                items[index].templatePhotoId = templatePhotoId
            }
        }
        operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
    }

    public func clearReviewGroupId(photoId: String) throws {
        try updateRecords { items in
            guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
            items[index].reviewGroupId = ""
        }
    }

    private func updateRecords(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { return }
        var records = try analysisStore.shared.load(for: folderUrl)
        mutate(&records)
        try analysisStore.shared.save(folderUrl: folderUrl, records: records)
    }
}
```

------

#### Step 2 — 运行验证

- [ ] 验证 review 写回不再传 `analysisConfig.defaults`：

```bash
rg -n "analysisConfig\.defaults" rawViewer/models/jsonReviewStateStore.swift
# 预期：无输出
```

- [ ] 验证 `analysisStore.save` 的 config 参数是可选默认值：

```bash
rg -n "func save\(folderUrl: URL, records: \[photoItem\], config: analysisConfig\? = nil\)" rawViewer/services/analysisStore.swift
# 预期：输出 save 函数签名所在行
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

如果验证不通过，修复本任务涉及文件后重新运行全部验证命令。

------

✅ **完成的标志：** 构建通过，`jsonReviewStateStore` 不再使用 `analysisConfig.defaults` 保存 review 修改。

------

## Task 4: 修复 LibRaw bridge 失败返回语义

**目标：** `rwRawOpen` 在 `open_file` 或 `unpack` 失败时释放 handle 并返回 `nullptr`，Swift 侧 RAW fallback 路径语义清晰且不泄漏 handle。

**涉及的文件：**

- `rawViewer/bridge/libRawBridge.h` — bridge 头文件注释
- `rawViewer/bridge/libRawBridge.mm` — bridge 实现

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/bridge/libRawBridge.h` 改为以下完整内容：

```c
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: LibRaw 最小 C 桥接头, 暴露 open / getBayerData / close。v1.1 补充 rawImage 指针生命周期说明
*/

#ifndef RAW_VIEWER_LIB_RAW_BRIDGE_H
#define RAW_VIEWER_LIB_RAW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    // rawImage points to LibRaw internal raw_image.
    // It remains valid after rwRawOpen until rwRawClose.
    // Do not call dcraw_process/recycle/clear_mem before Swift copies it.
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

- [ ] 将 `rawViewer/bridge/libRawBridge.mm` 改为以下完整内容：

```objc
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: LibRaw 极简 ObjC++ 包装, 只做 open + unpack + 返回 Bayer 数据。v1.1 open/unpack 失败时释放 handle 并返回 nullptr
*/

#include "libRawBridge.h"
#include <libraw.h>
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
        delete h;
        return nullptr;
    }

    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        delete h;
        return nullptr;
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

------

#### Step 2 — 运行验证

- [ ] 验证失败路径不再返回 handle：

```bash
python3 - <<'PY'
from pathlib import Path
text = Path('rawViewer/bridge/libRawBridge.mm').read_text()
if 'h->lastError = "open_file failed:' in text or 'h->lastError = "unpack failed:' in text:
    raise SystemExit('FAIL: failure branch still stores lastError and may return handle')
if 'delete h;\n        return nullptr;' not in text:
    raise SystemExit('FAIL: delete h + return nullptr not found')
print('PASS: libRawBridge failure branches return nullptr after deleting handle')
PY
# 预期：PASS: libRawBridge failure branches return nullptr after deleting handle
```

- [ ] 验证 bridge 头文件包含 rawImage 生命周期说明：

```bash
rg -n "rawImage points to LibRaw internal raw_image|It remains valid after rwRawOpen until rwRawClose" rawViewer/bridge/libRawBridge.h
# 预期：输出两行注释
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

如果验证不通过，修复本任务涉及文件后重新运行全部验证命令。

------

✅ **完成的标志：** 构建通过，`rwRawOpen` 失败路径释放 handle 并返回 `nullptr`。

------

## Task 5: 修复 RAW 与 JPG percentile 计算

**目标：** percentile 计算不再用 `0` 作为“未设置”哨兵；空 histogram、全黑图、首个非空 bin 不为 0 的输入都有明确结果。

**涉及的文件：**

- `rawViewer/services/rawBayerAnalyzer.swift` — RAW percentile 计算
- `rawViewer/services/jpgAnalyzer.swift` — JPG percentile 计算

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/services/rawBayerAnalyzer.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: RAW Bayer 原始值分析: LibRaw 取数据, Metal GPU 4 个 kernel, CPU 后处理曝光/虚焦/DR。v1.1 修复 percentile 计算的 0 哨兵问题
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

        // 2. 计算绝对阈值
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

        let (p01, p999) = computePercentiles(greenHist: greenHist, totalPixels: UInt64(greenW * greenH), binCount: Int(binCount))
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
        guard totalPixels > 0, !greenHist.isEmpty, binCount > 0 else { return (0, 0) }
        let p01Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.001)))
        let p999Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.999)))
        var cum: UInt64 = 0
        var p01Bin: UInt32?
        var p999Bin: UInt32?

        for i in 0..<min(binCount, greenHist.count) {
            cum += UInt64(greenHist[i])
            if p01Bin == nil, cum >= p01Target {
                p01Bin = UInt32(i)
            }
            if p999Bin == nil, cum >= p999Target {
                p999Bin = UInt32(i)
                break
            }
        }

        return (
            p01Bin ?? 0,
            p999Bin ?? UInt32(max(0, min(binCount, greenHist.count) - 1))
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(
            domain: "rawViewer.rawBayerAnalyzer", code: 999,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}
```

- [ ] 将 `rawViewer/services/jpgAnalyzer.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析。v1.1 修复 percentile 计算的 0 哨兵问题
*/

import Foundation
import Metal
import CoreImage

// MARK: - Protocol

public protocol jpgAnalyzing: AnyObject {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

// MARK: - GPU 共享结构 (镜像 metal shader)

struct jpgHistConfig {
    var totalPixels: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}

struct jpgLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

// MARK: - Analyzer

public final class jpgAnalyzer: jpgAnalyzing {
    private let context: metalAnalysisContext
    private let ciContext: CIContext

    public init(context: metalAnalysisContext = .shared) {
        self.context = context
        self.ciContext = CIContext(mtlDevice: context.device)
    }

    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        // a. Load CIImage from jpgPath
        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            throw makeError("Failed to load CIImage from \(jpgPath)")
        }

        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else {
            throw makeError("CIImage has zero dimensions")
        }
        let totalPixels = width * height

        // b. Create RGBA8 texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = .shaderRead
        texDesc.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: texDesc) else {
            throw makeError("Failed to create RGBA texture")
        }

        // c. Allocate buffers
        guard let grayBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt8>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc grayBuffer") }

        guard let lapBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }

        guard let histBuffer = context.device.makeBuffer(
            length: 256 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.size)

        guard let exposureBuffer = context.device.makeBuffer(
            length: 2 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)

        // d. Create command buffer
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // e. Render CIImage to texture
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ciImage, to: texture, commandBuffer: cmd, bounds: ciImage.extent, colorSpace: colorSpace)

        // Compute absolute thresholds (0–255 range)
        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)

        // f. Dispatch 1: rgbToGrayPipeline
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.rgbToGrayPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            var totalPx = UInt32(totalPixels)
            encoder.setBytes(&totalPx, length: MemoryLayout<UInt32>.size, index: 1)
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        }

        // g. Dispatch 2: jpgHistogramPipeline
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.jpgHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            var histConfig = jpgHistConfig(
                totalPixels: UInt32(totalPixels),
                overThreshold: absOver,
                underThreshold: absUnder
            )
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
            let histGroupSize = 256
            let histGroupCount = (totalPixels + histGroupSize - 1) / histGroupSize
            encoder.dispatchThreadgroups(
                MTLSize(width: histGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: histGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // h. Dispatch 3: jpgLaplacianPipeline
        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.jpgLaplacianPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            var lapConfig = jpgLaplacianConfig(
                width: UInt32(width),
                height: UInt32(height)
            )
            encoder.setBytes(&lapConfig, length: MemoryLayout<jpgLaplacianConfig>.size, index: 2)
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        }

        // i. Dispatch 4: reducePipeline (reuse from rawBayerAnalyzer)
        let reduceGroupSize = 256
        let reduceGroupCount = (totalPixels + reduceGroupSize - 1) / reduceGroupSize
        guard let partialStats = context.device.makeBuffer(
            length: reduceGroupCount * MemoryLayout<partialStatsGpu>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc partialStats") }

        do {
            let encoder = cmd.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(context.reducePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(partialStats, offset: 0, index: 1)
            var greenLapConfig = greenLaplacianConfig(
                width: UInt32(width),
                height: UInt32(height)
            )
            encoder.setBytes(&greenLapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: reduceGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: reduceGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // j. Commit + wait
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // k. CPU: read exposure counts → determine exposureStatus
        let exposurePtr = exposureBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
        let overCount = UInt64(exposurePtr[0])
        let underCount = UInt64(exposurePtr[1])
        let totalPix = UInt64(totalPixels)
        let overRatio = totalPix > 0 ? Double(overCount) / Double(totalPix) : 0
        let underRatio = totalPix > 0 ? Double(underCount) / Double(totalPix) : 0

        let exposureStatus: String
        if overRatio > config.exposure.overexposeRatioLimit {
            exposureStatus = "overexposed"
        } else if underRatio > config.exposure.underexposeRatioLimit {
            exposureStatus = "underexposed"
        } else {
            exposureStatus = "normal"
        }

        // l. CPU: read partialStats → compute variance → determine isBlurry
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

        // m. CPU: read histogram → compute p01/p999 percentiles → dynamicRangeData
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        let histArray = Array(UnsafeBufferPointer(start: histPtr, count: 256))
        let (p01, p999) = computePercentiles(histogram: histArray, totalPixels: totalPix)

        let sceneSpreadEv = p01 > 0 ? log2(Double(p999) / Double(p01)) : 0
        let codeRangeEv = p01 > 0 ? log2(255.0 / Double(p01)) : 0
        let dr = dynamicRangeData(
            sceneSpreadEv: sceneSpreadEv,
            codeRangeEv: codeRangeEv,
            blackLevel: 0,
            whiteLevel: 255
        )

        // n. Return result
        return rawAnalysisResult(
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            dynamicRange: dr,
            blackLevel: 0,
            whiteLevel: 255,
            analysisSource: "jpg"
        )
    }

    // MARK: - Private helpers

    private func computePercentiles(histogram: [UInt32], totalPixels: UInt64) -> (UInt32, UInt32) {
        guard totalPixels > 0, !histogram.isEmpty else { return (0, 0) }
        let p01Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.001)))
        let p999Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.999)))
        var cum: UInt64 = 0
        var p01Bin: UInt32?
        var p999Bin: UInt32?

        for i in 0..<histogram.count {
            cum += UInt64(histogram[i])
            if p01Bin == nil, cum >= p01Target {
                p01Bin = UInt32(i)
            }
            if p999Bin == nil, cum >= p999Target {
                p999Bin = UInt32(i)
                break
            }
        }

        return (
            p01Bin ?? 0,
            p999Bin ?? UInt32(max(0, histogram.count - 1))
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(
            domain: "rawViewer.jpgAnalyzer", code: 999,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}
```

------

#### Step 2 — 运行验证

- [ ] 验证不再使用 `p01Bin == 0` 作为哨兵：

```bash
rg -n "p01Bin == 0|UInt64\(Int64\(p01Target\)\)|UInt64\(Int64\(p999Target\)\)" rawViewer/services/rawBayerAnalyzer.swift rawViewer/services/jpgAnalyzer.swift
# 预期：无输出
```

- [ ] 验证 percentile 使用 Optional 哨兵：

```bash
rg -n "var p01Bin: UInt32\?|var p999Bin: UInt32\?" rawViewer/services/rawBayerAnalyzer.swift rawViewer/services/jpgAnalyzer.swift
# 预期：两个文件都输出 p01Bin 和 p999Bin Optional 声明
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

如果验证不通过，修复本任务涉及文件后重新运行全部验证命令。

------

✅ **完成的标志：** 构建通过，RAW/JPG percentile 都使用 Optional 哨兵，不再存在 `p01Bin == 0` 逻辑。

------

## Task 6: 去掉 `pickpick.` 前缀并完成全局收口验证

**目标：** 业务源码中不再出现不必要的 `pickpick.` 模块名前缀，完整修复集构建通过，关键静态检查符合预期。

**涉及的文件：**

- `rawViewer/services/photoAnalysisService.swift` — 默认 JPG analyzer 初始化

------

#### Step 1 — 实现

- [ ] 将 `rawViewer/services/photoAnalysisService.swift` 改为以下完整内容：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 主编排, 替代原 photoAnalyzerBridge。v1.1 去除不必要的 pickpick 模块名前缀并避免 jpgAnalyzer 命名遮蔽
*/

import Foundation

// MARK: - Summary

public struct analysisSummary {
    public let totalPhotos: Int
    public let blurryCount: Int
    public let overexposedCount: Int
    public let underexposedCount: Int
    public let normalCount: Int

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

// MARK: - Protocol

public protocol photoAnalyzing: AnyObject {
    func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary

    func loadRecords(folderUrl: URL) throws -> [photoItem]
}

// MARK: - Service

public final class photoAnalysisService: photoAnalyzing {

    private let scanner: fileScanner
    private let exif: exifReader
    private let grouper: duplicateGrouper
    private let rawAnalyzer: rawBayerAnalyzing
    private let jpgAnalyzerService: any jpgAnalyzing
    private let store: analysisStore
    private let cfgLoader: configLoader

    public init(
        scanner: fileScanner = fileScanner(),
        exif: exifReader = exifReader(),
        grouper: duplicateGrouper = duplicateGrouper(),
        rawAnalyzer: rawBayerAnalyzing = rawBayerAnalyzer(),
        jpgAnalyzerService: (any jpgAnalyzing)? = nil,
        store: analysisStore = .shared,
        cfgLoader: configLoader = configLoader()
    ) {
        self.scanner = scanner
        self.exif = exif
        self.grouper = grouper
        self.rawAnalyzer = rawAnalyzer
        self.jpgAnalyzerService = jpgAnalyzerService ?? jpgAnalyzer()
        self.store = store
        self.cfgLoader = cfgLoader
    }

    // MARK: - Analyze

    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = try cfgLoader.load(for: folderUrl)

        // 1. Scanning phase
        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))
        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalCount = pairs.count
        guard totalCount > 0 else {
            progress(analysisProgress(phase: .completed, completedCount: 0, totalCount: 0, overallProgress: 1.0))
            return analysisSummary(totalPhotos: 0, blurryCount: 0, overexposedCount: 0, underexposedCount: 0, normalCount: 0)
        }

        // 2. EXIF reading phase
        progress(analysisProgress(phase: .exifReading, completedCount: 0, totalCount: totalCount, overallProgress: 0.1))
        let recordsLock = NSLock()
        var records: [String: photoItem] = [:]
        var shootingTimes: [duplicateGrouper.entry] = []

        let exifQueue = DispatchQueue(label: "rawViewer.exifReader", attributes: .concurrent)
        let exifGroup = DispatchGroup()

        for (index, pair) in pairs.enumerated() {
            exifGroup.enter()
            exifQueue.async {
                let timeResult = self.exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)

                let item = photoItem(
                    photoId: pair.photoId,
                    jpgPath: pair.jpgPath ?? pair.rawPath ?? "",
                    rawPath: pair.rawPath,
                    analysisSource: ""
                )

                recordsLock.lock()
                records[pair.photoId] = item
                if timeResult.found {
                    shootingTimes.append(duplicateGrouper.entry(photoId: pair.photoId, epochSeconds: timeResult.epochSeconds))
                }
                recordsLock.unlock()

                let completed = index + 1
                let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))

                exifGroup.leave()
            }
        }
        exifGroup.wait()

        // 3. Analysis phase (raw / jpg)
        progress(analysisProgress(phase: .rawAnalysis, completedCount: 0, totalCount: totalCount, overallProgress: 0.2))
        let gpuSemaphore = DispatchSemaphore(value: config.metalConcurrency)
        let analysisQueue = DispatchQueue(label: "rawViewer.analysis", attributes: .concurrent)
        let analysisGroup = DispatchGroup()

        for (index, pair) in pairs.enumerated() {
            analysisGroup.enter()
            analysisQueue.async {
                gpuSemaphore.wait()
                defer { gpuSemaphore.signal() }

                let result: rawAnalysisResult
                if pair.hasRaw, let rawPath = pair.rawPath {
                    do {
                        result = try self.rawAnalyzer.analyze(rawPath: rawPath, config: config)
                    } catch {
                        result = self.runJpgFallback(pair: pair, config: config)
                    }
                } else if pair.hasJpg, let jpgPath = pair.jpgPath {
                    do {
                        result = try self.jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                    } catch {
                        result = rawAnalysisResult(
                            isBlurry: false,
                            exposureStatus: "normal",
                            dynamicRange: nil,
                            blackLevel: 0,
                            whiteLevel: 0,
                            analysisSource: "jpg_failed"
                        )
                    }
                } else {
                    result = rawAnalysisResult(
                        isBlurry: false,
                        exposureStatus: "normal",
                        dynamicRange: nil,
                        blackLevel: 0,
                        whiteLevel: 0,
                        analysisSource: "none"
                    )
                }

                recordsLock.lock()
                if var item = records[pair.photoId] {
                    item.isBlurry = result.isBlurry
                    item.exposureStatus = result.exposureStatus
                    item.dynamicRange = result.dynamicRange
                    item.analysisSource = result.analysisSource
                    records[pair.photoId] = item
                }
                recordsLock.unlock()

                let completed = index + 1
                let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
                let phase: analysisPhase = pair.hasRaw ? .rawAnalysis : .jpgAnalysis
                progress(analysisProgress(phase: phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))

                analysisGroup.leave()
            }
        }
        analysisGroup.wait()

        // 4. Duplicate grouping phase
        progress(analysisProgress(phase: .duplicateGrouping, completedCount: 0, totalCount: totalCount, overallProgress: 0.85))
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, groupId) in groupMap {
            if var item = records[photoId] {
                item.reviewGroupId = groupId
                records[photoId] = item
            }
        }

        // 5. Organizing / save phase
        progress(analysisProgress(phase: .organizing, completedCount: 0, totalCount: totalCount, overallProgress: 0.9))
        let finalRecords = pairs.compactMap { records[$0.photoId] }
        try store.save(folderUrl: folderUrl, records: finalRecords, config: config)

        // 6. Compute summary
        let summary = computeSummary(finalRecords)
        progress(analysisProgress(phase: .completed, completedCount: totalCount, totalCount: totalCount, overallProgress: 1.0))
        return summary
    }

    // MARK: - Load Records

    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        try store.load(for: folderUrl)
    }

    // MARK: - Private Helpers

    private func runJpgFallback(pair: photoFilePair, config: analysisConfig) -> rawAnalysisResult {
        guard pair.hasJpg, let jpgPath = pair.jpgPath else {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "normal",
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
                exposureStatus: "normal",
                dynamicRange: nil,
                blackLevel: 0,
                whiteLevel: 0,
                analysisSource: "jpg_failed"
            )
        }
    }

    private func computeSummary(_ records: [photoItem]) -> analysisSummary {
        var blurry = 0, overexposed = 0, underexposed = 0, normal = 0
        for item in records {
            if item.isBlurry { blurry += 1 }
            if item.exposureStatus == "overexposed" { overexposed += 1 }
            else if item.exposureStatus == "underexposed" { underexposed += 1 }
            if !item.isBlurry && item.exposureStatus == "normal" { normal += 1 }
        }
        return analysisSummary(
            totalPhotos: records.count,
            blurryCount: blurry,
            overexposedCount: overexposed,
            underexposedCount: underexposed,
            normalCount: normal
        )
    }
}
```

------

#### Step 2 — 运行验证

- [ ] 验证业务源码中没有不必要的 `pickpick.` 前缀：

```bash
rg -n "pickpick\." rawViewer --glob '!Assets.xcassets/**'
# 预期：无输出
```

- [ ] 验证本轮必须移除的旧结构和旧配置均不存在，并单独确认 review 写回不使用 defaults：

```bash
rg -n "photoItemRecord|laplacianKernelSize|laplacian_kernel_size" rawViewer/services rawViewer/models rawViewer/config.yaml
# 预期：无输出
```

```bash
rg -n "analysisConfig\.defaults" rawViewer/models/jsonReviewStateStore.swift
# 预期：无输出
```

- [ ] 验证 bundle resource、Codable、Optional percentile、LibRaw failure branch 都存在：

```bash
python3 - <<'PY'
from pathlib import Path
checks = [
    ('project resource', 'config.yaml in Resources' in Path('rawViewer.xcodeproj/project.pbxproj').read_text()),
    ('photoItem Codable', 'public struct photoItem: Codable, Equatable, Identifiable' in Path('rawViewer/models/photoModels.swift').read_text()),
    ('analysisStore optional config', 'config: analysisConfig? = nil' in Path('rawViewer/services/analysisStore.swift').read_text()),
    ('raw percentile optional', 'var p01Bin: UInt32?' in Path('rawViewer/services/rawBayerAnalyzer.swift').read_text()),
    ('jpg percentile optional', 'var p01Bin: UInt32?' in Path('rawViewer/services/jpgAnalyzer.swift').read_text()),
    ('bridge delete null', 'delete h;\n        return nullptr;' in Path('rawViewer/bridge/libRawBridge.mm').read_text()),
]
failed = [name for name, ok in checks if not ok]
if failed:
    raise SystemExit('FAIL: ' + ', '.join(failed))
print('PASS: all required static checks succeeded')
PY
# 预期：PASS: all required static checks succeeded
```

- [ ] 验证构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

- [ ] 验证 bundle 内包含 config：

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*pickpick.app/Contents/Resources/config.yaml' -print | tail -n 1
# 预期：输出一个以 pickpick.app/Contents/Resources/config.yaml 结尾的路径
```

如果验证不通过，修复本任务涉及文件或前序任务遗漏后，重新运行本任务全部验证命令。

------

✅ **完成的标志：** 全局静态检查通过，构建通过，bundle 中包含 `config.yaml`，业务源码中无 `pickpick.` 残留。

------

## 最终验收

完成所有任务后，执行以下命令作为最终验收：

```bash
rg -n "pickpick\.|photoItemRecord|laplacianKernelSize|laplacian_kernel_size|p01Bin == 0|UInt64\(Int64\(p01Target\)\)" rawViewer --glob '!Assets.xcassets/**'
# 预期：无输出
```

```bash
rg -n "analysisConfig\.defaults" rawViewer/models/jsonReviewStateStore.swift
# 预期：无输出
```

```bash
python3 - <<'PY'
from pathlib import Path
required = {
    'config ratio 0.96': 'overexpose_pixel_threshold: 0.96' in Path('rawViewer/config.yaml').read_text(),
    'bundle resource': 'config.yaml in Resources' in Path('rawViewer.xcodeproj/project.pbxproj').read_text(),
    'photoItem Codable': 'public struct photoItem: Codable, Equatable, Identifiable' in Path('rawViewer/models/photoModels.swift').read_text(),
    'optional save config': 'config: analysisConfig? = nil' in Path('rawViewer/services/analysisStore.swift').read_text(),
    'review save no config': 'analysisStore.shared.save(folderUrl: folderUrl, records: records)' in Path('rawViewer/models/jsonReviewStateStore.swift').read_text(),
    'raw optional percentile': 'var p01Bin: UInt32?' in Path('rawViewer/services/rawBayerAnalyzer.swift').read_text(),
    'jpg optional percentile': 'var p01Bin: UInt32?' in Path('rawViewer/services/jpgAnalyzer.swift').read_text(),
    'bridge null failure': 'delete h;\n        return nullptr;' in Path('rawViewer/bridge/libRawBridge.mm').read_text(),
    'jpg analyzer service': 'jpgAnalyzerService' in Path('rawViewer/services/photoAnalysisService.swift').read_text(),
}
missing = [name for name, ok in required.items() if not ok]
if missing:
    raise SystemExit('FAIL: ' + ', '.join(missing))
print('PASS: final static acceptance checks succeeded')
PY
# 预期：PASS: final static acceptance checks succeeded
```

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
# 预期：输出包含 ** BUILD SUCCEEDED **
```

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*pickpick.app/Contents/Resources/config.yaml' -print | tail -n 1
# 预期：输出一个以 pickpick.app/Contents/Resources/config.yaml 结尾的路径
```

全部通过后，本计划完成。
