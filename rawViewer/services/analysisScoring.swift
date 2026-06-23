/*
Author: wilbur
Version: 1.0
Date: 2026-06-23
Description: 曝光/模糊评分引擎 + 主因分类器 + 特征构建器，RAW/JPG 共用。构建全局/网格特征后算 underexposed/overexposed/blurry 三个 score，分类器按曝光优先→模糊→normal 给出唯一 primaryIssue；模糊评分带整体亮度闸门(meanNorm>=blurMinBrightnessRaw/Jpg)，暗图缺乏可靠 Laplacian 信号不参与模糊评分，避免暗而清晰照片被误判 blurry
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
        // 校准: 仅当整体亮度足够时才评估模糊——暗照片(meanNorm 低于阈值)的 Laplacian 方差低是因亮度不足而非失焦，
        // 缺乏强模糊证据(AC4)，故不参与模糊评分。RAW/JPG 值空间不同，阈值分开。
        let blurMinBrightness = isRaw ? s.blurMinBrightnessRaw : s.blurMinBrightnessJpg
        if features.globalExposure.meanNorm >= blurMinBrightness {
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
