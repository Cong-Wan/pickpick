/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 定义照片、分组、进度和显示源模型，并提供可见分组与偏好持久化辅助逻辑
*/

import Foundation

public enum displaySource: String, Codable, Equatable {
    case jpg
    case raw
}

public enum reviewStatus: String, Codable, Equatable {
    case active
    case kept
    case passed
    case trashed
}

public enum analysisPhase: String, Codable, Equatable {
    case scanning
    case rawConversion
    case analysis
    case organizing
    case completed
}

public struct analysisProgress: Equatable {
    public var phase: analysisPhase
    public var completedCount: Int
    public var totalCount: Int
    public var overallProgress: Double

    public init(phase: analysisPhase, completedCount: Int, totalCount: Int, overallProgress: Double) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.overallProgress = overallProgress
    }
}

public struct photoItem: Equatable, Identifiable {
    public var id: String { photoId }
    public var photoId: String
    public var jpgPath: String
    public var rawPath: String?
    public var isBlurry: Bool
    public var exposureStatus: String
    public var reviewStatus: reviewStatus
    public var reviewGroupId: String
    public var templatePhotoId: String

    public init(
        photoId: String,
        jpgPath: String,
        rawPath: String? = nil,
        isBlurry: Bool = false,
        exposureStatus: String = "normal",
        reviewStatus: reviewStatus = .active,
        reviewGroupId: String = "",
        templatePhotoId: String = ""
    ) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.reviewStatus = reviewStatus
        self.reviewGroupId = reviewGroupId
        self.templatePhotoId = templatePhotoId
    }
}

public enum photoGroupKind: Equatable {
    case overexposed
    case underexposed
    case blurry
    case normal
    case duplicate(reviewGroupId: String)

    public var title: String {
        switch self {
        case .overexposed: return "Overexposed"
        case .underexposed: return "Underexposed"
        case .blurry: return "Blurry"
        case .normal: return "Normal"
        case .duplicate(let reviewGroupId): return "Duplicate \(reviewGroupId)"
        }
    }

    public var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}

public struct photoGroup: Equatable, Identifiable {
    public var id: String {
        switch kind {
        case .overexposed: return "overexposed"
        case .underexposed: return "underexposed"
        case .blurry: return "blurry"
        case .normal: return "normal"
        case .duplicate(let reviewGroupId): return "duplicate-\(reviewGroupId)"
        }
    }

    public var kind: photoGroupKind
    public var photos: [photoItem]

    public init(kind: photoGroupKind, photos: [photoItem]) {
        self.kind = kind
        self.photos = photos
    }
}

public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter(\.isBlurry), into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" }, into: &groups)

    let duplicateGroupIds = Array(Set(visiblePhotos.map(\.reviewGroupId).filter { !$0.isEmpty })).sorted()
    for reviewGroupId in duplicateGroupIds {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}

private func appendGroup(_ kind: photoGroupKind, photos: [photoItem], into groups: inout [photoGroup]) {
    guard !photos.isEmpty else { return }
    groups.append(photoGroup(kind: kind, photos: photos))
}

public final class displaySourceStore {
    private let defaults: UserDefaults
    private let key = "rawViewer.displaySource"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var current: displaySource {
        get {
            guard let value = defaults.string(forKey: key), let source = displaySource(rawValue: value) else {
                return .jpg
            }
            return source
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}

public enum displayAvailability: Equatable {
    case available(URL)
    case unavailable
}

public func displayUrl(for photo: photoItem, source: displaySource) -> displayAvailability {
    switch source {
    case .jpg:
        return .available(URL(fileURLWithPath: photo.jpgPath))
    case .raw:
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else { return .unavailable }
        return .available(URL(fileURLWithPath: rawPath))
    }
}
