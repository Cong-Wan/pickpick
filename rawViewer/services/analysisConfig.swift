/*
Author: wilbur
Version: 1.3
Date: 2026-06-17
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值；同步默认参数到 rawViewer/config.yaml，避免 bundle 配置缺失时回退旧严格阈值
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
            overexposePixelThreshold: 0.975,
            underexposePixelThreshold: 0.025,
            overexposeRatioLimit: 0.05,
            underexposeRatioLimit: 0.05
        ),
        blur: blurConfig(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0
        ),
        metalConcurrency: 6
    )
}
