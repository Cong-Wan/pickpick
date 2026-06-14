/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值。v1.2 标注配置值可在后台分析任务中传递
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

    public init(
        laplacianThresholdRaw: Double,
        laplacianThresholdJpg: Double
    ) {
        self.laplacianThresholdRaw = laplacianThresholdRaw
        self.laplacianThresholdJpg = laplacianThresholdJpg
    }
}

nonisolated public struct analysisConfig: Codable, Equatable, Sendable {
    public var exposure: exposureConfig
    public var blur: blurConfig
    public var metalConcurrency: Int

    public init(exposure: exposureConfig, blur: blurConfig, metalConcurrency: Int) {
        self.exposure = exposure
        self.blur = blur
        self.metalConcurrency = metalConcurrency
    }
}

nonisolated public extension analysisConfig {
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
