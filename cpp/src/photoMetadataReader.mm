/*
 * Author: wilbur
 * Version: 1.2
 * Date: 2026-06-02
 * Description: 优先使用 ImageIO 读取文件内 EXIF/TIFF 拍摄时间，失败后用 macOS Metadata API 兜底，并输出 UTC ISO8601 时间供 JSON 分组使用
 */

#include "photoMetadataReader.h"
#include <Foundation/Foundation.h>
#include <ImageIO/ImageIO.h>
#include <CoreServices/CoreServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cmath>
#include <ctime>

namespace {

shootingTimeResult notFoundResult() {
    shootingTimeResult result;
    result.found = false;
    result.epochSeconds = 0;
    result.isoUtc.clear();
    result.source = "none";
    return result;
}

std::string isoUtcFromEpoch(int64_t epochSeconds) {
    std::time_t timeValue = static_cast<std::time_t>(epochSeconds);
    std::tm tmUtc = {};
    gmtime_r(&timeValue, &tmUtc);
    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);
    return buffer;
}

bool parseExifDate(NSString* value, int64_t& epochSeconds) {
    if (value == nil) {
        return false;
    }

    std::tm localTime = {};
    const char* text = [value UTF8String];
    if (text == nullptr) {
        return false;
    }

    char* parsedEnd = strptime(text, "%Y:%m:%d %H:%M:%S", &localTime);
    if (parsedEnd == nullptr || *parsedEnd != '\0') {
        return false;
    }

    localTime.tm_isdst = -1;
    std::time_t parsed = std::mktime(&localTime);
    if (parsed == static_cast<std::time_t>(-1)) {
        return false;
    }

    epochSeconds = static_cast<int64_t>(parsed);
    return true;
}

NSString* stringValueFromDictionary(NSDictionary* dictionary, CFStringRef key) {
    id value = dictionary[(__bridge NSString*)key];
    if ([value isKindOfClass:[NSString class]]) {
        return static_cast<NSString*>(value);
    }
    return nil;
}

shootingTimeResult readImageIoShootingTime(const std::string& filePath, const std::string& source) {
    @autoreleasepool {
        NSString* path = [NSString stringWithUTF8String:filePath.c_str()];
        if (path == nil) {
            return notFoundResult();
        }

        NSURL* url = [NSURL fileURLWithPath:path];
        CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
        if (imageSource == nullptr) {
            return notFoundResult();
        }

        CFDictionaryRef propertiesRef = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nullptr);
        CFRelease(imageSource);
        if (propertiesRef == nullptr) {
            return notFoundResult();
        }

        NSDictionary* properties = (__bridge_transfer NSDictionary*)propertiesRef;
        NSDictionary* exif = properties[(__bridge NSString*)kCGImagePropertyExifDictionary];
        NSDictionary* tiff = properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary];

        int64_t epochSeconds = 0;
        if (parseExifDate(stringValueFromDictionary(exif, kCGImagePropertyExifDateTimeOriginal), epochSeconds) ||
            parseExifDate(stringValueFromDictionary(exif, kCGImagePropertyExifDateTimeDigitized), epochSeconds) ||
            parseExifDate(stringValueFromDictionary(tiff, kCGImagePropertyTIFFDateTime), epochSeconds)) {
            shootingTimeResult result;
            result.found = true;
            result.epochSeconds = epochSeconds;
            result.isoUtc = isoUtcFromEpoch(epochSeconds);
            result.source = source;
            return result;
        }
    }

    return notFoundResult();
}

shootingTimeResult readMdItemShootingTime(const std::string& filePath, const std::string& source) {
    CFStringRef cfPath = CFStringCreateWithCString(kCFAllocatorDefault, filePath.c_str(), kCFStringEncodingUTF8);
    if (cfPath == nullptr) {
        return notFoundResult();
    }

    MDItemRef item = MDItemCreate(kCFAllocatorDefault, cfPath);
    CFRelease(cfPath);
    if (item == nullptr) {
        return notFoundResult();
    }

    CFTypeRef value = MDItemCopyAttribute(item, kMDItemContentCreationDate);
    CFRelease(item);
    if (value == nullptr) {
        return notFoundResult();
    }

    shootingTimeResult result = notFoundResult();
    if (CFGetTypeID(value) == CFDateGetTypeID()) {
        CFAbsoluteTime absoluteTime = CFDateGetAbsoluteTime(static_cast<CFDateRef>(value));
        auto epochSeconds = static_cast<int64_t>(std::llround(absoluteTime + kCFAbsoluteTimeIntervalSince1970));
        result.found = true;
        result.epochSeconds = epochSeconds;
        result.isoUtc = isoUtcFromEpoch(epochSeconds);
        result.source = source;
    }

    CFRelease(value);
    return result;
}

}  // namespace

shootingTimeResult photoMetadataReader::readBestShootingTime(const std::string& rawPath, const std::string& jpgPath) const {
    if (!rawPath.empty()) {
        shootingTimeResult rawResult = readFileShootingTime(rawPath, "raw");
        if (rawResult.found) {
            return rawResult;
        }
    }

    if (!jpgPath.empty()) {
        shootingTimeResult jpgResult = readFileShootingTime(jpgPath, "jpg");
        if (jpgResult.found) {
            return jpgResult;
        }
    }

    return notFoundResult();
}

shootingTimeResult photoMetadataReader::readFileShootingTime(const std::string& filePath, const std::string& source) const {
    if (filePath.empty()) {
        return notFoundResult();
    }

    shootingTimeResult imageIoResult = readImageIoShootingTime(filePath, source);
    if (imageIoResult.found) {
        return imageIoResult;
    }

    return readMdItemShootingTime(filePath, source);
}
