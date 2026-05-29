/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 使用 LibRaw + OpenCV 将 RW2/CR2 转 JPG；worker 调用重试封装
 */

#include "rawConverter.h"
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
    int ret = rawProcessor.open_file(task.rawPath.c_str());
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw open failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    ret = rawProcessor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw unpack failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    ret = rawProcessor.dcraw_process();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw process failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    libraw_processed_image_t* img = rawProcessor.dcraw_make_mem_image(&ret);
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
    bool written = cv::imwrite(task.outputJpgPath, mat, params);
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        result.success = false;
        result.error = "OpenCV imwrite failed: " + task.outputJpgPath;
        return result;
    }

    result.success = true;
    return result;
}
