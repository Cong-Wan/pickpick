/*
Author: wilbur
Version: 1.4
Date: 2026-06-11
Description: 修复 makeVisiblePhotoGroups 中单张 orphan 重复分组的问题，并让 photoItem 支持 Codable 以简化 analysisStore 持久化 schema
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
    case exifReading
    case rawAnalysis
    case jpgAnalysis
    case duplicateGrouping
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

public struct dynamicRangeData: Codable, Equatable {
    public var sceneSpreadEv: Double
    public var codeRangeEv: Double
    public var blackLevel: Int
    public var whiteLevel: Int

    public init(sceneSpreadEv: Double, codeRangeEv: Double, blackLevel: Int, whiteLevel: Int) {
        self.sceneSpreadEv = sceneSpreadEv
        self.codeRangeEv = codeRangeEv
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
    }
}

public struct photoItem: Codable, Equatable, Identifiable {
    public var id: String { photoId }
    public var photoId: String
    public var jpgPath: String
    public var rawPath: String?
    public var isBlurry: Bool
    public var exposureStatus: String
    public var reviewStatus: reviewStatus
    public var reviewGroupId: String
    public var templatePhotoId: String
    public var analysisSource: String
    public var dynamicRange: dynamicRangeData?

    public init(
        photoId: String,
        jpgPath: String,
        rawPath: String? = nil,
        isBlurry: Bool = false,
        exposureStatus: String = "normal",
        reviewStatus: reviewStatus = .active,
        reviewGroupId: String = "",
        templatePhotoId: String = "",
        analysisSource: String = "",
        dynamicRange: dynamicRangeData? = nil
    ) {
        self.photoId = photoId
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.reviewStatus = reviewStatus
        self.reviewGroupId = reviewGroupId
        self.templatePhotoId = templatePhotoId
        self.analysisSource = analysisSource
        self.dynamicRange = dynamicRange
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

public enum groupRoute: Equatable {
    case browser
    case duplicateCompare
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

    let groupCounts = Dictionary(grouping: visiblePhotos, by: \.reviewGroupId)
        .filter { !$0.key.isEmpty }
        .mapValues { $0.count }
    let validDuplicateIds = Set(groupCounts.filter { $0.value >= 2 }.keys)

    func isInValidDuplicateGroup(_ photo: photoItem) -> Bool {
        !photo.reviewGroupId.isEmpty && validDuplicateIds.contains(photo.reviewGroupId)
    }

    appendGroup(.overexposed, photos: visiblePhotos.filter { $0.exposureStatus == "overexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter { $0.exposureStatus == "underexposed" && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter { $0.isBlurry && !isInValidDuplicateGroup($0) }, into: &groups)
    appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && !isInValidDuplicateGroup($0) }, into: &groups)

    for reviewGroupId in validDuplicateIds.sorted() {
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
