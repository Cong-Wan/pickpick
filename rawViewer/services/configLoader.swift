/*
Author: wilbur
Version: 1.9
Date: 2026-06-25
Description: 配置加载顺序统一为 app bundle config.yaml → 硬编码默认值；兼容 bundle 根目录和 rawViewer 子目录资源，并通过 --debug 输出实际配置来源。v1.7 解析 grid_analysis/scoring 段（含 blur_min_brightness_raw/jpg），新增 clampedInt 对网格行列做安全 clamp；v1.8 metal_concurrency clamp 上限 8→4，配合默认并发降低分析内存峰值；v1.9 剥离 YAML 行内注释并在值解析回退字符串时输出 debug 反馈
*/

import Foundation

nonisolated public final class configLoader: @unchecked Sendable {
    public init() {}

    /// 加载顺序: Bundle.main/config.yaml > Bundle.main/rawViewer/config.yaml > defaults
    public func load(for _: URL) throws -> analysisConfig {
        if let bundleConfig = bundleConfigUrl() {
            appDebugLogger.log("analysis config loaded from bundle: \(bundleConfig.path)")
            return try load(from: bundleConfig)
        }
        appDebugLogger.log("analysis config bundle file missing, using defaults")
        return analysisConfig.defaults
    }

    private func bundleConfigUrl() -> URL? {
        Bundle.main.url(forResource: "config", withExtension: "yaml")
            ?? Bundle.main.url(forResource: "config", withExtension: "yaml", subdirectory: "rawViewer")
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

            let lineNoComment = stripInlineComment(trimmed)
            if lineNoComment.isEmpty { continue }

            if let colonIdx = lineNoComment.firstIndex(of: ":") {
                let key = lineNoComment[..<colonIdx].trimmingCharacters(in: .whitespaces)
                let afterColon = lineNoComment[lineNoComment.index(after: colonIdx)...]
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

    /// 剥离 YAML 行内注释：首个引号外的 "#"（井号前需为空白或行首）之后视为注释。
    /// 当前 config.yaml 的值均为简单标量，此实现足够；引号内的 # 不剥离。
    private func stripInlineComment(_ value: String) -> String {
        var inQuotes = false
        let chars = Array(value)
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes {
                if i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                    return String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return value
    }

    private func parseValue(_ raw: String) -> Any {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        if let d = Double(raw) { return d }
        if let i = Int(raw) { return i }
        if raw == "true" { return true }
        if raw == "false" { return false }
        appDebugLogger.log("config value parsed as string (fallback): \(raw)")
        return raw
    }

    // MARK: - 配置解析

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
            laplacianLowThresholdJpg: nonNegativeValue(scoringNode["laplacian_low_threshold_jpg"], default: analysisConfig.defaults.scoring.laplacianLowThresholdJpg),
            blurMinBrightnessRaw: ratioValue(scoringNode["blur_min_brightness_raw"], default: analysisConfig.defaults.scoring.blurMinBrightnessRaw),
            blurMinBrightnessJpg: ratioValue(scoringNode["blur_min_brightness_jpg"], default: analysisConfig.defaults.scoring.blurMinBrightnessJpg)
        )

        let rawConcurrency = intValue(analysisNode["metal_concurrency"]) ?? analysisConfig.defaults.metalConcurrency
        let concurrency = min(max(rawConcurrency, 1), 4)

        return analysisConfig(exposure: exposure, blur: blur, grid: grid, scoring: scoring, metalConcurrency: concurrency)
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

    private func clampedInt(_ any: Any?, default defaultValue: Int, min minValue: Int, max maxValue: Int) -> Int {
        let raw = intValue(any) ?? defaultValue
        return Swift.min(Swift.max(raw, minValue), maxValue)
    }
}
