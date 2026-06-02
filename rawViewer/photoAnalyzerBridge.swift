/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 提供 Swift async 照片分析 facade，将 Objective-C++ 桥模型转换为 Swift 模型
*/

import Foundation

public final class photoAnalyzerBridge {
    private let bridge: rwPhotoAnalyzerBridge

    public init(bridge: rwPhotoAnalyzerBridge = rwPhotoAnalyzerBridge()) {
        self.bridge = bridge
    }

    public func startAnalysis(
        folderUrl: URL,
        configUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> rwAnalysisResult {
        try await withCheckedThrowingContinuation { continuation in
            bridge.startAnalysis(atFolderPath: folderUrl.path, configPath: configUrl.path) { bridgeProgress in
                progress(analysisProgress(
                    phase: analysisPhase(bridgePhase: bridgeProgress.phase),
                    completedCount: bridgeProgress.completedCount,
                    totalCount: bridgeProgress.totalCount,
                    overallProgress: bridgeProgress.overallProgress
                ))
            } completion: { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: NSError(domain: "rawViewer.photoAnalyzer", code: 1))
                }
            }
        }
    }

    public func loadAnalysisResult(folderUrl: URL) throws -> [photoItem] {
        let records = try bridge.loadAnalysisResult(atFolderPath: folderUrl.path)
        return records.map { record in
            photoItem(
                photoId: record.photoId,
                jpgPath: record.jpgPath,
                rawPath: record.rawPath.isEmpty ? nil : record.rawPath,
                isBlurry: record.isBlurry,
                exposureStatus: record.exposureStatus,
                reviewStatus: reviewStatus(rawValue: record.reviewStatus) ?? .active,
                reviewGroupId: record.reviewGroupId,
                templatePhotoId: record.templatePhotoId
            )
        }
    }
}

extension analysisPhase {
    init(bridgePhase: Int) {
        switch bridgePhase {
        case 0: self = .scanning
        case 1: self = .rawConversion
        case 2: self = .analysis
        case 3: self = .organizing
        case 4: self = .completed
        default: self = .scanning
        }
    }
}
