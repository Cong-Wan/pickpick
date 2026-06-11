/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值。v1.1 移除未生效的拉普拉斯核大小配置，保持 config schema 与 Metal 3x3 kernel 行为一致
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
