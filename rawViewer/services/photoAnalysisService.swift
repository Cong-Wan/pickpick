/*
Author: wilbur
Version: 1.6
Date: 2026-06-17
Description: 主编排, 替代原 photoAnalyzerBridge；加载缓存时校验当前分析配置，configSnapshot 不一致则让上层重新分析；v1.6 在 --debug 下写 calibration dump 供阈值校准
*/

import Foundation

// MARK: - Summary

public struct analysisSummary {
    public let totalPhotos: Int
    public let blurryCount: Int
    public let overexposedCount: Int
    public let underexposedCount: Int
    public let normalCount: Int

    public init(
        totalPhotos: Int,
        blurryCount: Int,
        overexposedCount: Int,
        underexposedCount: Int,
        normalCount: Int
    ) {
        self.totalPhotos = totalPhotos
        self.blurryCount = blurryCount
        self.overexposedCount = overexposedCount
        self.underexposedCount = underexposedCount
        self.normalCount = normalCount
    }
}

// MARK: - Protocol

public protocol photoAnalyzing: AnyObject {
    func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary

    func loadRecords(folderUrl: URL) throws -> [photoItem]
}

// MARK: - Service

public final class photoAnalysisService: photoAnalyzing {

    private let scanner: fileScanner
    private let exif: exifReader
    private let grouper: duplicateGrouper
    private let rawAnalyzer: rawBayerAnalyzing
    private let jpgAnalyzerService: any jpgAnalyzing
    private let store: analysisStore
    private let cfgLoader: configLoader

    public init(
        scanner: fileScanner = fileScanner(),
        exif: exifReader = exifReader(),
        grouper: duplicateGrouper = duplicateGrouper(),
        rawAnalyzer: rawBayerAnalyzing = rawBayerAnalyzer(),
        jpgAnalyzerService: (any jpgAnalyzing)? = nil,
        store: analysisStore = .shared,
        cfgLoader: configLoader = configLoader()
    ) {
        self.scanner = scanner
        self.exif = exif
        self.grouper = grouper
        self.rawAnalyzer = rawAnalyzer
        self.jpgAnalyzerService = jpgAnalyzerService ?? jpgAnalyzer()
        self.store = store
        self.cfgLoader = cfgLoader
    }

    private struct exifStageResult {
        let index: Int
        let pair: photoFilePair
        let item: photoItem
        let shootingTime: duplicateGrouper.entry?
    }

    private struct analysisStageResult {
        let index: Int
        let photoId: String
        let result: rawAnalysisResult
        let phase: analysisPhase
    }

    // MARK: - Analyze

    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = try cfgLoader.load(for: folderUrl)

        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))
        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalCount = pairs.count
        guard totalCount > 0 else {
            progress(analysisProgress(phase: .completed, completedCount: 0, totalCount: 0, overallProgress: 1.0))
            return analysisSummary(totalPhotos: 0, blurryCount: 0, overexposedCount: 0, underexposedCount: 0, normalCount: 0)
        }

        progress(analysisProgress(phase: .exifReading, completedCount: 0, totalCount: totalCount, overallProgress: 0.1))
        let exifResults = await runExifStage(pairs: pairs, totalCount: totalCount, progress: progress)

        var recordsById: [String: photoItem] = [:]
        var shootingTimes: [duplicateGrouper.entry] = []
        for result in exifResults {
            recordsById[result.item.photoId] = result.item
            if let shootingTime = result.shootingTime {
                shootingTimes.append(shootingTime)
            }
        }

        progress(analysisProgress(phase: .rawAnalysis, completedCount: 0, totalCount: totalCount, overallProgress: 0.2))
        let analysisResults = await runAnalysisStage(pairs: pairs, config: config, totalCount: totalCount, progress: progress)

        writeCalibrationDumpIfDebug(folderUrl: folderUrl, results: analysisResults, config: config)

        for result in analysisResults {
            if var item = recordsById[result.photoId] {
                item.isBlurry = result.result.isBlurry
                item.exposureStatus = result.result.exposureStatus
                item.dynamicRange = result.result.dynamicRange
                item.analysisSource = result.result.analysisSource
                recordsById[result.photoId] = item
            }
        }

        progress(analysisProgress(phase: .duplicateGrouping, completedCount: 0, totalCount: totalCount, overallProgress: 0.85))
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, groupId) in groupMap {
            if var item = recordsById[photoId] {
                item.reviewGroupId = groupId
                recordsById[photoId] = item
            }
        }

        progress(analysisProgress(phase: .organizing, completedCount: 0, totalCount: totalCount, overallProgress: 0.9))
        let finalRecords = pairs.compactMap { recordsById[$0.photoId] }
        try store.save(folderUrl: folderUrl, records: finalRecords, config: config)

        let summary = computeSummary(finalRecords)
        progress(analysisProgress(phase: .completed, completedCount: totalCount, totalCount: totalCount, overallProgress: 1.0))
        return summary
    }

    // MARK: - Load Records

    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        let config = try cfgLoader.load(for: folderUrl)
        return try store.load(for: folderUrl, expectedConfig: config)
    }

    // MARK: - Private Helpers

    private func runExifStage(
        pairs: [photoFilePair],
        totalCount: Int,
        progress: @escaping (analysisProgress) -> Void
    ) async -> [exifStageResult] {
        let concurrency = min(8, max(1, pairs.count))
        var nextIndex = 0
        var completed = 0
        var results: [exifStageResult] = []
        results.reserveCapacity(pairs.count)

        await withTaskGroup(of: exifStageResult.self) { group in
            func enqueueNext() {
                guard nextIndex < pairs.count else { return }
                let index = nextIndex
                let pair = pairs[index]
                nextIndex += 1
                group.addTask { [exif] in
                    let timeResult = exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)
                    let item = photoItem(
                        photoId: pair.photoId,
                        jpgPath: pair.jpgPath ?? pair.rawPath ?? "",
                        rawPath: pair.rawPath,
                        analysisSource: ""
                    )
                    let shootingTime = timeResult.found
                        ? duplicateGrouper.entry(photoId: pair.photoId, epochSeconds: timeResult.epochSeconds)
                        : nil
                    return exifStageResult(index: index, pair: pair, item: item, shootingTime: shootingTime)
                }
            }

            for _ in 0..<concurrency {
                enqueueNext()
            }

            while let result = await group.next() {
                results.append(result)
                completed += 1
                let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
                enqueueNext()
            }
        }

        return results.sorted { $0.index < $1.index }
    }

    private func runAnalysisStage(
        pairs: [photoFilePair],
        config: analysisConfig,
        totalCount: Int,
        progress: @escaping (analysisProgress) -> Void
    ) async -> [analysisStageResult] {
        let concurrency = min(max(config.metalConcurrency, 1), max(1, pairs.count))
        let jpgFallback = makeJpgFallbackRunner(config: config)
        var nextIndex = 0
        var completed = 0
        var results: [analysisStageResult] = []
        results.reserveCapacity(pairs.count)

        await withTaskGroup(of: analysisStageResult.self) { group in
            func enqueueNext() {
                guard nextIndex < pairs.count else { return }
                let index = nextIndex
                let pair = pairs[index]
                nextIndex += 1
                group.addTask { [rawAnalyzer, jpgAnalyzerService] in
                    let result: rawAnalysisResult
                    let phase: analysisPhase
                    if pair.hasRaw, let rawPath = pair.rawPath {
                        phase = .rawAnalysis
                        do {
                            result = try rawAnalyzer.analyze(rawPath: rawPath, config: config)
                        } catch {
                            result = jpgFallback(pair)
                        }
                    } else if pair.hasJpg, let jpgPath = pair.jpgPath {
                        phase = .jpgAnalysis
                        do {
                            result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                        } catch {
                            result = rawAnalysisResult(
                                isBlurry: false,
                                exposureStatus: "failed",
                                dynamicRange: nil,
                                blackLevel: 0,
                                whiteLevel: 0,
                                analysisSource: "jpg_failed"
                            )
                        }
                    } else {
                        phase = .jpgAnalysis
                        result = rawAnalysisResult(
                            isBlurry: false,
                            exposureStatus: "failed",
                            dynamicRange: nil,
                            blackLevel: 0,
                            whiteLevel: 0,
                            analysisSource: "none"
                        )
                    }
                    return analysisStageResult(index: index, photoId: pair.photoId, result: result, phase: phase)
                }
            }

            for _ in 0..<concurrency {
                enqueueNext()
            }

            while let result = await group.next() {
                results.append(result)
                completed += 1
                let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: result.phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))
                enqueueNext()
            }
        }

        return results.sorted { $0.index < $1.index }
    }

    private func makeJpgFallbackRunner(config: analysisConfig) -> @Sendable (photoFilePair) -> rawAnalysisResult {
        let jpgAnalyzerService = self.jpgAnalyzerService
        return { pair in
            guard pair.hasJpg, let jpgPath = pair.jpgPath else {
                return rawAnalysisResult(
                    isBlurry: false,
                    exposureStatus: "failed",
                    dynamicRange: nil,
                    blackLevel: 0,
                    whiteLevel: 0,
                    analysisSource: "jpg_failed"
                )
            }
            do {
                let result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                return rawAnalysisResult(
                    isBlurry: result.isBlurry,
                    exposureStatus: result.exposureStatus,
                    dynamicRange: result.dynamicRange,
                    blackLevel: result.blackLevel,
                    whiteLevel: result.whiteLevel,
                    analysisSource: "jpg_fallback"
                )
            } catch {
                return rawAnalysisResult(
                    isBlurry: false,
                    exposureStatus: "failed",
                    dynamicRange: nil,
                    blackLevel: 0,
                    whiteLevel: 0,
                    analysisSource: "jpg_failed"
                )
            }
        }
    }

    private func runJpgFallback(pair: photoFilePair, config: analysisConfig) -> rawAnalysisResult {
        guard pair.hasJpg, let jpgPath = pair.jpgPath else {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "failed",
                dynamicRange: nil,
                blackLevel: 0,
                whiteLevel: 0,
                analysisSource: "jpg_failed"
            )
        }
        do {
            let result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
            return rawAnalysisResult(
                isBlurry: result.isBlurry,
                exposureStatus: result.exposureStatus,
                dynamicRange: result.dynamicRange,
                blackLevel: result.blackLevel,
                whiteLevel: result.whiteLevel,
                analysisSource: "jpg_fallback"
            )
        } catch {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "failed",
                dynamicRange: nil,
                blackLevel: 0,
                whiteLevel: 0,
                analysisSource: "jpg_failed"
            )
        }
    }

    private func computeSummary(_ records: [photoItem]) -> analysisSummary {
        var blurry = 0, overexposed = 0, underexposed = 0, normal = 0
        for item in records {
            if item.isBlurry { blurry += 1 }
            if item.exposureStatus == "overexposed" { overexposed += 1 }
            else if item.exposureStatus == "underexposed" { underexposed += 1 }
            if item.isNormalAnalysisResult { normal += 1 }
        }
        return analysisSummary(
            totalPhotos: records.count,
            blurryCount: blurry,
            overexposedCount: overexposed,
            underexposedCount: underexposed,
            normalCount: normal
        )
    }

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
}
