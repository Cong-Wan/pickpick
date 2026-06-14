/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: 从 folderUrl/config.yaml → Bundle.main/config.yaml → 硬编码默认值三级降级加载 config；校验 ratio、blur threshold 和 Metal 并发边界。v1.4 明确配置加载器可在后台分析任务中使用
*/

import Foundation

nonisolated public final class configLoader: @unchecked Sendable {
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
        let raw = parseSimpleYaml(text)
        return parse(raw)
    }

    // MARK: - 极简 YAML 解析器（仅支持两层嵌套的 key: value）

    /// 解析简单 YAML 为 [String: Any] 字典，支持两层嵌套、# 注释、数值/字符串值
    private func parseSimpleYaml(_ text: String) -> [String: Any] {
        var root: [String: Any] = [:]
        var currentSection: String?
        var currentDict: [String: Any] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespaces)
                let afterColon = trimmed[trimmed.index(after: colonIdx)...]
                    .trimmingCharacters(in: .whitespaces)

                if afterColon.isEmpty {
                    // 顶层 section 开头，保存上一个 section
                    if let section = currentSection {
                        root[section] = currentDict
                    }
                    currentSection = key
                    currentDict = [:]
                } else {
                    // key: value 对
                    currentDict[key] = parseValue(afterColon)
                }
            }
        }
        if let section = currentSection {
            root[section] = currentDict
        }
        return root
    }

    private func parseValue(_ raw: String) -> Any {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        if let d = Double(raw) { return d }
        if let i = Int(raw) { return i }
        if raw == "true" { return true }
        if raw == "false" { return false }
        return raw
    }

    // MARK: - 配置解析

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
