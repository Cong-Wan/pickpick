/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: 主编排, 替代原 photoAnalyzerBridge。v1.1 去除不必要的 pickpick 模块名前缀并避免 jpgAnalyzer 命名遮蔽
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

    // MARK: - Analyze

    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = try cfgLoader.load(for: folderUrl)

        // 1. Scanning phase
        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))
        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalCount = pairs.count
        guard totalCount > 0 else {
            progress(analysisProgress(phase: .completed, completedCount: 0, totalCount: 0, overallProgress: 1.0))
            return analysisSummary(totalPhotos: 0, blurryCount: 0, overexposedCount: 0, underexposedCount: 0, normalCount: 0)
        }

        // 2. EXIF reading phase
        progress(analysisProgress(phase: .exifReading, completedCount: 0, totalCount: totalCount, overallProgress: 0.1))
        let recordsLock = NSLock()
        var records: [String: photoItem] = [:]
        var shootingTimes: [duplicateGrouper.entry] = []
        var exifCompletedCount = 0

        let exifQueue = DispatchQueue(label: "rawViewer.exifReader", attributes: .concurrent)
        let exifGroup = DispatchGroup()
        let exifSemaphore = DispatchSemaphore(value: 8)

        for (index, pair) in pairs.enumerated() {
            exifGroup.enter()
            exifQueue.async {
                exifSemaphore.wait()
                defer {
                    exifSemaphore.signal()
                    exifGroup.leave()
                }

                let timeResult = self.exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)

                let item = photoItem(
                    photoId: pair.photoId,
                    jpgPath: pair.jpgPath ?? pair.rawPath ?? "",
                    rawPath: pair.rawPath,
                    analysisSource: ""
                )

                recordsLock.lock()
                records[pair.photoId] = item
                if timeResult.found {
                    shootingTimes.append(duplicateGrouper.entry(photoId: pair.photoId, epochSeconds: timeResult.epochSeconds))
                }
                recordsLock.unlock()

                recordsLock.lock()
                exifCompletedCount += 1
                let completed = exifCompletedCount
                recordsLock.unlock()
                let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
            }
        }
        exifGroup.wait()

        // 3. Analysis phase (raw / jpg)
        progress(analysisProgress(phase: .rawAnalysis, completedCount: 0, totalCount: totalCount, overallProgress: 0.2))
        let gpuSemaphore = DispatchSemaphore(value: config.metalConcurrency)
        var analysisCompletedCount = 0
        let analysisQueue = DispatchQueue(label: "rawViewer.analysis", attributes: .concurrent)
        let analysisGroup = DispatchGroup()

        for (index, pair) in pairs.enumerated() {
            analysisGroup.enter()
            analysisQueue.async {
                gpuSemaphore.wait()
                defer {
                    gpuSemaphore.signal()
                    analysisGroup.leave()
                }

                let result: rawAnalysisResult
                if pair.hasRaw, let rawPath = pair.rawPath {
                    do {
                        result = try self.rawAnalyzer.analyze(rawPath: rawPath, config: config)
                    } catch {
                        result = self.runJpgFallback(pair: pair, config: config)
                    }
                } else if pair.hasJpg, let jpgPath = pair.jpgPath {
                    do {
                        result = try self.jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                    } catch {
                        result = rawAnalysisResult(
                            isBlurry: false,
                            exposureStatus: "normal",
                            dynamicRange: nil,
                            blackLevel: 0,
                            whiteLevel: 0,
                            analysisSource: "jpg_failed"
                        )
                    }
                } else {
                    result = rawAnalysisResult(
                        isBlurry: false,
                        exposureStatus: "normal",
                        dynamicRange: nil,
                        blackLevel: 0,
                        whiteLevel: 0,
                        analysisSource: "none"
                    )
                }

                recordsLock.lock()
                if var item = records[pair.photoId] {
                    item.isBlurry = result.isBlurry
                    item.exposureStatus = result.exposureStatus
                    item.dynamicRange = result.dynamicRange
                    item.analysisSource = result.analysisSource
                    records[pair.photoId] = item
                }
                recordsLock.unlock()

                recordsLock.lock()
                analysisCompletedCount += 1
                let completed = analysisCompletedCount
                recordsLock.unlock()
                let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
                let phase: analysisPhase = pair.hasRaw ? .rawAnalysis : .jpgAnalysis
                progress(analysisProgress(phase: phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))
            }
        }
        analysisGroup.wait()

        // 4. Duplicate grouping phase
        progress(analysisProgress(phase: .duplicateGrouping, completedCount: 0, totalCount: totalCount, overallProgress: 0.85))
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, groupId) in groupMap {
            if var item = records[photoId] {
                item.reviewGroupId = groupId
                records[photoId] = item
            }
        }

        // 5. Organizing / save phase
        progress(analysisProgress(phase: .organizing, completedCount: 0, totalCount: totalCount, overallProgress: 0.9))
        let finalRecords = pairs.compactMap { records[$0.photoId] }
        try store.save(folderUrl: folderUrl, records: finalRecords, config: config)

        // 6. Compute summary
        let summary = computeSummary(finalRecords)
        progress(analysisProgress(phase: .completed, completedCount: totalCount, totalCount: totalCount, overallProgress: 1.0))
        return summary
    }

    // MARK: - Load Records

    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        try store.load(for: folderUrl)
    }

    // MARK: - Private Helpers

    private func runJpgFallback(pair: photoFilePair, config: analysisConfig) -> rawAnalysisResult {
        guard pair.hasJpg, let jpgPath = pair.jpgPath else {
            return rawAnalysisResult(
                isBlurry: false,
                exposureStatus: "normal",
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
                exposureStatus: "normal",
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
            if !item.isBlurry && item.exposureStatus == "normal" { normal += 1 }
        }
        return analysisSummary(
            totalPhotos: records.count,
            blurryCount: blurry,
            overexposedCount: overexposed,
            underexposedCount: underexposed,
            normalCount: normal
        )
    }
}
