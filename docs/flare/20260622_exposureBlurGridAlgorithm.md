# 综合曝光 / 模糊检测算法 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 用“全局统计 + 5x5 网格区域统计 + 主因分类”替代当前单阈值曝光/模糊判断，使 `0621` 中只有 `P1002511/P1002538/P1002539/P1002552` 判为 underexposed，其余误报回到 normal，且分组互斥（曝光优先于模糊）。

**架构：** GPU 提取全局直方图 + 每格直方图 + 每格 Laplacian 统计；CPU 把特征归一化后交给共享评分引擎算三个 score，再由分类器按“曝光优先、模糊其次”给出唯一 primaryIssue，映射回现有 `exposureStatus`/`isBlurry`。RAW 与 JPG 共用同一评分器，但亮度/对比/Laplacian 阈值按值空间拆成 raw/jpg 两套。

**技术栈：** Swift 6 / Metal / LibRaw / Xcode 16（文件系统同步组）

**工程前置（已确认，无需实现）：**
- `appDebugLogger` 已受 `--debug` 控制（`rawViewer/services/appDebugLogger.swift`）
- `appDelegate` 已支持 `--folder=/path` 自动加载（`rawViewer/appDelegate.swift`）
- `rawViewer/` 是 `PBXFileSystemSynchronizedRootGroup`：新增 `.swift`/`.metal` 文件落盘即纳入编译，**无需手改 `project.pbxproj`**
- `config.yaml` 已作为 bundle 资源打包
- 构建命令：`xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build`

**`0621` 文件夹：** `/Users/wilbur/Downloads/0621`，缓存 hash = `3ED13108F536342E`
缓存路径：`~/Library/Application Support/rawViewer/3ED13108F536342E/analysis.json`

**验收标准（来自 recipe）：**
- AC1：`P1002511/P1002538/P1002539/P1002552` 必须判为 `underexposed`
- AC2：上述 4 张 `isBlurry = false`
- AC3：当前 `underexposed` 其余 13 张回到 `normal`（`P1002441/P1002461/P1002485/P1002489/P1002490/P1002491/P1002496/P1002549/P1002551/P1002555/P1002561/P1002580/P1002581`，`exposureStatus="normal"`, `isBlurry=false`）
- AC4：无强模糊证据的误报照片不得判 `blurry`
- AC5：`configSnapshot` 变化自动触发重新分析

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `rawViewer/services/analysisConfig.swift` | 配置结构 + 默认值 | 新增 `gridAnalysisConfig` / `scoringConfig`，自定义 Codable |
| `rawViewer/config.yaml` | 打包配置 | 新增 `grid_analysis` / `scoring` 段 |
| `rawViewer/services/configLoader.swift` | YAML 解析 | 解析新段 |
| `rawViewer/metal/rawAnalysisShaders.metal` | GPU kernels | 新增 3 个 kernel，保留旧全局 reduce 直到 RAW/JPG 切换完成，避免中间任务断编译 |
| `rawViewer/metal/metalAnalysisContext.swift` | pipeline 上下文 | 新增 3 个 pipeline，保留旧 reducePipeline 直到 RAW/JPG 切换完成 |
| `rawViewer/services/analysisScoring.swift` | 评分引擎 + 分类器（NEW） | 新建，RAW/JPG 共用 |
| `rawViewer/services/rawBayerAnalyzer.swift` | RAW 分析 | 重写：特征→评分→分类→映射 |
| `rawViewer/services/jpgAnalyzer.swift` | JPG 分析 | 重写：同上 |
| `rawViewer/services/photoAnalysisService.swift` | 主编排 | `--debug` 下写校准 dump |

---

## Task 1: 扩展配置结构（grid + scoring + algorithmVersion）

**目标：** `analysisConfig` 能携带网格与评分配置；旧缓存缺失新算法版本时被明确判为 stale 并触发重新分析；非法网格配置会被 clamp 到安全范围。

**涉及的文件：**
- `rawViewer/services/analysisConfig.swift` — 新增两个配置结构 + `analysisAlgorithmVersion` + 自定义 Codable
- `rawViewer/config.yaml` — 新增配置段
- `rawViewer/services/configLoader.swift` — 解析新段并校验 grid 合法性

### Step 1 — 实现

`rawViewer/services/analysisConfig.swift`（完整新内容）：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-22
Description: 分析参数配置结构 (algorithmVersion / exposure / blur / grid / scoring / concurrency) + 默认值；v1.5 新增网格分析与评分配置，并用 analysisAlgorithmVersion 让旧单阈值缓存明确失效
*/

import Foundation

nonisolated public struct exposureConfig: Codable, Equatable, Sendable {
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

nonisolated public struct blurConfig: Codable, Equatable, Sendable {
    public var laplacianThresholdRaw: Double
    public var laplacianThresholdJpg: Double

    public init(laplacianThresholdRaw: Double, laplacianThresholdJpg: Double) {
        self.laplacianThresholdRaw = laplacianThresholdRaw
        self.laplacianThresholdJpg = laplacianThresholdJpg
    }
}

nonisolated public struct gridAnalysisConfig: Codable, Equatable, Sendable {
    public var rows: Int
    public var columns: Int
    public var centerRows: Int
    public var centerColumns: Int

    public init(rows: Int = 5, columns: Int = 5, centerRows: Int = 3, centerColumns: Int = 3) {
        self.rows = rows
        self.columns = columns
        self.centerRows = centerRows
        self.centerColumns = centerColumns
    }
}

nonisolated public struct scoringConfig: Codable, Equatable, Sendable {
    public var underexposedThreshold: Double
    public var overexposedThreshold: Double
    public var blurryThreshold: Double
    public var deepDarkPixelThreshold: Double
    public var darkTileMeanThresholdRaw: Double
    public var darkTileMeanThresholdJpg: Double
    public var brightTileP90ThresholdRaw: Double
    public var brightTileP90ThresholdJpg: Double
    public var lowContrastTileThresholdRaw: Double
    public var lowContrastTileThresholdJpg: Double
    public var usableTileMinBrightnessRaw: Double
    public var usableTileMinBrightnessJpg: Double
    public var usableTileMinContrastRaw: Double
    public var usableTileMinContrastJpg: Double
    public var sharpTileLaplacianThresholdRaw: Double
    public var sharpTileLaplacianThresholdJpg: Double
    public var laplacianLowThresholdRaw: Double
    public var laplacianLowThresholdJpg: Double

    public init(
        underexposedThreshold: Double = 0.55,
        overexposedThreshold: Double = 0.55,
        blurryThreshold: Double = 0.55,
        deepDarkPixelThreshold: Double = 0.002,
        darkTileMeanThresholdRaw: Double = 0.05,
        darkTileMeanThresholdJpg: Double = 0.08,
        brightTileP90ThresholdRaw: Double = 0.4,
        brightTileP90ThresholdJpg: Double = 0.55,
        lowContrastTileThresholdRaw: Double = 0.02,
        lowContrastTileThresholdJpg: Double = 0.06,
        usableTileMinBrightnessRaw: Double = 0.05,
        usableTileMinBrightnessJpg: Double = 0.08,
        usableTileMinContrastRaw: Double = 0.03,
        usableTileMinContrastJpg: Double = 0.08,
        sharpTileLaplacianThresholdRaw: Double = 0.0005,
        sharpTileLaplacianThresholdJpg: Double = 0.0005,
        laplacianLowThresholdRaw: Double = 0.0005,
        laplacianLowThresholdJpg: Double = 0.0005
    ) {
        self.underexposedThreshold = underexposedThreshold
        self.overexposedThreshold = overexposedThreshold
        self.blurryThreshold = blurryThreshold
        self.deepDarkPixelThreshold = deepDarkPixelThreshold
        self.darkTileMeanThresholdRaw = darkTileMeanThresholdRaw
        self.darkTileMeanThresholdJpg = darkTileMeanThresholdJpg
        self.brightTileP90ThresholdRaw = brightTileP90ThresholdRaw
        self.brightTileP90ThresholdJpg = brightTileP90ThresholdJpg
        self.lowContrastTileThresholdRaw = lowContrastTileThresholdRaw
        self.lowContrastTileThresholdJpg = lowContrastTileThresholdJpg
        self.usableTileMinBrightnessRaw = usableTileMinBrightnessRaw
        self.usableTileMinBrightnessJpg = usableTileMinBrightnessJpg
        self.usableTileMinContrastRaw = usableTileMinContrastRaw
        self.usableTileMinContrastJpg = usableTileMinContrastJpg
        self.sharpTileLaplacianThresholdRaw = sharpTileLaplacianThresholdRaw
        self.sharpTileLaplacianThresholdJpg = sharpTileLaplacianThresholdJpg
        self.laplacianLowThresholdRaw = laplacianLowThresholdRaw
        self.laplacianLowThresholdJpg = laplacianLowThresholdJpg
    }
}

nonisolated public struct analysisConfig: Codable, Equatable, Sendable {
    public var analysisAlgorithmVersion: String
    public var exposure: exposureConfig
    public var blur: blurConfig
    public var grid: gridAnalysisConfig
    public var scoring: scoringConfig
    public var metalConcurrency: Int

    public init(
        exposure: exposureConfig,
        blur: blurConfig,
        grid: gridAnalysisConfig = gridAnalysisConfig(),
        scoring: scoringConfig = scoringConfig(),
        metalConcurrency: Int,
        analysisAlgorithmVersion: String = "grid-v1"
    ) {
        self.analysisAlgorithmVersion = analysisAlgorithmVersion
        self.exposure = exposure
        self.blur = blur
        self.grid = grid
        self.scoring = scoring
        self.metalConcurrency = metalConcurrency
    }

    private enum codingKeys: String, CodingKey {
        case analysisAlgorithmVersion, exposure, blur, grid, scoring, metalConcurrency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: codingKeys.self)
        self.analysisAlgorithmVersion = try c.decodeIfPresent(String.self, forKey: .analysisAlgorithmVersion) ?? analysisConfig.legacyAlgorithmVersion
        self.exposure = try c.decode(exposureConfig.self, forKey: .exposure)
        self.blur = try c.decode(blurConfig.self, forKey: .blur)
        self.grid = try c.decodeIfPresent(gridAnalysisConfig.self, forKey: .grid) ?? gridAnalysisConfig()
        self.scoring = try c.decodeIfPresent(scoringConfig.self, forKey: .scoring) ?? scoringConfig()
        self.metalConcurrency = try c.decode(Int.self, forKey: .metalConcurrency)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: codingKeys.self)
        try c.encode(analysisAlgorithmVersion, forKey: .analysisAlgorithmVersion)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(blur, forKey: .blur)
        try c.encode(grid, forKey: .grid)
        try c.encode(scoring, forKey: .scoring)
        try c.encode(metalConcurrency, forKey: .metalConcurrency)
    }
}

nonisolated public extension analysisConfig {
    static let currentAlgorithmVersion = "grid-v1"
    static let legacyAlgorithmVersion = "legacy-single-threshold"

    static let defaults = analysisConfig(
        exposure: exposureConfig(
            overexposePixelThreshold: 0.975,
            underexposePixelThreshold: 0.01,
            overexposeRatioLimit: 0.2,
            underexposeRatioLimit: 0.3
        ),
        blur: blurConfig(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0
        ),
        grid: gridAnalysisConfig(),
        scoring: scoringConfig(),
        metalConcurrency: 6,
        analysisAlgorithmVersion: currentAlgorithmVersion
    )
}
```

`rawViewer/config.yaml`（完整新内容）：

```yaml
# pickpick 默认分析参数
# Swift 原生分析 schema 2.0
# exposure_detection 中的像素阈值均为 0.0~1.0 ratio。
# 本文件会被打包进 app bundle，分析参数统一来自 app bundle；照片文件夹内 config.yaml 不再覆盖本文件。

exposure_detection:
  overexpose_pixel_threshold: 0.975
  underexpose_pixel_threshold: 0.01
  overexpose_ratio_limit: 0.2
  underexpose_ratio_limit: 0.3

blur_detection:
  laplacian_threshold_raw: 5000.0
  laplacian_threshold_jpg: 10.0

grid_analysis:
  rows: 5
  columns: 5
  center_rows: 3
  center_columns: 3

scoring:
  underexposed_threshold: 0.55
  overexposed_threshold: 0.55
  blurry_threshold: 0.55
  deep_dark_pixel_threshold: 0.002
  dark_tile_mean_threshold_raw: 0.05
  dark_tile_mean_threshold_jpg: 0.08
  bright_tile_p90_threshold_raw: 0.4
  bright_tile_p90_threshold_jpg: 0.55
  low_contrast_tile_threshold_raw: 0.02
  low_contrast_tile_threshold_jpg: 0.06
  usable_tile_min_brightness_raw: 0.05
  usable_tile_min_brightness_jpg: 0.08
  usable_tile_min_contrast_raw: 0.03
  usable_tile_min_contrast_jpg: 0.08
  sharp_tile_laplacian_threshold_raw: 0.0005
  sharp_tile_laplacian_threshold_jpg: 0.0005
  laplacian_low_threshold_raw: 0.0005
  laplacian_low_threshold_jpg: 0.0005

analysis:
  metal_concurrency: 6
```

`rawViewer/services/configLoader.swift` —— 把 `parse(_:)` 方法替换为，并在 `intValue(_:)` 后新增 `clampedInt(_:,default:min:max:)`：

```swift
    private func parse(_ root: [String: Any]) -> analysisConfig {
        let exposureNode = root["exposure_detection"] as? [String: Any] ?? [:]
        let blurNode = root["blur_detection"] as? [String: Any] ?? [:]
        let gridNode = root["grid_analysis"] as? [String: Any] ?? [:]
        let scoringNode = root["scoring"] as? [String: Any] ?? [:]
        let analysisNode = root["analysis"] as? [String: Any] ?? [:]

        let exposure = exposureConfig(
            overexposePixelThreshold: ratioValue(exposureNode["overexpose_pixel_threshold"], default: analysisConfig.defaults.exposure.overexposePixelThreshold),
            underexposePixelThreshold: ratioValue(exposureNode["underexpose_pixel_threshold"], default: analysisConfig.defaults.exposure.underexposePixelThreshold),
            overexposeRatioLimit: ratioValue(exposureNode["overexpose_ratio_limit"], default: analysisConfig.defaults.exposure.overexposeRatioLimit),
            underexposeRatioLimit: ratioValue(exposureNode["underexpose_ratio_limit"], default: analysisConfig.defaults.exposure.underexposeRatioLimit)
        )

        let blur = blurConfig(
            laplacianThresholdRaw: nonNegativeValue(blurNode["laplacian_threshold_raw"], default: analysisConfig.defaults.blur.laplacianThresholdRaw),
            laplacianThresholdJpg: nonNegativeValue(blurNode["laplacian_threshold_jpg"], default: analysisConfig.defaults.blur.laplacianThresholdJpg)
        )

        let rows = clampedInt(gridNode["rows"], default: analysisConfig.defaults.grid.rows, min: 1, max: 12)
        let columns = clampedInt(gridNode["columns"], default: analysisConfig.defaults.grid.columns, min: 1, max: 12)
        let centerRows = clampedInt(gridNode["center_rows"], default: analysisConfig.defaults.grid.centerRows, min: 1, max: rows)
        let centerColumns = clampedInt(gridNode["center_columns"], default: analysisConfig.defaults.grid.centerColumns, min: 1, max: columns)
        let grid = gridAnalysisConfig(rows: rows, columns: columns, centerRows: centerRows, centerColumns: centerColumns)

        let scoring = scoringConfig(
            underexposedThreshold: ratioValue(scoringNode["underexposed_threshold"], default: analysisConfig.defaults.scoring.underexposedThreshold),
            overexposedThreshold: ratioValue(scoringNode["overexposed_threshold"], default: analysisConfig.defaults.scoring.overexposedThreshold),
            blurryThreshold: ratioValue(scoringNode["blurry_threshold"], default: analysisConfig.defaults.scoring.blurryThreshold),
            deepDarkPixelThreshold: ratioValue(scoringNode["deep_dark_pixel_threshold"], default: analysisConfig.defaults.scoring.deepDarkPixelThreshold),
            darkTileMeanThresholdRaw: ratioValue(scoringNode["dark_tile_mean_threshold_raw"], default: analysisConfig.defaults.scoring.darkTileMeanThresholdRaw),
            darkTileMeanThresholdJpg: ratioValue(scoringNode["dark_tile_mean_threshold_jpg"], default: analysisConfig.defaults.scoring.darkTileMeanThresholdJpg),
            brightTileP90ThresholdRaw: ratioValue(scoringNode["bright_tile_p90_threshold_raw"], default: analysisConfig.defaults.scoring.brightTileP90ThresholdRaw),
            brightTileP90ThresholdJpg: ratioValue(scoringNode["bright_tile_p90_threshold_jpg"], default: analysisConfig.defaults.scoring.brightTileP90ThresholdJpg),
            lowContrastTileThresholdRaw: ratioValue(scoringNode["low_contrast_tile_threshold_raw"], default: analysisConfig.defaults.scoring.lowContrastTileThresholdRaw),
            lowContrastTileThresholdJpg: ratioValue(scoringNode["low_contrast_tile_threshold_jpg"], default: analysisConfig.defaults.scoring.lowContrastTileThresholdJpg),
            usableTileMinBrightnessRaw: ratioValue(scoringNode["usable_tile_min_brightness_raw"], default: analysisConfig.defaults.scoring.usableTileMinBrightnessRaw),
            usableTileMinBrightnessJpg: ratioValue(scoringNode["usable_tile_min_brightness_jpg"], default: analysisConfig.defaults.scoring.usableTileMinBrightnessJpg),
            usableTileMinContrastRaw: ratioValue(scoringNode["usable_tile_min_contrast_raw"], default: analysisConfig.defaults.scoring.usableTileMinContrastRaw),
            usableTileMinContrastJpg: ratioValue(scoringNode["usable_tile_min_contrast_jpg"], default: analysisConfig.defaults.scoring.usableTileMinContrastJpg),
            sharpTileLaplacianThresholdRaw: nonNegativeValue(scoringNode["sharp_tile_laplacian_threshold_raw"], default: analysisConfig.defaults.scoring.sharpTileLaplacianThresholdRaw),
            sharpTileLaplacianThresholdJpg: nonNegativeValue(scoringNode["sharp_tile_laplacian_threshold_jpg"], default: analysisConfig.defaults.scoring.sharpTileLaplacianThresholdJpg),
            laplacianLowThresholdRaw: nonNegativeValue(scoringNode["laplacian_low_threshold_raw"], default: analysisConfig.defaults.scoring.laplacianLowThresholdRaw),
            laplacianLowThresholdJpg: nonNegativeValue(scoringNode["laplacian_low_threshold_jpg"], default: analysisConfig.defaults.scoring.laplacianLowThresholdJpg)
        )

        let rawConcurrency = intValue(analysisNode["metal_concurrency"]) ?? analysisConfig.defaults.metalConcurrency
        let concurrency = min(max(rawConcurrency, 1), 8)

        return analysisConfig(exposure: exposure, blur: blur, grid: grid, scoring: scoring, metalConcurrency: concurrency)
    }
```

新增 helper：

```swift
    private func clampedInt(_ any: Any?, default defaultValue: Int, min minValue: Int, max maxValue: Int) -> Int {
        let raw = intValue(any) ?? defaultValue
        return Swift.min(Swift.max(raw, minValue), maxValue)
    }
```

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -3
# 预期：BUILD SUCCEEDED

$ python3 - <<'PY'
import json, pathlib
url = pathlib.Path.home()/'Library/Application Support/rawViewer/3ED13108F536342E/analysis.json'
if url.exists():
    d = json.loads(url.read_text())
    snap = d.get('configSnapshot') or {}
    print('cachedVersion=', snap.get('analysisAlgorithmVersion'))
else:
    print('no existing cache')
PY
# 预期：旧缓存若没有 analysisAlgorithmVersion，后续 loadRecords 会因 expected=grid-v1、cached=legacy-single-threshold 而 stale
```

✅ **完成标志：** 构建通过；`analysisConfig.defaults.analysisAlgorithmVersion == "grid-v1"`；旧单阈值缓存不会被静默当作新算法缓存复用。

---

## Task 2: Metal 网格统计 kernels

**目标：** GPU 能产出每格亮度直方图 + 每格暗部/死黑/高光计数 + 每格 Laplacian sum/sumSq。

**涉及的文件：**
- `rawViewer/metal/rawAnalysisShaders.metal` — 新增 3 个 kernel，暂时保留旧 `reduceLaplacianKernel`
- `rawViewer/metal/metalAnalysisContext.swift` — 新增 3 个 pipeline，暂时保留 `reducePipeline`

### Step 1 — 实现

`rawViewer/metal/rawAnalysisShaders.metal`（完整新内容）：

```metal
/*
Author: wilbur
Version: 1.1
Date: 2026-06-22
Description: RAW/JPG 直方图 + Green/Gray 平面 + Laplacian + 每格统计 kernels。v1.1 新增网格直方图与每格 Laplacian 规约，保留旧全局 reduce 以保证分步构建通过
*/

#include <metal_stdlib>
using namespace metal;

struct BayerHistConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint visibleWidth; uint visibleHeight;
    uint binCount; uint blackLevel; uint whiteLevel;
    uint overThreshold; uint underThreshold;
};

struct GreenPlaneConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint greenWidth; uint greenHeight; uint blackLevel;
};

struct GreenLaplacianConfig { uint width; uint height; };

struct RawGridHistConfig {
    uint planeWidth; uint planeHeight;
    uint gridRows; uint gridCols; uint binCount;
    float range; float darkThreshold;
    float deepDarkThreshold; float highlightThreshold;
};

struct JpgGridHistConfig {
    uint planeWidth; uint planeHeight;
    uint gridRows; uint gridCols; uint binCount;
    float darkThreshold; float deepDarkThreshold; float highlightThreshold;
};

struct GridReduceConfig { uint width; uint height; uint gridRows; uint gridCols; };
struct PerTileStats { float sum; float sumSq; };

// 旧全局 reduce 过渡期保留，直到 RAW/JPG analyzer 都不再引用 reducePipeline
struct PartialStats { float sum; float sumSq; float minVal; float maxVal; };

kernel void bayerHistogramKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
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
    uint channel = ((x & 1) == 0) ? ((y & 1) == 0 ? 0u : 3u) : ((y & 1) == 0 ? 1u : 2u);
    uint bin = config.binCount > 0
        ? static_cast<uint>(valueSigned) * config.binCount / (config.whiteLevel - config.blackLevel + 1u)
        : 0u;
    if (bin >= config.binCount) bin = config.binCount - 1u;
    atomic_fetch_add_explicit(&histogram[channel * config.binCount + bin], 1u, memory_order_relaxed);
    if (rawValue >= config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 0], 1u, memory_order_relaxed);
    if (rawValue <= config.underThreshold && rawValue > 0) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 1], 1u, memory_order_relaxed);
}

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
    uint g1 = static_cast<uint>(rawBuffer[baseY * config.rawWidth + (baseX + 1u)]);
    uint g2 = static_cast<uint>(rawBuffer[(baseY + 1u) * config.rawWidth + baseX]);
    int g1Signed = static_cast<int>(g1) - static_cast<int>(config.blackLevel);
    int g2Signed = static_cast<int>(g2) - static_cast<int>(config.blackLevel);
    float greenValue = (static_cast<float>(max(0, g1Signed)) + static_cast<float>(max(0, g2Signed))) * 0.5f;
    greenPlane[gid.y * config.greenWidth + gid.x] = greenValue;
}

kernel void greenLaplacianKernel(
    device const float* greenPlane [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x; uint y = gid.y;
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

// 旧全局 Laplacian 规约：过渡期保留，保证 Task 2 后旧 analyzer 仍可编译运行
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
    bool valid = index < total;
    float value = valid ? laplacianBuffer[index] : 0.0f;
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

// 每格 Laplacian 规约：一个 threadgroup 处理一个 tile
kernel void reduceLaplacianPerTileKernel(
    device const float* laplacianBuffer [[buffer(0)]],
    device PerTileStats* tileStats [[buffer(1)]],
    constant GridReduceConfig& config [[buffer(2)]],
    uint tid [[thread_position_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    uint tileRow = groupId / config.gridCols;
    uint tileCol = groupId % config.gridCols;
    uint baseTileW = config.width / config.gridCols;
    uint baseTileH = config.height / config.gridRows;
    uint startX = tileCol * baseTileW;
    uint startY = tileRow * baseTileH;
    uint tileW = (tileCol == config.gridCols - 1u) ? (config.width - startX) : baseTileW;
    uint tileH = (tileRow == config.gridRows - 1u) ? (config.height - startY) : baseTileH;
    float sum = 0.0f; float sumSq = 0.0f;
    uint tilePixels = tileW * tileH;
    for (uint idx = tid; idx < tilePixels; idx += threadsPerGroup) {
        uint lx = idx % tileW; uint ly = idx / tileW;
        float v = laplacianBuffer[(startY + ly) * config.width + (startX + lx)];
        sum += v; sumSq += v * v;
    }
    localSum[tid] = sum; localSumSq[tid] = sumSq;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = threadsPerGroup / 2; stride > 0; stride >>= 1) {
        if (tid < stride) { localSum[tid] += localSum[tid + stride]; localSumSq[tid] += localSumSq[tid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) { tileStats[groupId].sum = localSum[0]; tileStats[groupId].sumSq = localSumSq[0]; }
}

// RAW 每格直方图（Green Plane，float，0~range）
kernel void rawGridHistogramKernel(
    device const float* plane [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* counts [[buffer(2)]],
    constant RawGridHistConfig& config [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.planeWidth || gid.y >= config.planeHeight) return;
    uint tileCol = gid.x * config.gridCols / config.planeWidth;
    uint tileRow = gid.y * config.gridRows / config.planeHeight;
    if (tileCol >= config.gridCols) tileCol = config.gridCols - 1u;
    if (tileRow >= config.gridRows) tileRow = config.gridRows - 1u;
    uint tileIdx = tileRow * config.gridCols + tileCol;
    float v = plane[gid.y * config.planeWidth + gid.x];
    uint bin = config.range > 0.0f ? static_cast<uint>(v / config.range * static_cast<float>(config.binCount)) : 0u;
    if (bin >= config.binCount) bin = config.binCount - 1u;
    atomic_fetch_add_explicit(&histogram[tileIdx * config.binCount + bin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&counts[tileIdx * 4u + 0u], 1u, memory_order_relaxed);
    if (v <= config.darkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 1u], 1u, memory_order_relaxed);
    if (v <= config.deepDarkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 2u], 1u, memory_order_relaxed);
    if (v >= config.highlightThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 3u], 1u, memory_order_relaxed);
}

struct JpgHistConfig { uint totalPixels; uint overThreshold; uint underThreshold; };
struct JpgLaplacianConfig { uint width; uint height; };

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
    grayBuffer[gid.y * rgbaTexture.get_width() + gid.x] = static_cast<uchar>(grayFloat + 0.5f);
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
    if (gray > config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    if (gray < config.underThreshold) atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
}

kernel void jpgLaplacianKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant JpgLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x; uint y = gid.y;
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

// JPG 每格直方图（Gray，uchar，0~255）
kernel void jpgGridHistogramKernel(
    device const uchar* plane [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* counts [[buffer(2)]],
    constant JpgGridHistConfig& config [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.planeWidth || gid.y >= config.planeHeight) return;
    uint tileCol = gid.x * config.gridCols / config.planeWidth;
    uint tileRow = gid.y * config.gridRows / config.planeHeight;
    if (tileCol >= config.gridCols) tileCol = config.gridCols - 1u;
    if (tileRow >= config.gridRows) tileRow = config.gridRows - 1u;
    uint tileIdx = tileRow * config.gridCols + tileCol;
    float v = static_cast<float>(plane[gid.y * config.planeWidth + gid.x]);
    uint bin = static_cast<uint>(v / 255.0f * static_cast<float>(config.binCount));
    if (bin >= config.binCount) bin = config.binCount - 1u;
    atomic_fetch_add_explicit(&histogram[tileIdx * config.binCount + bin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&counts[tileIdx * 4u + 0u], 1u, memory_order_relaxed);
    if (v <= config.darkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 1u], 1u, memory_order_relaxed);
    if (v <= config.deepDarkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 2u], 1u, memory_order_relaxed);
    if (v >= config.highlightThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 3u], 1u, memory_order_relaxed);
}
```

`rawViewer/metal/metalAnalysisContext.swift`（完整新内容）：

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-22
Description: Metal 设备 / queue / pipeline 上下文。v1.3 新增每格 Laplacian 规约 + 网格直方图 pipeline，并保留旧全局 reducePipeline 以保证分步构建通过
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
        case .metalNotSupported: return "Metal is not supported on this device"
        case .commandQueueUnavailable: return "Failed to create Metal command queue"
        case .libraryUnavailable: return "Failed to load default Metal library"
        case .functionUnavailable(let name): return "Metal function '\(name)' was not found"
        case .pipelineCreationFailed(let name, let underlying): return "Failed to create Metal pipeline '\(name)': \(underlying.localizedDescription)"
        }
    }
}

public final class metalAnalysisContext {
    private nonisolated static let cachedResult: Result<metalAnalysisContext, Error> = Result { try metalAnalysisContext() }
    public nonisolated static func shared() throws -> metalAnalysisContext { try cachedResult.get() }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public let bayerHistogramPipeline: MTLComputePipelineState
    public let bayerToGreenPlanePipeline: MTLComputePipelineState
    public let greenLaplacianPipeline: MTLComputePipelineState
    public let reducePipeline: MTLComputePipelineState
    public let reduceLaplacianPerTilePipeline: MTLComputePipelineState
    public let rawGridHistogramPipeline: MTLComputePipelineState
    public let rgbToGrayPipeline: MTLComputePipelineState
    public let jpgHistogramPipeline: MTLComputePipelineState
    public let jpgLaplacianPipeline: MTLComputePipelineState
    public let jpgGridHistogramPipeline: MTLComputePipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw metalAnalysisContextError.metalNotSupported }
        guard let queue = device.makeCommandQueue() else { throw metalAnalysisContextError.commandQueueUnavailable }
        guard let library = device.makeDefaultLibrary() else { throw metalAnalysisContextError.libraryUnavailable }
        self.device = device
        self.commandQueue = queue
        self.library = library

        self.bayerHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "bayerHistogramKernel")
        self.bayerToGreenPlanePipeline = try Self.makePipeline(device: device, library: library, name: "bayerToGreenPlaneKernel")
        self.greenLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "greenLaplacianKernel")
        self.reducePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
        self.reduceLaplacianPerTilePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianPerTileKernel")
        self.rawGridHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "rawGridHistogramKernel")
        self.rgbToGrayPipeline = try Self.makePipeline(device: device, library: library, name: "rgbToGrayKernel")
        self.jpgHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgHistogramKernel")
        self.jpgLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "jpgLaplacianKernel")
        self.jpgGridHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgGridHistogramKernel")
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

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -3
# 预期：BUILD SUCCEEDED（Metal kernel + 新 pipeline 编译通过）
```

✅ **完成标志：** 构建通过，新 kernel 与 pipeline 编译无误。

## Task 3: 共享评分引擎与分类器

**目标：** 提供 RAW/JPG 共用的特征构建器、评分引擎、主因分类器与字段映射，使两个 analyzer 调用同一套逻辑。

**涉及的文件：**
- `rawViewer/services/analysisScoring.swift` — 新建

### Step 1 — 实现

`rawViewer/services/analysisScoring.swift`（完整新内容）：

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-22
Description: 曝光/模糊评分引擎 + 主因分类器 + 特征构建器，RAW/JPG 共用
*/

import Foundation

public enum analysisValueSpace: String, Sendable {
    case rawLinear
    case jpgGamma
}

public enum primaryIssue: String, Sendable {
    case normal
    case underexposed
    case overexposed
    case blurry
    case failed
}

nonisolated public struct globalExposureFeatures: Sendable {
    public var meanNorm, medianNorm: Double
    public var p01Norm, p05Norm, p10Norm, p50Norm, p90Norm, p95Norm, p99Norm: Double
    public var darkRatio, deepDarkRatio, highlightRatio, tonalSpreadNorm: Double
}

nonisolated public struct tileFeatures: Sendable {
    public var meanNorm, p10Norm, p90Norm: Double
    public var darkRatio, deepDarkRatio, highlightRatio: Double
    public var localContrastNorm, laplacianVarianceNorm: Double
    public var isUsable: Bool
}

nonisolated public struct blurFeatures: Sendable {
    public var centerLaplacianVarianceNorm, usableAreaLaplacianVarianceNorm: Double
    public var sharpTileRatio, lowContrastTileRatio, usableTileRatio: Double
}

nonisolated public struct analysisFeatures: Sendable {
    public var globalExposure: globalExposureFeatures
    public var tiles: [tileFeatures]
    public var blur: blurFeatures
    public var gridRows, gridCols, centerRows, centerCols: Int
}

nonisolated public struct analysisScores: Sendable {
    public var underexposed, overexposed, blurry: Double
}

nonisolated public struct analysisDebugInfo: Sendable {
    public var features: analysisFeatures
    public var scores: analysisScores
    public var primary: primaryIssue
}

// MARK: - 特征构建

public func buildGlobalExposureFeatures(
    histogram: [UInt32], binCount: Int,
    darkThresholdNorm: Double, deepDarkThresholdNorm: Double, highlightThresholdNorm: Double
) -> globalExposureFeatures {
    var f = globalExposureFeatures(
        meanNorm: 0, medianNorm: 0,
        p01Norm: 0, p05Norm: 0, p10Norm: 0, p50Norm: 0, p90Norm: 0, p95Norm: 0, p99Norm: 0,
        darkRatio: 0, deepDarkRatio: 0, highlightRatio: 0, tonalSpreadNorm: 0)
    guard binCount > 0, !histogram.isEmpty else { return f }
    let n = min(binCount, histogram.count)
    var total: Double = 0
    for i in 0..<n { total += Double(histogram[i]) }
    guard total > 0 else { return f }
    func binNorm(_ i: Int) -> Double { (Double(i) + 0.5) / Double(binCount) }
    func pct(_ q: Double) -> Double {
        let target = total * q
        var cum: Double = 0
        for i in 0..<n {
            cum += Double(histogram[i])
            if cum >= target { return binNorm(i) }
        }
        return binNorm(n - 1)
    }
    var meanAcc: Double = 0
    var darkAcc: Double = 0, deepDarkAcc: Double = 0, highAcc: Double = 0
    for i in 0..<n {
        let c = Double(histogram[i])
        let bn = binNorm(i)
        meanAcc += bn * c
        if bn <= darkThresholdNorm { darkAcc += c }
        if bn <= deepDarkThresholdNorm { deepDarkAcc += c }
        if bn >= highlightThresholdNorm { highAcc += c }
    }
    f.meanNorm = meanAcc / total
    f.medianNorm = pct(0.5)
    f.p01Norm = pct(0.01); f.p05Norm = pct(0.05); f.p10Norm = pct(0.10)
    f.p50Norm = f.medianNorm
    f.p90Norm = pct(0.90); f.p95Norm = pct(0.95); f.p99Norm = pct(0.99)
    f.darkRatio = darkAcc / total
    f.deepDarkRatio = deepDarkAcc / total
    f.highlightRatio = highAcc / total
    f.tonalSpreadNorm = max(0, f.p99Norm - f.p01Norm)
    return f
}

public func buildTileFeatures(
    histogram: [UInt32], histogramOffset: Int, binCount: Int, pixelCount: Double,
    darkCount: Double, deepDarkCount: Double, highlightCount: Double,
    laplacianSum: Double, laplacianSumSq: Double, range: Double,
    usableMinBrightness: Double, usableMinContrast: Double
) -> tileFeatures {
    var t = tileFeatures(meanNorm: 0, p10Norm: 0, p90Norm: 0, darkRatio: 0, deepDarkRatio: 0, highlightRatio: 0, localContrastNorm: 0, laplacianVarianceNorm: 0, isUsable: false)
    guard binCount > 0, pixelCount > 0 else { return t }
    func binNorm(_ i: Int) -> Double { (Double(i) + 0.5) / Double(binCount) }
    var meanAcc: Double = 0
    for i in 0..<binCount {
        let c = Double(histogram[histogramOffset + i])
        meanAcc += binNorm(i) * c
    }
    func pct(_ q: Double) -> Double {
        let target = pixelCount * q
        var cum: Double = 0
        for i in 0..<binCount {
            cum += Double(histogram[histogramOffset + i])
            if cum >= target { return binNorm(i) }
        }
        return binNorm(binCount - 1)
    }
    t.meanNorm = meanAcc / pixelCount
    t.p10Norm = pct(0.10)
    t.p90Norm = pct(0.90)
    t.darkRatio = darkCount / pixelCount
    t.deepDarkRatio = deepDarkCount / pixelCount
    t.highlightRatio = highlightCount / pixelCount
    t.localContrastNorm = max(0, t.p90Norm - t.p10Norm)
    let mean = laplacianSum / pixelCount
    let variance = max(0, laplacianSumSq / pixelCount - mean * mean)
    t.laplacianVarianceNorm = range > 0 ? variance / (range * range) : 0
    t.isUsable = (t.meanNorm >= usableMinBrightness) && (t.localContrastNorm >= usableMinContrast)
    return t
}

public func buildBlurFeatures(
    tiles: [tileFeatures], gridRows: Int, gridCols: Int,
    centerRows: Int, centerCols: Int,
    sharpTileLaplacianThreshold: Double, lowContrastTileThreshold: Double
) -> blurFeatures {
    var b = blurFeatures(centerLaplacianVarianceNorm: 0, usableAreaLaplacianVarianceNorm: 0, sharpTileRatio: 0, lowContrastTileRatio: 0, usableTileRatio: 0)
    let total = tiles.count
    guard total > 0 else { return b }
    let rowStart = (gridRows - centerRows) / 2
    let colStart = (gridCols - centerCols) / 2
    var centerSum: Double = 0, centerCount = 0
    var usableSum: Double = 0, usableCount = 0
    var sharp = 0, lowContrast = 0, usable = 0
    for r in 0..<gridRows {
        for c in 0..<gridCols {
            let idx = r * gridCols + c
            guard idx < total else { continue }
            let t = tiles[idx]
            let isCenter = (r >= rowStart && r < rowStart + centerRows && c >= colStart && c < colStart + centerCols)
            if isCenter { centerSum += t.laplacianVarianceNorm; centerCount += 1 }
            if t.isUsable {
                usableSum += t.laplacianVarianceNorm; usableCount += 1
                if t.laplacianVarianceNorm > sharpTileLaplacianThreshold { sharp += 1 }
            }
            if t.localContrastNorm < lowContrastTileThreshold { lowContrast += 1 }
        }
    }
    _ = usable
    b.centerLaplacianVarianceNorm = centerCount > 0 ? centerSum / Double(centerCount) : 0
    b.usableAreaLaplacianVarianceNorm = usableCount > 0 ? usableSum / Double(usableCount) : 0
    b.sharpTileRatio = Double(sharp) / Double(total)
    b.lowContrastTileRatio = Double(lowContrast) / Double(total)
    b.usableTileRatio = Double(usableCount) / Double(total)
    return b
}

// MARK: - 评分

public enum scoringEngine {
    public static func score(features: analysisFeatures, config: analysisConfig, valueSpace: analysisValueSpace) -> analysisScores {
        let s = config.scoring
        let isRaw = valueSpace == .rawLinear
        let midGray = isRaw ? 0.18 : 0.5
        let darkTileMeanThreshold = isRaw ? s.darkTileMeanThresholdRaw : s.darkTileMeanThresholdJpg
        let brightTileP90Threshold = isRaw ? s.brightTileP90ThresholdRaw : s.brightTileP90ThresholdJpg
        let laplacianLowThreshold = isRaw ? s.laplacianLowThresholdRaw : s.laplacianLowThresholdJpg
        let g = features.globalExposure
        let tileCount = max(1, features.tiles.count)

        // underexposed
        let globalDarkness = clamp01((midGray - g.medianNorm) / midGray)
        let darkTileCount = features.tiles.filter { $0.meanNorm < darkTileMeanThreshold }.count
        let darkTileCoverage = Double(darkTileCount) / Double(tileCount)
        let brightTileCount = features.tiles.filter { $0.p90Norm > brightTileP90Threshold }.count
        let lackOfBrightTiles = 1.0 - Double(brightTileCount) / Double(tileCount)
        let (cr, cc) = (features.centerRows, features.centerCols)
        let rowStart = (features.gridRows - cr) / 2
        let colStart = (features.gridCols - cc) / 2
        var centerBrightSum: Double = 0; var centerN = 0
        for r in 0..<features.gridRows {
            for c in 0..<features.gridCols {
                if r >= rowStart && r < rowStart + cr && c >= colStart && c < colStart + cc {
                    let idx = r * features.gridCols + c
                    if idx < features.tiles.count { centerBrightSum += features.tiles[idx].meanNorm; centerN += 1 }
                }
            }
        }
        let centerBrightnessNorm = centerN > 0 ? centerBrightSum / Double(centerN) : 0
        let centerDarkness = clamp01((midGray - centerBrightnessNorm) / midGray)
        let deepDarkRatioNorm = clamp01(g.deepDarkRatio / 0.3)
        let under = 0.30*globalDarkness + 0.25*darkTileCoverage + 0.25*lackOfBrightTiles + 0.15*centerDarkness + 0.05*deepDarkRatioNorm

        // overexposed
        let highlightClipNorm = clamp01(g.highlightRatio / 0.3)
        let brightHighlightTiles = features.tiles.filter { $0.highlightRatio > 0.5 }.count
        let brightTileCoverage = Double(brightHighlightTiles) / Double(tileCount)
        let lackOfShadowAnchor = 1.0 - Double(darkTileCount) / Double(tileCount)
        let highlightHeadroomLow = clamp01((g.p99Norm - 0.95) / 0.05)
        let over = 0.40*highlightClipNorm + 0.30*brightTileCoverage + 0.20*lackOfShadowAnchor + 0.10*highlightHeadroomLow

        // blurry
        var blur: Double = 0
        if features.blur.usableTileRatio > 0 {
            let lapLow = max(laplacianLowThreshold, 0.0000001)
            let usableAreaLaplacianLow = clamp01((lapLow - features.blur.usableAreaLaplacianVarianceNorm) / lapLow)
            let centerLaplacianLow = clamp01((lapLow - features.blur.centerLaplacianVarianceNorm) / lapLow)
            let sharpTileRatioLow = 1.0 - features.blur.sharpTileRatio
            blur = 0.40*usableAreaLaplacianLow + 0.30*centerLaplacianLow + 0.20*sharpTileRatioLow + 0.10*features.blur.lowContrastTileRatio
        }
        return analysisScores(underexposed: under, overexposed: over, blurry: blur)
    }

    public static func classify(scores: analysisScores, config: analysisConfig) -> primaryIssue {
        let s = config.scoring
        if scores.overexposed >= s.overexposedThreshold { return .overexposed }
        if scores.underexposed >= s.underexposedThreshold { return .underexposed }
        if scores.blurry >= s.blurryThreshold { return .blurry }
        return .normal
    }
}

public func mapPrimaryToFields(_ primary: primaryIssue) -> (exposureStatus: String, isBlurry: Bool) {
    switch primary {
    case .normal: return ("normal", false)
    case .underexposed: return ("underexposed", false)
    case .overexposed: return ("overexposed", false)
    case .blurry: return ("normal", true)
    case .failed: return ("failed", false)
    }
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
```

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -3
# 预期：BUILD SUCCEEDED
```

✅ **完成标志：** 构建通过（新文件落盘即编译，纯 Swift 逻辑无运行依赖）。

## Task 4: RAW 分析器重写

**目标：** `rawBayerAnalyzer` 产出全局/网格特征 → 评分 → 主因分类 → 映射回 `exposureStatus`/`isBlurry`，并在 `--debug` 下携带 debugInfo。

**涉及的文件：**
- `rawViewer/services/rawBayerAnalyzer.swift` — 重写

### Step 1 — 实现

`rawViewer/services/rawBayerAnalyzer.swift`（完整新内容）：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-22
Description: RAW Bayer 分析：LibRaw 取数据 + Metal 全局/网格直方图 + 每格 Laplacian + 共享评分引擎。v1.5 用全局+网格特征 + 主因分类替代单阈值
*/

import Foundation
import Metal

nonisolated public struct rawAnalysisResult: Sendable {
    public let isBlurry: Bool
    public let exposureStatus: String
    public let dynamicRange: dynamicRangeData?
    public let blackLevel: Int
    public let whiteLevel: Int
    public let analysisSource: String
    public let debugInfo: analysisDebugInfo?

    public init(
        isBlurry: Bool,
        exposureStatus: String,
        dynamicRange: dynamicRangeData?,
        blackLevel: Int,
        whiteLevel: Int,
        analysisSource: String = "raw",
        debugInfo: analysisDebugInfo? = nil
    ) {
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.dynamicRange = dynamicRange
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.analysisSource = analysisSource
        self.debugInfo = debugInfo
    }
}

nonisolated public protocol rawBayerAnalyzing: AnyObject, Sendable {
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

struct rawGridHistConfigGpu {
    var planeWidth: UInt32
    var planeHeight: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
    var binCount: UInt32
    var range: Float
    var darkThreshold: Float
    var deepDarkThreshold: Float
    var highlightThreshold: Float
}

struct gridReduceConfigGpu {
    var width: UInt32
    var height: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
}

struct perTileStatsGpu {
    var sum: Float
    var sumSq: Float
}

nonisolated public final class rawBayerAnalyzer: rawBayerAnalyzing, @unchecked Sendable {
    private let contextProvider: @Sendable () throws -> metalAnalysisContext

    public init(contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() }) {
        self.contextProvider = contextProvider
    }

    public func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        guard let handle = rwRawOpen(rawPath) else {
            throw makeError("LibRaw open_file returned null for \(rawPath)")
        }
        defer { rwRawClose(handle) }

        let errorMsg = String(cString: rwRawLastError(handle))
        if !errorMsg.isEmpty {
            throw makeError("LibRaw error: \(errorMsg)")
        }

        let data = rwRawGetBayerData(handle)
        guard data.rawWidth > 0, data.rawHeight > 0, data.rawImage != nil else {
            throw makeError("LibRaw returned empty Bayer data")
        }

        let black = Int(data.blackLevel)
        let white = Int(data.whiteLevel)
        guard white > black else {
            throw makeError("Invalid black/white level: black=\(black) white=\(white)")
        }

        let visibleW = Int(data.visibleWidth)
        let visibleH = Int(data.visibleHeight)
        let rawW = Int(data.rawWidth)
        let rawH = Int(data.rawHeight)
        let range = Double(white - black)

        let totalRaw = rawW * rawH
        guard let rawBuffer = context.device.makeBuffer(
            length: totalRaw * MemoryLayout<UInt16>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, totalRaw * MemoryLayout<UInt16>.size)

        let absOver = UInt32(black) + UInt32(Double(white - black) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(black) + UInt32(Double(white - black) * config.exposure.underexposePixelThreshold)

        let binCount: UInt32 = 4096
        let gridRows = UInt32(config.grid.rows)
        let gridCols = UInt32(config.grid.columns)
        let gridBinCount: UInt32 = 64
        let tileCount = Int(gridRows * gridCols)

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

        let greenW = visibleW / 2
        let greenH = visibleH / 2
        guard greenW > 0, greenH > 0 else {
            throw makeError("Visible area too small for green plane")
        }
        guard let greenBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc greenBuffer") }

        guard let lapBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }

        guard let gridHistBuffer = context.device.makeBuffer(
            length: tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc gridHistBuffer") }
        memset(gridHistBuffer.contents(), 0, tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size)

        guard let gridCountBuffer = context.device.makeBuffer(
            length: tileCount * 4 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc gridCountBuffer") }
        memset(gridCountBuffer.contents(), 0, tileCount * 4 * MemoryLayout<UInt32>.size)

        guard let perTileStatsBuffer = context.device.makeBuffer(
            length: tileCount * MemoryLayout<perTileStatsGpu>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc perTileStatsBuffer") }

        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // Dispatch 1: bayerHistogramKernel (全局 4 通道直方图 + 曝光计数)
        var histConfig = bayerHistConfig(
            rawWidth: UInt32(rawW), rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX), visibleOffsetY: UInt32(data.visibleOffsetY),
            visibleWidth: UInt32(visibleW), visibleHeight: UInt32(visibleH),
            binCount: binCount, blackLevel: UInt32(black), whiteLevel: UInt32(white),
            overThreshold: absOver, underThreshold: absUnder
        )
        let totalVisible = visibleW * visibleH
        let histGroupSize = 256
        let histGroupCount = (totalVisible + histGroupSize - 1) / histGroupSize
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
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
        var greenConfig = greenPlaneConfig(
            rawWidth: UInt32(rawW), rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX), visibleOffsetY: UInt32(data.visibleOffsetY),
            greenWidth: UInt32(greenW), greenHeight: UInt32(greenH), blackLevel: UInt32(black)
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
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
        var lapConfig = greenLaplacianConfig(width: UInt32(greenW), height: UInt32(greenH))
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
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

        // Dispatch 4: reduceLaplacianPerTileKernel (每格 Laplacian sum/sumSq)
        var gridReduceConfig = gridReduceConfigGpu(width: UInt32(greenW), height: UInt32(greenH), gridRows: gridRows, gridCols: gridCols)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.reduceLaplacianPerTilePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(perTileStatsBuffer, offset: 0, index: 1)
            encoder.setBytes(&gridReduceConfig, length: MemoryLayout<gridReduceConfigGpu>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: tileCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 5: rawGridHistogramKernel (每格亮度直方图 + 计数)
        var rawGridConfig = rawGridHistConfigGpu(
            planeWidth: UInt32(greenW), planeHeight: UInt32(greenH),
            gridRows: gridRows, gridCols: gridCols, binCount: gridBinCount,
            range: Float(range),
            darkThreshold: Float(config.exposure.underexposePixelThreshold) * Float(range),
            deepDarkThreshold: Float(config.scoring.deepDarkPixelThreshold) * Float(range),
            highlightThreshold: Float(config.exposure.overexposePixelThreshold) * Float(range)
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.rawGridHistogramPipeline)
            encoder.setBuffer(greenBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridHistBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridCountBuffer, offset: 0, index: 2)
            encoder.setBytes(&rawGridConfig, length: MemoryLayout<rawGridHistConfigGpu>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 4 * Int(binCount))
        let greenHist = Array(UnsafeBufferPointer(start: histPtr.advanced(by: Int(binCount)), count: Int(binCount)))

        let globalFeatures = buildGlobalExposureFeatures(
            histogram: greenHist, binCount: Int(binCount),
            darkThresholdNorm: config.exposure.underexposePixelThreshold,
            deepDarkThresholdNorm: config.scoring.deepDarkPixelThreshold,
            highlightThresholdNorm: config.exposure.overexposePixelThreshold
        )

        let gridHistPtr = gridHistBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * Int(gridBinCount))
        let gridCountPtr = gridCountBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * 4)
        let statsPtr = perTileStatsBuffer.contents().bindMemory(to: perTileStatsGpu.self, capacity: tileCount)
        let gridHistArray = Array(UnsafeBufferPointer(start: gridHistPtr, count: tileCount * Int(gridBinCount)))

        var tiles: [tileFeatures] = []
        tiles.reserveCapacity(tileCount)
        for t in 0..<tileCount {
            let pixelCount = Double(gridCountPtr[t * 4 + 0])
            let darkCount = Double(gridCountPtr[t * 4 + 1])
            let deepDarkCount = Double(gridCountPtr[t * 4 + 2])
            let highlightCount = Double(gridCountPtr[t * 4 + 3])
            let tf = buildTileFeatures(
                histogram: gridHistArray, histogramOffset: t * Int(gridBinCount), binCount: Int(gridBinCount),
                pixelCount: pixelCount, darkCount: darkCount, deepDarkCount: deepDarkCount, highlightCount: highlightCount,
                laplacianSum: Double(statsPtr[t].sum), laplacianSumSq: Double(statsPtr[t].sumSq), range: range,
                usableMinBrightness: config.scoring.usableTileMinBrightnessRaw,
                usableMinContrast: config.scoring.usableTileMinContrastRaw
            )
            tiles.append(tf)
        }

        let blur = buildBlurFeatures(
            tiles: tiles, gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns,
            sharpTileLaplacianThreshold: config.scoring.sharpTileLaplacianThresholdRaw,
            lowContrastTileThreshold: config.scoring.lowContrastTileThresholdRaw
        )

        let features = analysisFeatures(
            globalExposure: globalFeatures, tiles: tiles, blur: blur,
            gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns
        )

        let scores = scoringEngine.score(features: features, config: config, valueSpace: .rawLinear)
        let primary = scoringEngine.classify(scores: scores, config: config)
        let fields = mapPrimaryToFields(primary)

        // 动态范围 (复用全局特征百分位)
        let p01Code = globalFeatures.p01Norm * range
        let p999Code = globalFeatures.p99Norm * range
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
        let dr = dynamicRangeData(sceneSpreadEv: sceneSpreadEv, codeRangeEv: codeRangeEv, blackLevel: black, whiteLevel: white)

        let debugInfo = analysisDebugInfo(features: features, scores: scores, primary: primary)
        return rawAnalysisResult(
            isBlurry: fields.isBlurry,
            exposureStatus: fields.exposureStatus,
            dynamicRange: dr,
            blackLevel: black,
            whiteLevel: white,
            analysisSource: "raw",
            debugInfo: debugInfo
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "rawViewer.rawBayerAnalyzer", code: 999, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
```

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -3
# 预期：BUILD SUCCEEDED
```

✅ **完成标志：** 构建通过。此时 RAW 路径已产出特征/评分/分类；`jpgAnalyzer` 仍可通过 Task 2 保留的旧 `reducePipeline` 编译运行，因此 Task 4 可以独立验证。

## Task 5: JPG 分析器重写

**目标：** `jpgAnalyzer` 与 RAW 走同一套评分逻辑（`.jpgGamma` 值空间），产出特征/评分/分类/映射。

**涉及的文件：**
- `rawViewer/services/jpgAnalyzer.swift` — 重写

### Step 1 — 实现

`rawViewer/services/jpgAnalyzer.swift`（完整新内容）：

```swift
/*
Author: wilbur
Version: 1.6
Date: 2026-06-22
Description: JPG 兜底分析：CoreImage 渲染到 RGBA texture，Metal 全局/网格直方图 + 每格 Laplacian + 共享评分引擎。v1.6 改用全局+网格特征 + 主因分类
*/

import Foundation
import Metal
import CoreImage

nonisolated public protocol jpgAnalyzing: AnyObject, Sendable {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
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

struct jpgGridHistConfigGpu {
    var planeWidth: UInt32
    var planeHeight: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
    var binCount: UInt32
    var darkThreshold: Float
    var deepDarkThreshold: Float
    var highlightThreshold: Float
}

nonisolated public final class jpgAnalyzer: jpgAnalyzing, @unchecked Sendable {
    private let contextProvider: @Sendable () throws -> metalAnalysisContext
    private let maxJpgPixels: Int

    public init(
        contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() },
        maxJpgPixels: Int = 100_000_000
    ) {
        self.contextProvider = contextProvider
        self.maxJpgPixels = maxJpgPixels
    }

    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        let ciContext = CIContext(mtlDevice: context.device)

        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            throw makeError("Failed to load CIImage from \(jpgPath)")
        }
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else { throw makeError("CIImage has zero dimensions") }
        let totalPixels = width * height
        guard totalPixels <= maxJpgPixels else { throw makeError("JPG too large: \(width)x\(height)") }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        texDesc.usage = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: texDesc) else { throw makeError("Failed to create RGBA texture") }

        guard let grayBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<UInt8>.size, options: .storageModeShared) else { throw makeError("alloc grayBuffer") }
        guard let lapBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<Float>.size, options: .storageModeShared) else { throw makeError("alloc lapBuffer") }
        guard let histBuffer = context.device.makeBuffer(length: 256 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.size)
        guard let exposureBuffer = context.device.makeBuffer(length: 2 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)

        let gridRows = UInt32(config.grid.rows)
        let gridCols = UInt32(config.grid.columns)
        let gridBinCount: UInt32 = 64
        let tileCount = Int(gridRows * gridCols)
        guard let gridHistBuffer = context.device.makeBuffer(length: tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc gridHistBuffer") }
        memset(gridHistBuffer.contents(), 0, tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size)
        guard let gridCountBuffer = context.device.makeBuffer(length: tileCount * 4 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc gridCountBuffer") }
        memset(gridCountBuffer.contents(), 0, tileCount * 4 * MemoryLayout<UInt32>.size)
        guard let perTileStatsBuffer = context.device.makeBuffer(length: tileCount * MemoryLayout<perTileStatsGpu>.size, options: .storageModeShared) else { throw makeError("alloc perTileStatsBuffer") }

        guard let cmd = context.commandQueue.makeCommandBuffer() else { throw makeError("makeCommandBuffer") }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ciImage, to: texture, commandBuffer: cmd, bounds: ciImage.extent, colorSpace: colorSpace)

        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)

        // Dispatch 1: rgbToGray
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.rgbToGrayPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            var totalPx = UInt32(totalPixels)
            encoder.setBytes(&totalPx, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 2: jpgHistogram (全局)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            var histConfig = jpgHistConfig(totalPixels: UInt32(totalPixels), overThreshold: absOver, underThreshold: absUnder)
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
            let groupSize = 256
            let groupCount = (totalPixels + groupSize - 1) / groupSize
            encoder.dispatchThreadgroups(MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 3: jpgLaplacian
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgLaplacianPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            var lapConfig = jpgLaplacianConfig(width: UInt32(width), height: UInt32(height))
            encoder.setBytes(&lapConfig, length: MemoryLayout<jpgLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 4: reduceLaplacianPerTile
        var gridReduceConfig = gridReduceConfigGpu(width: UInt32(width), height: UInt32(height), gridRows: gridRows, gridCols: gridCols)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.reduceLaplacianPerTilePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(perTileStatsBuffer, offset: 0, index: 1)
            encoder.setBytes(&gridReduceConfig, length: MemoryLayout<gridReduceConfigGpu>.size, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: tileCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 5: jpgGridHistogram
        var jpgGridConfig = jpgGridHistConfigGpu(
            planeWidth: UInt32(width), planeHeight: UInt32(height),
            gridRows: gridRows, gridCols: gridCols, binCount: gridBinCount,
            darkThreshold: Float(config.exposure.underexposePixelThreshold) * 255.0,
            deepDarkThreshold: Float(config.scoring.deepDarkPixelThreshold) * 255.0,
            highlightThreshold: Float(config.exposure.overexposePixelThreshold) * 255.0
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgGridHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridHistBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridCountBuffer, offset: 0, index: 2)
            encoder.setBytes(&jpgGridConfig, length: MemoryLayout<jpgGridHistConfigGpu>.size, index: 3)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        let histArray = Array(UnsafeBufferPointer(start: histPtr, count: 256))
        let range = 255.0
        let globalFeatures = buildGlobalExposureFeatures(
            histogram: histArray, binCount: 256,
            darkThresholdNorm: config.exposure.underexposePixelThreshold,
            deepDarkThresholdNorm: config.scoring.deepDarkPixelThreshold,
            highlightThresholdNorm: config.exposure.overexposePixelThreshold
        )

        let gridHistPtr = gridHistBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * Int(gridBinCount))
        let gridCountPtr = gridCountBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * 4)
        let statsPtr = perTileStatsBuffer.contents().bindMemory(to: perTileStatsGpu.self, capacity: tileCount)
        let gridHistArray = Array(UnsafeBufferPointer(start: gridHistPtr, count: tileCount * Int(gridBinCount)))

        var tiles: [tileFeatures] = []
        tiles.reserveCapacity(tileCount)
        for t in 0..<tileCount {
            let pixelCount = Double(gridCountPtr[t * 4 + 0])
            let tf = buildTileFeatures(
                histogram: gridHistArray, histogramOffset: t * Int(gridBinCount), binCount: Int(gridBinCount),
                pixelCount: pixelCount, darkCount: Double(gridCountPtr[t * 4 + 1]),
                deepDarkCount: Double(gridCountPtr[t * 4 + 2]), highlightCount: Double(gridCountPtr[t * 4 + 3]),
                laplacianSum: Double(statsPtr[t].sum), laplacianSumSq: Double(statsPtr[t].sumSq), range: range,
                usableMinBrightness: config.scoring.usableTileMinBrightnessJpg,
                usableMinContrast: config.scoring.usableTileMinContrastJpg
            )
            tiles.append(tf)
        }

        let blur = buildBlurFeatures(
            tiles: tiles, gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns,
            sharpTileLaplacianThreshold: config.scoring.sharpTileLaplacianThresholdJpg,
            lowContrastTileThreshold: config.scoring.lowContrastTileThresholdJpg
        )

        let features = analysisFeatures(
            globalExposure: globalFeatures, tiles: tiles, blur: blur,
            gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns
        )
        let scores = scoringEngine.score(features: features, config: config, valueSpace: .jpgGamma)
        let primary = scoringEngine.classify(scores: scores, config: config)
        let fields = mapPrimaryToFields(primary)

        let p01Code = Double(globalFeatures.p01Norm) * range
        let p999Code = Double(globalFeatures.p99Norm) * range
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
        let dr = dynamicRangeData(sceneSpreadEv: sceneSpreadEv, codeRangeEv: codeRangeEv, blackLevel: 0, whiteLevel: 255)

        let debugInfo = analysisDebugInfo(features: features, scores: scores, primary: primary)
        return rawAnalysisResult(
            isBlurry: fields.isBlurry,
            exposureStatus: fields.exposureStatus,
            dynamicRange: dr,
            blackLevel: 0,
            whiteLevel: 255,
            analysisSource: "jpg",
            debugInfo: debugInfo
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "rawViewer.jpgAnalyzer", code: 999, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
```

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -3
# 预期：BUILD SUCCEEDED（RAW + JPG 两个 analyzer 与共享评分引擎全部编译通过）
```

✅ **完成标志：** 构建通过。此时整个新算法链路编译完整，可进入校准。

---

## Task 6: 校准 dump 与阈值校准

**目标：** 在 `--debug` 下把每张图的特征/分数/主因写到 `calibration.txt`；用 `0621` 跑一次，依据 dump 调整 `scoring` 阈值，使 4 张真欠曝 `underexposedScore >= 0.55`、13 张误报 `< 0.55`。

**涉及的文件：**
- `rawViewer/services/photoAnalysisService.swift` — 分析完成后写 dump

### Step 1 — 实现

在 `photoAnalysisService.swift` 的 `analyze(folderUrl:progress:)` 中，找到 `let analysisResults = await runAnalysisStage(pairs: pairs, config: config, totalCount: totalCount, progress: progress)`，在它之后、`progress(analysisProgress(phase: .duplicateGrouping, completedCount: 0, totalCount: totalCount, overallProgress: 0.85))` 之前，插入校准 dump 调用；并新增私有方法。

插入调用（在 `analysisResults` 赋值后）：

```swift
        writeCalibrationDumpIfDebug(folderUrl: folderUrl, results: analysisResults, config: config)
```

新增私有方法（放在 `computeSummary` 之后）：

```swift
    private func writeCalibrationDumpIfDebug(folderUrl: URL, results: [analysisStageResult], config: analysisConfig) {
        guard appDebugLogger.isEnabled else { return }
        let dir = store.resultsUrl(for: folderUrl).deletingLastPathComponent()
        let url = dir.appendingPathComponent("calibration.txt")
        var lines: [String] = []
        lines.append("photoId\tsource\tmeanNorm\tmedianNorm\tp10\tp90\tp99\tdarkRatio\tdeepDarkRatio\tdarkTileCov\tbrightTileCov\tcenterBrightNorm\tusableTileRatio\tunderScore\toverScore\tblurScore\tprimary")
        for r in results {
            guard let d = r.result.debugInfo else { continue }
            let g = d.features.globalExposure
            let tiles = d.features.tiles
            let tc = max(1, tiles.count)
            let isRaw = r.result.analysisSource == "raw"
            let darkThreshold = isRaw ? config.scoring.darkTileMeanThresholdRaw : config.scoring.darkTileMeanThresholdJpg
            let brightThreshold = isRaw ? config.scoring.brightTileP90ThresholdRaw : config.scoring.brightTileP90ThresholdJpg
            let darkTiles = tiles.filter { $0.meanNorm < darkThreshold }.count
            let brightTiles = tiles.filter { $0.p90Norm > brightThreshold }.count
            let centerBright = centerBrightness(features: d.features)
            lines.append("\(r.photoId)\t\(r.result.analysisSource)\t\(String(format: "%.4f", g.meanNorm))\t\(String(format: "%.4f", g.medianNorm))\t\(String(format: "%.4f", g.p10Norm))\t\(String(format: "%.4f", g.p90Norm))\t\(String(format: "%.4f", g.p99Norm))\t\(String(format: "%.4f", g.darkRatio))\t\(String(format: "%.4f", g.deepDarkRatio))\t\(String(format: "%.3f", Double(darkTiles)/Double(tc)))\t\(String(format: "%.3f", Double(brightTiles)/Double(tc)))\t\(String(format: "%.4f", centerBright))\t\(String(format: "%.3f", d.features.blur.usableTileRatio))\t\(String(format: "%.3f", d.scores.underexposed))\t\(String(format: "%.3f", d.scores.overexposed))\t\(String(format: "%.3f", d.scores.blurry))\t\(d.primary.rawValue)")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        appDebugLogger.log("calibration dump written to \(url.path)")
    }

    private func centerBrightness(features: analysisFeatures) -> Double {
        let rowStart = (features.gridRows - features.centerRows) / 2
        let colStart = (features.gridCols - features.centerCols) / 2
        var sum: Double = 0
        var n = 0
        for r in 0..<features.gridRows {
            for c in 0..<features.gridCols {
                if r >= rowStart && r < rowStart + features.centerRows && c >= colStart && c < colStart + features.centerCols {
                    let idx = r * features.gridCols + c
                    if idx < features.tiles.count { sum += features.tiles[idx].meanNorm; n += 1 }
                }
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }
```

### Step 2 — 运行验证（首次跑 dump）

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -2
# 预期：BUILD SUCCEEDED

$ rm -f ~/Library/Application\ Support/rawViewer/3ED13108F536342E/analysis.json
$ timeout 120 build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --debug --folder=/Users/wilbur/Downloads/0621 >/dev/null 2>&1 ; true
$ cat ~/Library/Application\ Support/rawViewer/3ED13108F536342E/calibration.txt | head -1
$ grep -E "P1002511|P1002538|P1002539|P1002552" ~/Library/Application\ Support/rawViewer/3ED13108F536342E/calibration.txt
# 预期：4 张真欠曝的 underScore 列偏高、primary=underexposed；13 张误报 underScore 偏低、primary=normal
```

### Step 3 — 阈值校准（迭代）

依据 `calibration.txt` 的列：
- 若 4 张真欠曝 `underScore < 0.55`：调低 `underexposed_threshold`，或按来源调高 `dark_tile_mean_threshold_raw/jpg`、`bright_tile_p90_threshold_raw/jpg`（让暗格/缺亮格更容易触发）；
- 若 13 张误报 `underScore >= 0.55`：调高 `underexposed_threshold`，或按来源调低 `bright_tile_p90_threshold_raw/jpg`（有亮格就别判欠曝）；
- 模糊阈值 `laplacian_low_threshold_raw/jpg`、`sharp_tile_laplacian_threshold_raw/jpg` 同理：真欠曝应被曝光优先截胡（primary=underexposed），不应判 blurry；若误报 blurry，调高 `blurry_threshold` 或按来源调整 laplacian 阈值。

修改 `rawViewer/config.yaml` 的 `scoring:` 段后重新执行 Step 2 命令（`rm analysis.json` → 重跑 → 看 `calibration.txt`），直到：
- `P1002511/P1002538/P1002539/P1002552` 的 `primary` 全部为 `underexposed`；
- 原 13 张误报的 `primary` 全部为 `normal`。

✅ **完成标志：** `calibration.txt` 中 4 张真欠曝 primary=underexposed、13 张误报 primary=normal。

---

## Task 7: 最终验收

**目标：** 重新构建并以非 debug 方式跑 `0621`，确认 `analysis.json` 的分组满足 AC1~AC5。

### Step 1 — 实现

无需改代码（阈值已在 Task 6 固化进 `config.yaml`）。

### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build build 2>&1 | tail -2
# 预期：BUILD SUCCEEDED

$ rm -f ~/Library/Application\ Support/rawViewer/3ED13108F536342E/analysis.json
$ timeout 120 build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --folder=/Users/wilbur/Downloads/0621 >/dev/null 2>&1 ; true

$ python3 - <<'PY'
import json, pathlib, sys
url = pathlib.Path.home()/'Library/Application Support/rawViewer/3ED13108F536342E/analysis.json'
d = json.loads(url.read_text())
photos = {p['photoId']: p for p in d['photos']}
positives = ['P1002511','P1002538','P1002539','P1002552']
false_positives = ['P1002441','P1002461','P1002485','P1002489','P1002490','P1002491','P1002496','P1002549','P1002551','P1002555','P1002561','P1002580','P1002581']
under = sorted(p['photoId'] for p in d['photos'] if p['exposureStatus'] == 'underexposed')
expected_under = sorted(positives)
errors = []
if under != expected_under:
    errors.append(f'underexposed mismatch: got {under}, expected {expected_under}')
for pid in positives:
    p = photos[pid]
    if p['exposureStatus'] != 'underexposed' or p['isBlurry']:
        errors.append(f'{pid} expected underexposed/non-blurry, got exp={p["exposureStatus"]} blurry={p["isBlurry"]}')
for pid in false_positives:
    p = photos[pid]
    if p['exposureStatus'] != 'normal' or p['isBlurry']:
        errors.append(f'{pid} expected normal/non-blurry, got exp={p["exposureStatus"]} blurry={p["isBlurry"]}')
print('summary:', d['summary'])
print('underexposed:', under)
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('AC1-AC4 passed')
PY
# 预期：打印 AC1-AC4 passed；summary.underexposed == 4；13 张历史误报全部 normal 且非 blurry
```

AC4（无误报 blurry）已由上面的脚本硬断言：13 张历史欠曝误报必须全部 `normal/non-blurry`。

AC5（配置变化触发重分析）：修改 **app bundle 内** 的 `config.yaml`（因为运行时读取 bundle 资源，不是源码目录），重跑并确认 `updatedAt` 与 `configSnapshot` 更新。

```bash
$ cd /Users/wilbur/project/rawViewer
$ python3 - <<'PY'
import json, pathlib
url = pathlib.Path.home()/'Library/Application Support/rawViewer/3ED13108F536342E/analysis.json'
d = json.loads(url.read_text())
print(d['updatedAt'])
PY
# 记下 oldUpdatedAt

$ python3 - <<'PY'
from pathlib import Path
cfg = Path('build/Build/Products/Debug/pickpick.app/Contents/Resources/config.yaml')
if not cfg.exists():
    cfg = Path('build/Build/Products/Debug/pickpick.app/Contents/Resources/rawViewer/config.yaml')
text = cfg.read_text()
if 'underexposed_threshold: 0.55' in text:
    text = text.replace('underexposed_threshold: 0.55', 'underexposed_threshold: 0.56')
elif 'underexposed_threshold: 0.56' in text:
    text = text.replace('underexposed_threshold: 0.56', 'underexposed_threshold: 0.55')
else:
    raise SystemExit('threshold literal not found')
cfg.write_text(text)
print(cfg)
PY

$ timeout 120 build/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick --folder=/Users/wilbur/Downloads/0621 >/dev/null 2>&1 ; true

$ python3 - <<'PY'
import json, pathlib
url = pathlib.Path.home()/'Library/Application Support/rawViewer/3ED13108F536342E/analysis.json'
d = json.loads(url.read_text())
print('updatedAt=', d['updatedAt'])
print('snapshotThreshold=', d['configSnapshot']['scoring']['underexposedThreshold'])
print('algorithmVersion=', d['configSnapshot']['analysisAlgorithmVersion'])
PY
# 预期：updatedAt 与 oldUpdatedAt 不同；snapshotThreshold 反映刚改的值；algorithmVersion=grid-v1
```

（AC5 由 `analysisStore` 的 `configSnapshot` 校验保证：Task 1 已让 `analysisConfig` 包含 `analysisAlgorithmVersion/grid/scoring`，旧单阈值缓存和任何 scoring 变化都会触发 stale 后重新分析。）

✅ **完成标志：** AC1~AC5 全部满足。

---

## 自我复审

**1. 规范覆盖：** recipe 的全局+网格特征（Task 2/4/5）、三 score 加权（Task 3）、主因分类互斥+曝光优先（Task 3）、config 结构（Task 1）、GPU/CPU 边界（Task 2/4/5）、缓存兼容（Task 1 自定义 Codable + Task 7 AC5）、校准（Task 6）、验收（Task 7）均有对应任务。

**2. 占位符扫描：** 所有代码块均为完整内容；`scoring` 初始阈值为校准起点，Task 6 提供迭代流程将其固化为真实值（非占位）。

**3. 类型一致性：** `analysisFeatures`/`analysisScores`/`primaryIssue`/`analysisDebugInfo`/`perTileStatsGpu`/`gridReduceConfigGpu` 在 Task 3/4/5 中名称一致；`rawAnalysisResult` 新增 `debugInfo` 参数带默认值，`photoAnalysisService` 的失败 fallback 构造不受影响。

**4. 验证完整性：** Task 1~7 均有 `xcodebuild` 构建命令 + 明确预期输出；Task 6/7 有 `0621` 运行命令 + Python 校验脚本与明确预期。Task 2 保留旧 reducePipeline，确保每个任务结束都可独立构建验证。

---

## 执行交接

计划已完成并保存到 `docs/flare/20260622_exposureBlurGridAlgorithm.md`。两种执行选项：

1. **子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代
2. **内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理

选择哪种方式？
