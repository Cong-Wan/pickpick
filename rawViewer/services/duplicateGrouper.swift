/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 3 秒阈值重复分组, 同组 >= 2 张才分配 dup_NNN ID
*/

import Foundation

public final class duplicateGrouper {
    public static let thresholdSeconds: Int64 = 3

    public init() {}

    public struct entry {
        public let photoId: String
        public let epochSeconds: Int64
        public init(photoId: String, epochSeconds: Int64) {
            self.photoId = photoId
            self.epochSeconds = epochSeconds
        }
    }

    /// 输入拍摄时间列表, 返回 photoId → reviewGroupId 映射 (空字符串表示无分组)
    public func computeDuplicateGroupIds(_ entries: [entry]) -> [String: String] {
        let valid = entries.filter { $0.epochSeconds > 0 }
        let sorted = valid.sorted { a, b in
            if a.epochSeconds != b.epochSeconds { return a.epochSeconds < b.epochSeconds }
            return a.photoId < b.photoId
        }

        var result: [String: String] = [:]
        var index = 0
        var groupIndex = 1

        while index < sorted.count {
            let groupStart = index
            let groupStartEpoch = sorted[groupStart].epochSeconds
            index += 1
            while index < sorted.count
                && sorted[index].epochSeconds - groupStartEpoch <= Self.thresholdSeconds {
                index += 1
            }
            let size = index - groupStart
            if size < 2 { continue }
            let gid = String(format: "dup_%03d", groupIndex)
            for i in groupStart..<index {
                result[sorted[i].photoId] = gid
            }
            groupIndex += 1
        }
        return result
    }
}
