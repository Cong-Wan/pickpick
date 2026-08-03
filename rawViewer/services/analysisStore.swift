/*
Author: wilbur
Version: 1.7
Date: 2026-08-03
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json；读取缓存时可校验 configSnapshot，配置变化时拒绝旧缓存以触发重新分析；v1.4 新增 loadAsync(for:expectedConfig:) 把磁盘解码放到后台 Task.detached，避免在 MainActor 上同步阻塞 ioQueue；v1.5 update 改为读取完整 analysisFile 后原样保留 configSnapshot 写回，缺失缓存文件显式抛 missingResults；v1.6 save 覆盖损坏缓存时不再依赖旧文件可解码；v1.7 彻底关闭曝光/虚焦检测：summary 仅保留 totalPhotos/normal，删除 blurry/overexposed/underexposed 计数
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
    var normal: Int = 0
}

public enum analysisStoreError: Error, LocalizedError, Equatable {
    case missingResults
    case staleConfigSnapshot

    public var errorDescription: String? {
        switch self {
        case .missingResults:
            return "analysis cache file does not exist"
        case .staleConfigSnapshot:
            return "analysis cache configSnapshot differs from current config"
        }
    }
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

    public func load(for folderUrl: URL, expectedConfig: analysisConfig) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl, expectedConfig: expectedConfig)
        }
    }

    /// 异步读取：把磁盘解码放到后台，避免在 MainActor 上同步阻塞 ioQueue
    public func loadAsync(for folderUrl: URL, expectedConfig: analysisConfig? = nil) async throws -> [photoItem] {
        try await Task.detached(priority: .userInitiated) { [self] in
            if let expectedConfig {
                return try self.load(for: folderUrl, expectedConfig: expectedConfig)
            }
            return try self.load(for: folderUrl)
        }.value
    }

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        try ioQueue.sync {
            try saveUnlocked(folderUrl: folderUrl, records: records, config: config)
        }
    }

    public func update(folderUrl: URL, mutate: (inout [photoItem]) throws -> Void) throws {
        try ioQueue.sync {
            var root = try loadFileUnlocked(for: folderUrl)
            try mutate(&root.photos)
            try saveFileUnlocked(folderUrl: folderUrl, root: root)
        }
    }

    private func loadUnlocked(for folderUrl: URL, expectedConfig: analysisConfig? = nil) throws -> [photoItem] {
        let root = try loadFileUnlocked(for: folderUrl)
        if let expectedConfig, root.configSnapshot != expectedConfig {
            throw analysisStoreError.staleConfigSnapshot
        }
        return root.photos
    }

    private func loadFileUnlocked(for folderUrl: URL) throws -> analysisFile {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else {
            throw analysisStoreError.missingResults
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(analysisFile.self, from: data)
    }

    private func saveFileUnlocked(folderUrl: URL, root: analysisFile) throws {
        let dir = resultsUrl(for: folderUrl).deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var nextRoot = root
        nextRoot.schemaVersion = "2.0"
        nextRoot.folderPath = folderUrl.path
        nextRoot.updatedAt = isoNow()
        if nextRoot.createdAt.isEmpty { nextRoot.createdAt = nextRoot.updatedAt }
        nextRoot.summary = summaryCounts(nextRoot.photos)

        let data = try JSONEncoder().encode(nextRoot)
        try data.write(to: resultsUrl(for: folderUrl), options: .atomic)
    }

    private func saveUnlocked(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        var existing = analysisFile()
        let url = resultsUrl(for: folderUrl)
        if fileManager.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(analysisFile.self, from: data) {
            existing = decoded
        }

        existing.photos = records
        if let config {
            existing.configSnapshot = config
        }
        try saveFileUnlocked(folderUrl: folderUrl, root: existing)
    }

    private func summaryCounts(_ records: [photoItem]) -> summaryData {
        var s = summaryData()
        s.totalPhotos = records.count
        let duplicateIds = Dictionary(grouping: records, by: \.reviewGroupId)
            .filter { !$0.key.isEmpty }
            .mapValues { $0.count }
            .filter { $0.value >= 2 }
            .keys
        s.normal = records.filter { photo in
            photo.reviewGroupId.isEmpty || !duplicateIds.contains(photo.reviewGroupId)
        }.count
        return s
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
