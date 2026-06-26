/*
Author: wilbur
Version: 1.8
Date: 2026-06-25
Description: 分析参数配置结构 (algorithmVersion / exposure / blur / grid / scoring / concurrency) + 默认值；v1.5 新增网格分析与评分配置，并用 analysisAlgorithmVersion 让旧单阈值缓存明确失效；v1.6 校准：underexposed_threshold 默认值 0.55→0.855，使仅 4 张真欠曝越过阈值；v1.7 新增 blurMinBrightnessRaw/Jpg，暗图(meanNorm<0.10)缺乏可靠 Laplacian 信号不参与模糊评分，消除暗而清晰照片的假模糊(AC4)；v1.8 默认 metalConcurrency 6→3，降低 RAW 并发分析瞬时内存峰值(改 configSnapshot 让旧缓存失效触发重新分析，属正常机制)
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
    public var blurMinBrightnessRaw: Double
    public var blurMinBrightnessJpg: Double

    public init(
        underexposedThreshold: Double = 0.855,
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
        laplacianLowThresholdJpg: Double = 0.0005,
        blurMinBrightnessRaw: Double = 0.10,
        blurMinBrightnessJpg: Double = 0.15
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
        self.blurMinBrightnessRaw = blurMinBrightnessRaw
        self.blurMinBrightnessJpg = blurMinBrightnessJpg
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
        metalConcurrency: 3,
        analysisAlgorithmVersion: currentAlgorithmVersion
    )
}
