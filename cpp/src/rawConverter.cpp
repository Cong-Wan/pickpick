/*
 * Author: wilbur
 * Version: 1.4
 * Date: 2026-06-03
 * Description: 使用 LibRaw 解码 RW2/CR2，并通过 ImageIO 一次性写出带基础 TIFF/EXIF 元信息的 JPG；接入 jpgWriter 模块替代 OpenCV imwrite
 */

#include "rawConverter.h"
#include "perfTimer.h"
#include "jpgWriter.h"
#include <libraw.h>
#include <filesystem>
#include <fstream>

RawConvertResult RawConverter::convert(const RawConvertTask& task, const AppConfig& config) const {
    RawConvertResult result;
    result.photoId = task.photoId;
    result.rawPath = task.rawPath;
    result.jpgPath = task.outputJpgPath;

    if (!std::filesystem::exists(task.rawPath)) {
        result.success = false;
        result.error = "RAW file not found: " + task.rawPath;
        return result;
    }

    std::filesystem::path outDir = std::filesystem::path(task.outputJpgPath).parent_path();
    if (!outDir.empty() && !std::filesystem::exists(outDir)) {
        std::filesystem::create_directories(outDir);
    }

    LibRaw rawProcessor;
    PerfTimer phaseTimer;
    int ret = rawProcessor.open_file(task.rawPath.c_str());
    result.openFileMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw open failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    rawProcessor.imgdata.params.use_camera_wb = 1;
    rawProcessor.imgdata.params.use_auto_wb = 0;
    rawProcessor.imgdata.params.output_color = 1;
    rawProcessor.imgdata.params.output_bps = 8;

    phaseTimer.reset();
    ret = rawProcessor.unpack();
    result.unpackMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw unpack failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    ret = rawProcessor.dcraw_process();
    result.processMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw process failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    libraw_processed_image_t* img = rawProcessor.dcraw_make_mem_image(&ret);
    result.makeImageMs = phaseTimer.elapsedMs();
    if (!img || ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw make image failed";
        if (img) rawProcessor.dcraw_clear_mem(img);
        return result;
    }

    jpgMetadata metadata;
    metadata.quality = config.rawConversion.jpgQuality;
    metadata.timestamp = static_cast<int64_t>(rawProcessor.imgdata.other.timestamp);
    metadata.make = rawProcessor.imgdata.idata.make;
    metadata.model = rawProcessor.imgdata.idata.model;
    metadata.software = rawProcessor.imgdata.idata.software;
    metadata.isoSpeed = rawProcessor.imgdata.other.iso_speed;
    metadata.exposureTime = rawProcessor.imgdata.other.shutter;
    metadata.fNumber = rawProcessor.imgdata.other.aperture;
    metadata.focalLength = rawProcessor.imgdata.other.focal_len;
    metadata.lensModel = rawProcessor.imgdata.lens.Lens;
    if (rawProcessor.imgdata.lens.FocalLengthIn35mmFormat > 0) {
        metadata.focalLength35mm = rawProcessor.imgdata.lens.FocalLengthIn35mmFormat;
    } else if (rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0.0f) {
        metadata.focalLength35mm = static_cast<int>(rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat + 0.5f);
    }
    if (rawProcessor.imgdata.shootinginfo.ExposureProgram > 0) {
        metadata.exposureProgram = rawProcessor.imgdata.shootinginfo.ExposureProgram;
    }
    metadata.flash = rawProcessor.imgdata.color.flash_used > 0.0f ? 1 : 0;
    metadata.hasFlash = true;

    std::string writeError;
    phaseTimer.reset();
    bool written = writeJpgWithImageIo(task.outputJpgPath, img->width, img->height, img->colors, img->data, metadata, writeError);
    result.writeJpgMs = phaseTimer.elapsedMs();
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        result.success = false;
        result.error = "ImageIO write failed: " + writeError;
        return result;
    }

    result.success = true;
    return result;
}
