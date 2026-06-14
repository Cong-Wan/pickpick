/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json。v1.2 增加串行 load-mutate-save 更新入口，避免快速 review 操作互相覆盖
*/

import Foundation
import CryptoKit

nonisolated struct analysisFile: Codable, Sendable {
    var schemaVersion: String = "2.0"
    var folderPath: String = ""
    var createdAt: String = ""
    var updatedAt: String = ""
    var summary: summaryData = summaryData()
    var photos: [photoItem] = []
    var configSnapshot: analysisConfig?
}

nonisolated struct summaryData: Codable, Sendable {
    var totalPhotos: Int = 0
    var blurry: Int = 0
    var overexposed: Int = 0
    var underexposed: Int = 0
    var normal: Int = 0
}

nonisolated public final class analysisStore: @unchecked Sendable {
    public static let shared = analysisStore()

    private let fileManager: FileManager
    private let appSupportDir: URL
    private let ioQueue = DispatchQueue(label: "rawViewer.analysisStore.io")

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        do {
            self.appSupportDir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("rawViewer", isDirectory: true)
        } catch {
            self.appSupportDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rawViewer", isDirectory: true)
        }
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    public func folderHash(_ folderUrl: URL) -> String {
        let digest = SHA256.hash(data: Data(folderUrl.path.utf8))
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    public func resultsUrl(for folderUrl: URL) -> URL {
        appSupportDir
            .appendingPathComponent(folderHash(folderUrl), isDirectory: true)
            .appendingPathComponent("analysis.json")
    }

    public func hasResults(for folderUrl: URL) -> Bool {
        fileManager.fileExists(atPath: resultsUrl(for: folderUrl).path)
    }

    public func load(for folderUrl: URL) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl)
        }
    }

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        try ioQueue.sync {
            try saveUnlocked(folderUrl: folderUrl, records: records, config: config)
        }
    }

    public func update(folderUrl: URL, mutate: (inout [photoItem]) throws -> Void) throws {
        try ioQueue.sync {
            var records = try loadUnlocked(for: folderUrl)
            try mutate(&records)
            try saveUnlocked(folderUrl: folderUrl, records: records, config: nil)
        }
    }

    private func loadUnlocked(for folderUrl: URL) throws -> [photoItem] {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(analysisFile.self, from: data)
        return root.photos
    }

    private func saveUnlocked(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        let dir = resultsUrl(for: folderUrl).deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var existing = analysisFile()
        let url = resultsUrl(for: folderUrl)
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            existing = try JSONDecoder().decode(analysisFile.self, from: data)
        }

        existing.schemaVersion = "2.0"
        existing.folderPath = folderUrl.path
        existing.updatedAt = isoNow()
        if existing.createdAt.isEmpty { existing.createdAt = existing.updatedAt }
        if let config {
            existing.configSnapshot = config
        }
        existing.photos = records
        existing.summary = summaryCounts(records)

        let data = try JSONEncoder().encode(existing)
        try data.write(to: url, options: .atomic)
    }

    private func summaryCounts(_ records: [photoItem]) -> summaryData {
        var s = summaryData()
        s.totalPhotos = records.count
        s.blurry = records.filter { $0.isBlurry }.count
        s.overexposed = records.filter { $0.exposureStatus == "overexposed" }.count
        s.underexposed = records.filter { $0.exposureStatus == "underexposed" }.count
        s.normal = records.filter { $0.isNormalAnalysisResult }.count
        return s
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
