/*
Author: wilbur
Version: 1.8
Date: 2026-06-11
Description: 新增照片展示旋转角度持久化，并保持旧 analysis.json 解码兼容；补充 reviewStatus 解码同名遮蔽说明
*/

import Foundation

public enum displaySource: String, Codable, Equatable {
    case jpg
    case raw
}

public enum photoRotationDirection: Equatable {
    case left
    case right

    public var deltaDegrees: Int {
        switch self {
        case .left: return 270
        case .right: return 90
        }
    }
}

public func normalizedRotationDegrees(_ value: Int) -> Int {
    let normalized = value % 360
    let positive = normalized < 0 ? normalized + 360 : normalized
    switch positive {
    case 90, 180, 270:
        return positive
    default:
        return 0
    }
}

public func rotatedDegrees(_ current: Int, direction: photoRotationDirection) -> Int {
    normalizedRotationDegrees(current + direction.deltaDegrees)
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
    public var rotationDegrees: Int

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
        dynamicRange: dynamicRangeData? = nil,
        rotationDegrees: Int = 0
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
        self.rotationDegrees = normalizedRotationDegrees(rotationDegrees)
    }

    // reviewStatus 属性与 reviewStatus 类型同名，解码时使用 typealias 避免 Swift 名称遮蔽。
    private typealias itemReviewStatus = reviewStatus

    private enum codingKeys: String, CodingKey {
        case photoId
        case jpgPath
        case rawPath
        case isBlurry
        case exposureStatus
        case reviewStatus
        case reviewGroupId
        case templatePhotoId
        case analysisSource
        case dynamicRange
        case rotationDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: codingKeys.self)
        self.photoId = try container.decode(String.self, forKey: .photoId)
        self.jpgPath = try container.decode(String.self, forKey: .jpgPath)
        self.rawPath = try container.decodeIfPresent(String.self, forKey: .rawPath)
        self.isBlurry = try container.decode(Bool.self, forKey: .isBlurry)
        self.exposureStatus = try container.decode(String.self, forKey: .exposureStatus)
        self.reviewStatus = try container.decode(itemReviewStatus.self, forKey: .reviewStatus)
        self.reviewGroupId = try container.decode(String.self, forKey: .reviewGroupId)
        self.templatePhotoId = try container.decode(String.self, forKey: .templatePhotoId)
        self.analysisSource = try container.decode(String.self, forKey: .analysisSource)
        self.dynamicRange = try container.decodeIfPresent(dynamicRangeData.self, forKey: .dynamicRange)
        self.rotationDegrees = normalizedRotationDegrees(try container.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: codingKeys.self)
        try container.encode(photoId, forKey: .photoId)
        try container.encode(jpgPath, forKey: .jpgPath)
        try container.encodeIfPresent(rawPath, forKey: .rawPath)
        try container.encode(isBlurry, forKey: .isBlurry)
        try container.encode(exposureStatus, forKey: .exposureStatus)
        try container.encode(reviewStatus, forKey: .reviewStatus)
        try container.encode(reviewGroupId, forKey: .reviewGroupId)
        try container.encode(templatePhotoId, forKey: .templatePhotoId)
        try container.encode(analysisSource, forKey: .analysisSource)
        try container.encodeIfPresent(dynamicRange, forKey: .dynamicRange)
        try container.encode(normalizedRotationDegrees(rotationDegrees), forKey: .rotationDegrees)
    }
}

public extension photoItem {
    func hasExistingJpgFile(fileManager: FileManager = .default) -> Bool {
        let ext = URL(fileURLWithPath: jpgPath).pathExtension.lowercased()
        guard ["jpg", "jpeg"].contains(ext) else { return false }
        return fileManager.fileExists(atPath: jpgPath)
    }

    func hasExistingRawFile(fileManager: FileManager = .default) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        let ext = URL(fileURLWithPath: rawPath).pathExtension.lowercased()
        guard ["rw2", "cr2"].contains(ext) else { return false }
        return fileManager.fileExists(atPath: rawPath)
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
