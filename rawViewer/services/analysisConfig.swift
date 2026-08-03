/*
Author: wilbur
Version: 1.9
Date: 2026-08-03
Description: 分析参数配置结构。v1.9 彻底关闭曝光/虚焦检测：精简为仅含 analysisAlgorithmVersion（用于缓存校验），删除 exposure/blur/grid/scoring/metalConcurrency 配置；bump algorithmVersion 为 no-analysis-v1 使旧缓存失效
*/

import Foundation

nonisolated public struct analysisConfig: Codable, Equatable, Sendable {
    public var analysisAlgorithmVersion: String

    public init(analysisAlgorithmVersion: String = analysisConfig.currentAlgorithmVersion) {
        self.analysisAlgorithmVersion = analysisAlgorithmVersion
    }

    private enum codingKeys: String, CodingKey {
        case analysisAlgorithmVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: codingKeys.self)
        self.analysisAlgorithmVersion = try c.decodeIfPresent(String.self, forKey: .analysisAlgorithmVersion) ?? analysisConfig.currentAlgorithmVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: codingKeys.self)
        try c.encode(analysisAlgorithmVersion, forKey: .analysisAlgorithmVersion)
    }
}

nonisolated public extension analysisConfig {
    static let currentAlgorithmVersion = "no-analysis-v1"
    static let legacyAlgorithmVersion = "grid-v1"

    static let defaults = analysisConfig()
}
