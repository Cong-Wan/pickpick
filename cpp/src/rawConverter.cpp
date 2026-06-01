/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 使用 LibRaw + OpenCV 将 RW2/CR2 转 JPG；worker 调用重试封装；记录 RAW 转换阶段耗时
 */

#include "rawConverter.h"
#include "perfTimer.h"
#include <libraw.h>
#include <opencv2/opencv.hpp>
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

    cv::Mat mat;
    if (img->colors == 3) {
        mat = cv::Mat(img->height, img->width, CV_8UC3, img->data);
    } else {
        mat = cv::Mat(img->height, img->width, CV_8UC1, img->data);
    }

    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, config.rawConversion.jpgQuality};
    phaseTimer.reset();
    bool written = cv::imwrite(task.outputJpgPath, mat, params);
    result.writeJpgMs = phaseTimer.elapsedMs();
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        result.success = false;
        result.error = "OpenCV imwrite failed: " + task.outputJpgPath;
        return result;
    }

    result.success = true;
    return result;
}
