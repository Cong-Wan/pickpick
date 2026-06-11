/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 通用本地文件日志服务，按天写入 Application Support/rawViewer/logs，并保留最近 7 天日志
*/

import Foundation

public enum appLogLevel: String {
    case info
    case warning
    case error
}

public enum appFileLogger {
    private static let queue = DispatchQueue(label: "rawViewer.appFileLogger")
    private static let fileManager = FileManager.default
    private static let retentionDays = 7
    private static var cleanupCompleted = false

    public static func log(_ message: String, level: appLogLevel = .info) {
        queue.async {
            write(message, level: level)
        }
    }

    private static func write(_ message: String, level: appLogLevel) {
        do {
            let directory = try logsDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !cleanupCompleted {
                cleanupOldLogs(in: directory)
                cleanupCompleted = true
            }

            let now = Date()
            let url = directory.appendingPathComponent(fileName(for: now))
            let line = "\(timestamp(for: now)) [\(level.rawValue)] \(message)\n"
            try append(line, to: url)
        } catch {
            appDebugLogger.log("appFileLogger failed: \(error.localizedDescription)")
        }
    }

    private static func logsDirectory() throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("rawViewer", isDirectory: true)
        .appendingPathComponent("logs", isDirectory: true)
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date)).log"
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func append(_ line: String, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func cleanupOldLogs(in directory: URL) {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            guard let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: todayStart) else {
                return
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"

            for url in urls where url.pathExtension == "log" {
                let baseName = url.deletingPathExtension().lastPathComponent
                guard let date = formatter.date(from: baseName), date < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        } catch {
            appDebugLogger.log("appFileLogger cleanup failed: \(error.localizedDescription)")
        }
    }
}
