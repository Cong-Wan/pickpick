/*
Author: wilbur
Version: 1.3
Date: 2026-06-06
Description: 提供 Swift 侧 review 状态更新接口，新增 clearReviewGroupId 方法用于 Duplicate 完成后清空 reviewGroupId
*/

import Foundation

public enum reviewOperation: Equatable {
    case status(photoId: String, status: reviewStatus)
    case template(reviewGroupId: String, templatePhotoId: String)
}

public protocol jsonReviewStateStoring: AnyObject {
    func mark(photoId: String, status: reviewStatus) throws
    func setTemplate(reviewGroupId: String, templatePhotoId: String) throws
    func clearReviewGroupId(photoId: String) throws
}

public final class jsonReviewStateStore: jsonReviewStateStoring {
    public private(set) var operations: [reviewOperation] = []
    private let folderUrl: URL?

    public init(folderUrl: URL? = nil) {
        self.folderUrl = folderUrl
    }

    public func mark(photoId: String, status: reviewStatus) throws {
        try updateJson { photos in
            guard var photo = photos[photoId] as? [String: Any] else { return }
            photo["review_status"] = status.rawValue
            photo["trashed_at"] = status == .trashed ? isoNow() : ""
            photos[photoId] = photo
        }
        operations.append(.status(photoId: photoId, status: status))
    }

    public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
        try updateJson { photos in
            for key in photos.keys {
                guard var photo = photos[key] as? [String: Any], photo["review_group_id"] as? String == reviewGroupId else { continue }
                photo["template_photo_id"] = templatePhotoId
                photos[key] = photo
            }
        }
        operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
    }

    public func clearReviewGroupId(photoId: String) throws {
        try updateJson { photos in
            guard var photo = photos[photoId] as? [String: Any] else { return }
            photo["review_group_id"] = ""
            photos[photoId] = photo
        }
    }

    private func updateJson(_ mutate: (inout [String: Any]) -> Void) throws {
        guard let folderUrl else { return }
        let jsonUrl = folderUrl.appendingPathComponent(".cache/analysis.json")
        guard FileManager.default.fileExists(atPath: jsonUrl.path) else { return }
        let data = try Data(contentsOf: jsonUrl)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any], var photos = root["photos"] as? [String: Any] else { return }
        mutate(&photos)
        root["photos"] = photos
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: jsonUrl, options: .atomic)
    }
}

private let isoFormatter = ISO8601DateFormatter()

private func isoNow() -> String {
    isoFormatter.string(from: Date())
}
