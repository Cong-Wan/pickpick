/*
 * Author: wilbur
 * Version: 1.2
 * Date: 2026-06-02
 * Description: 使用 ImageIO CGImageDestination 一次性写出 JPG，并注入基础 TIFF/EXIF 元信息；避免覆盖失败时删除既有 JPG，使用线程安全时间格式化，并同步文件系统创建/修改时间
 */

#include "jpgWriter.h"
#include <Foundation/Foundation.h>
#include <ImageIO/ImageIO.h>
#include <CoreServices/CoreServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cmath>
#include <ctime>
#include <filesystem>
#include <sstream>
#include <vector>

namespace {

NSString* stringFromStd(const std::string& value) {
    if (value.empty()) {
        return nil;
    }
    return [NSString stringWithUTF8String:value.c_str()];
}

NSString* exifDateFromTimestamp(int64_t timestamp) {
    if (timestamp <= 0) {
        return nil;
    }
    std::time_t timeValue = static_cast<std::time_t>(timestamp);
    std::tm localTime = {};
    localtime_r(&timeValue, &localTime);
    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y:%m:%d %H:%M:%S", &localTime);
    return [NSString stringWithUTF8String:buffer];
}

void setString(NSMutableDictionary* dictionary, CFStringRef key, const std::string& value) {
    NSString* stringValue = stringFromStd(value);
    if (stringValue != nil) {
        dictionary[(__bridge NSString*)key] = stringValue;
    }
}

void setDouble(NSMutableDictionary* dictionary, CFStringRef key, double value) {
    if (value > 0.0 && std::isfinite(value)) {
        dictionary[(__bridge NSString*)key] = @(value);
    }
}

void setInt(NSMutableDictionary* dictionary, CFStringRef key, int value) {
    if (value > 0) {
        dictionary[(__bridge NSString*)key] = @(value);
    }
}

CGImageRef makeRgbImage(int width, int height, const unsigned char* data, std::vector<unsigned char>& rgbaBuffer, std::string& error) {
    size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    rgbaBuffer.resize(pixelCount * 4);
    for (size_t i = 0; i < pixelCount; ++i) {
        rgbaBuffer[i * 4 + 0] = data[i * 3 + 0];
        rgbaBuffer[i * 4 + 1] = data[i * 3 + 1];
        rgbaBuffer[i * 4 + 2] = data[i * 3 + 2];
        rgbaBuffer[i * 4 + 3] = 255;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace == nullptr) {
        error = "failed to create sRGB color space";
        return nullptr;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, rgbaBuffer.data(), rgbaBuffer.size(), nullptr);
    if (provider == nullptr) {
        CGColorSpaceRelease(colorSpace);
        error = "failed to create RGB data provider";
        return nullptr;
    }

    CGImageRef image = CGImageCreate(width,
                                     height,
                                     8,
                                     32,
                                     static_cast<size_t>(width) * 4,
                                     colorSpace,
                                     kCGImageAlphaLast | kCGBitmapByteOrder32Big,
                                     provider,
                                     nullptr,
                                     false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (image == nullptr) {
        error = "failed to create RGB CGImage";
    }
    return image;
}

CGImageRef makeGrayImage(int width, int height, const unsigned char* data, std::string& error) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    if (colorSpace == nullptr) {
        error = "failed to create grayscale color space";
        return nullptr;
    }

    size_t dataSize = static_cast<size_t>(width) * static_cast<size_t>(height);
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, data, dataSize, nullptr);
    if (provider == nullptr) {
        CGColorSpaceRelease(colorSpace);
        error = "failed to create grayscale data provider";
        return nullptr;
    }

    CGImageRef image = CGImageCreate(width,
                                     height,
                                     8,
                                     8,
                                     static_cast<size_t>(width),
                                     colorSpace,
                                     kCGImageAlphaNone,
                                     provider,
                                     nullptr,
                                     false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (image == nullptr) {
        error = "failed to create grayscale CGImage";
    }
    return image;
}

bool setFileDates(const std::filesystem::path& path, int64_t timestamp, std::string& error) {
    if (timestamp <= 0) {
        return true;
    }

    @autoreleasepool {
        NSString* pathString = [NSString stringWithUTF8String:path.string().c_str()];
        if (pathString == nil) {
            error = "failed to create NSString for file date path";
            return false;
        }

        NSDate* date = [NSDate dateWithTimeIntervalSince1970:static_cast<NSTimeInterval>(timestamp)];
        NSDictionary* attributes = @{
            NSFileCreationDate: date,
            NSFileModificationDate: date
        };
        NSError* nsError = nil;
        BOOL ok = [[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:pathString error:&nsError];
        if (!ok) {
            NSString* message = nsError.localizedDescription ?: @"unknown file date error";
            error = std::string("failed to set JPEG file dates: ") + [message UTF8String];
            return false;
        }
    }

    return true;
}

NSMutableDictionary* makeImageProperties(const jpgMetadata& metadata) {
    NSMutableDictionary* properties = [NSMutableDictionary dictionary];
    double quality = std::clamp(static_cast<double>(metadata.quality) / 100.0, 0.0, 1.0);
    properties[(__bridge NSString*)kCGImageDestinationLossyCompressionQuality] = @(quality);
    properties[(__bridge NSString*)kCGImagePropertyDPIWidth] = @(metadata.dpi > 0 ? metadata.dpi : 180);
    properties[(__bridge NSString*)kCGImagePropertyDPIHeight] = @(metadata.dpi > 0 ? metadata.dpi : 180);
    properties[(__bridge NSString*)kCGImagePropertyColorModel] = (__bridge NSString*)kCGImagePropertyColorModelRGB;

    NSString* dateString = exifDateFromTimestamp(metadata.timestamp);

    NSMutableDictionary* tiff = [NSMutableDictionary dictionary];
    setString(tiff, kCGImagePropertyTIFFMake, metadata.make);
    setString(tiff, kCGImagePropertyTIFFModel, metadata.model);
    setString(tiff, kCGImagePropertyTIFFSoftware, metadata.software);
    if (dateString != nil) {
        tiff[(__bridge NSString*)kCGImagePropertyTIFFDateTime] = dateString;
    }
    tiff[(__bridge NSString*)kCGImagePropertyTIFFOrientation] = @(metadata.orientation > 0 ? metadata.orientation : 1);
    tiff[(__bridge NSString*)kCGImagePropertyTIFFXResolution] = @(metadata.dpi > 0 ? metadata.dpi : 180);
    tiff[(__bridge NSString*)kCGImagePropertyTIFFYResolution] = @(metadata.dpi > 0 ? metadata.dpi : 180);
    tiff[(__bridge NSString*)kCGImagePropertyTIFFResolutionUnit] = @(2);
    properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary] = tiff;

    NSMutableDictionary* exif = [NSMutableDictionary dictionary];
    if (dateString != nil) {
        exif[(__bridge NSString*)kCGImagePropertyExifDateTimeOriginal] = dateString;
        exif[(__bridge NSString*)kCGImagePropertyExifDateTimeDigitized] = dateString;
    }
    if (metadata.isoSpeed > 0.0 && std::isfinite(metadata.isoSpeed)) {
        exif[(__bridge NSString*)kCGImagePropertyExifISOSpeedRatings] = @[@(static_cast<int>(std::lround(metadata.isoSpeed)))];
        exif[(__bridge NSString*)kCGImagePropertyExifISOSpeed] = @(static_cast<int>(std::lround(metadata.isoSpeed)));
    }
    setDouble(exif, kCGImagePropertyExifExposureTime, metadata.exposureTime);
    setDouble(exif, kCGImagePropertyExifFNumber, metadata.fNumber);
    setDouble(exif, kCGImagePropertyExifFocalLength, metadata.focalLength);
    setInt(exif, kCGImagePropertyExifFocalLenIn35mmFilm, metadata.focalLength35mm);
    setString(exif, kCGImagePropertyExifLensModel, metadata.lensModel);
    setInt(exif, kCGImagePropertyExifExposureProgram, metadata.exposureProgram);
    if (metadata.hasFlash) {
        exif[(__bridge NSString*)kCGImagePropertyExifFlash] = @(metadata.flash);
    }
    properties[(__bridge NSString*)kCGImagePropertyExifDictionary] = exif;

    return properties;
}

}  // namespace

bool writeJpgWithImageIo(const std::string& outputPath,
                         int width,
                         int height,
                         int colors,
                         const void* data,
                         const jpgMetadata& metadata,
                         std::string& error) {
    error.clear();
    if (outputPath.empty()) {
        error = "output path is empty";
        return false;
    }
    if (width <= 0 || height <= 0) {
        error = "image size must be positive";
        return false;
    }
    if (data == nullptr) {
        error = "image data is null";
        return false;
    }

    std::vector<unsigned char> rgbaBuffer;
    CGImageRef image = nullptr;
    const auto* bytes = static_cast<const unsigned char*>(data);
    if (colors == 3) {
        image = makeRgbImage(width, height, bytes, rgbaBuffer, error);
    } else if (colors == 1) {
        image = makeGrayImage(width, height, bytes, error);
    } else {
        std::ostringstream message;
        message << "unsupported channel count: " << colors;
        error = message.str();
        return false;
    }

    if (image == nullptr) {
        return false;
    }

    namespace fs = std::filesystem;
    fs::path finalPath(outputPath);
    fs::path tmpPath = finalPath;
    tmpPath.replace_filename(finalPath.filename().string() + ".tmp");
    fs::remove(tmpPath);

    @autoreleasepool {
        NSString* tmpString = [NSString stringWithUTF8String:tmpPath.string().c_str()];
        NSURL* url = [NSURL fileURLWithPath:tmpString];
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, kUTTypeJPEG, 1, nullptr);
        if (destination == nullptr) {
            CGImageRelease(image);
            error = "failed to create ImageIO destination";
            return false;
        }

        NSMutableDictionary* properties = makeImageProperties(metadata);
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
        bool finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);

        if (!finalized) {
            fs::remove(tmpPath);
            error = "failed to finalize ImageIO destination";
            return false;
        }
    }

    std::string dateError;
    if (!setFileDates(tmpPath, metadata.timestamp, dateError)) {
        fs::remove(tmpPath);
        error = dateError;
        return false;
    }

    std::error_code renameError;
    fs::rename(tmpPath, finalPath, renameError);
    if (renameError) {
        fs::remove(tmpPath);
        error = "failed to move temporary JPEG into place: " + renameError.message();
        return false;
    }

    return true;
}
