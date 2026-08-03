/*
Author: wilbur
Version: 1.9
Date: 2026-08-03
Description: 主编排, 替代原 photoAnalyzerBridge；加载缓存时校验当前分析配置，configSnapshot 不一致则让上层重新分析；v1.6 在 --debug 下写 calibration dump 供阈值校准；v1.7 新增 loadRecordsAsync(folderUrl:) 委托 store.loadAsync，避免主线程同步阻塞；v1.8 删除无调用方的 runJpgFallback 死方法；v1.9 彻底关闭曝光/虚焦检测：删除 rawBayerAnalyzer/jpgAnalyzer 像素分析依赖与 runAnalysisStage/makeJpgFallbackRunner/writeCalibrationDumpIfDebug/centerBrightness/analysisStageResult，分析流程简化为扫描->EXIF->duplicate 分组；不再使用 configLoader，直接用 analysisConfig.defaults；analysisSummary 仅保留 totalPhotos/normalCount
*/

import Foundation

// MARK: - Summary

public struct analysisSummary {
    public let totalPhotos: Int
    public let normalCount: Int

    public init(
        totalPhotos: Int,
        normalCount: Int
    ) {
        self.totalPhotos = totalPhotos
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

    func loadRecordsAsync(folderUrl: URL) async throws -> [photoItem]
}

// MARK: - Service

public final class photoAnalysisService: photoAnalyzing {

    private let scanner: fileScanner
    private let exif: exifReader
    private let grouper: duplicateGrouper
    private let store: analysisStore

    public init(
        scanner: fileScanner = fileScanner(),
        exif: exifReader = exifReader(),
        grouper: duplicateGrouper = duplicateGrouper(),
        store: analysisStore = .shared
    ) {
        self.scanner = scanner
        self.exif = exif
        self.grouper = grouper
        self.store = store
    }

    private struct exifStageResult {
        let index: Int
        let pair: photoFilePair
        let item: photoItem
        let shootingTime: duplicateGrouper.entry?
    }

    // MARK: - Analyze

    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = analysisConfig.defaults

        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))
        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalCount = pairs.count
        guard totalCount > 0 else {
            progress(analysisProgress(phase: .completed, completedCount: 0, totalCount: 0, overallProgress: 1.0))
            return analysisSummary(totalPhotos: 0, normalCount: 0)
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
        let config = analysisConfig.defaults
        return try store.load(for: folderUrl, expectedConfig: config)
    }

    public func loadRecordsAsync(folderUrl: URL) async throws -> [photoItem] {
        let config = analysisConfig.defaults
        return try await store.loadAsync(for: folderUrl, expectedConfig: config)
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
                        rawPath: pair.rawPath
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
                let overall = 0.1 + 0.7 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
                enqueueNext()
            }
        }

        return results.sorted { $0.index < $1.index }
    }

    private func computeSummary(_ records: [photoItem]) -> analysisSummary {
        let duplicateIds = Dictionary(grouping: records, by: \.reviewGroupId)
            .filter { !$0.key.isEmpty }
            .mapValues { $0.count }
            .filter { $0.value >= 2 }
            .keys
        let normal = records.filter { photo in
            photo.reviewGroupId.isEmpty || !duplicateIds.contains(photo.reviewGroupId)
        }.count
        return analysisSummary(totalPhotos: records.count, normalCount: normal)
    }
}
