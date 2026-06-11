/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: 使用 ImageIO 读取 EXIF DateTimeOriginal, 失败回退到 Spotlight kMDItemContentCreationDate
*/

import Foundation
import ImageIO
import CoreServices
import CoreFoundation

public struct shootingTimeResult: Equatable {
    public let found: Bool
    public let epochSeconds: Int64
    public let isoUtc: String?
    public let source: String

    public init(found: Bool, epochSeconds: Int64, isoUtc: String?, source: String) {
        self.found = found
        self.epochSeconds = epochSeconds
        self.isoUtc = isoUtc
        self.source = source
    }

    public static let notFound = shootingTimeResult(found: false, epochSeconds: 0, isoUtc: nil, source: "none")
}

public final class exifReader {

    public init() {}

    public func readBestShootingTime(rawPath: String?, jpgPath: String?) -> shootingTimeResult {
        if let raw = rawPath, !raw.isEmpty {
            let r = readFileShootingTime(raw, source: "raw")
            if r.found { return r }
        }
        if let jpg = jpgPath, !jpg.isEmpty {
            let r = readFileShootingTime(jpg, source: "jpg")
            if r.found { return r }
        }
        return .notFound
    }

    public func readFileShootingTime(_ filePath: String, source: String) -> shootingTimeResult {
        if let result = readImageIoShootingTime(filePath, source: source), result.found {
            return result
        }
        return readSpotlightShootingTime(filePath, source: source)
    }

    private func readImageIoShootingTime(_ filePath: String, source: String) -> shootingTimeResult? {
        guard let imgSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil) else {
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        ]
        for value in candidates {
            guard let value else { continue }
            if let seconds = parseExifDate(value) {
                return shootingTimeResult(found: true, epochSeconds: seconds, isoUtc: isoUtcFromEpoch(seconds), source: source)
            }
        }
        return nil
    }

    private func readSpotlightShootingTime(_ filePath: String, source: String) -> shootingTimeResult {
        let cfPath = filePath as CFString
        guard let item = MDItemCreate(kCFAllocatorDefault, cfPath) else {
            return .notFound
        }
        guard let value = MDItemCopyAttribute(item, kMDItemContentCreationDate) else {
            return .notFound
        }
        guard CFGetTypeID(value) == CFDateGetTypeID() else {
            return .notFound
        }
        let absolute = CFDateGetAbsoluteTime(value as! CFDate)
        let seconds = Int64((absolute + kCFAbsoluteTimeIntervalSince1970).rounded())
        return shootingTimeResult(found: true, epochSeconds: seconds, isoUtc: isoUtcFromEpoch(seconds), source: source)
    }

    private func parseExifDate(_ value: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: value) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded())
    }

    private func isoUtcFromEpoch(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
