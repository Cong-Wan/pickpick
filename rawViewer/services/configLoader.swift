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
        let concurrency = min(max(rawConcurrency, 1), 8)

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
