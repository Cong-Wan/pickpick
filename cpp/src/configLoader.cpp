/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 使用 yaml-cpp 读取 config.yaml，缺字段或非法值时抛出明确错误；补充图片处理 backend 配置解析
 */

#include "configLoader.h"
#include <yaml-cpp/yaml.h>
#include <stdexcept>
#include <fstream>

static void checkMissing(const YAML::Node& node, const char* path) {
    if (!node || node.IsNull()) {
        throw std::runtime_error(std::string("Missing config field: ") + path);
    }
}

static void checkRangeDouble(const YAML::Node& node, const char* path, double minVal, double maxVal) {
    checkMissing(node, path);
    double val = node.as<double>();
    if (val < minVal || val > maxVal) {
        throw std::runtime_error(std::string("Invalid config field: ") + path);
    }
}

static void checkRangeInt(const YAML::Node& node, const char* path, int minVal, int maxVal) {
    checkMissing(node, path);
    int val = node.as<int>();
    if (val < minVal || val > maxVal) {
        throw std::runtime_error(std::string("Invalid config field: ") + path);
    }
}

static ImageBackend readImageBackend(const YAML::Node& node, const char* path) {
    checkMissing(node, path);
    try {
        return imageBackendFromString(node.as<std::string>());
    } catch (const std::invalid_argument&) {
        throw std::runtime_error(std::string("Invalid config field: ") + path);
    }
}

AppConfig ConfigLoader::loadFromFile(const std::string& configPath) const {
    std::ifstream fin(configPath);
    if (!fin) {
        throw std::runtime_error("Config file not found: " + configPath);
    }

    YAML::Node root = YAML::LoadFile(configPath);

    AppConfig config;

    auto blur = root["blur_detection"];
    checkMissing(blur, "blur_detection");
    checkRangeDouble(blur["laplacian_threshold"], "blur_detection.laplacian_threshold", 0.0, 1e9);
    config.blurDetection.laplacianThreshold = blur["laplacian_threshold"].as<double>();

    checkMissing(blur["laplacian_kernel_size"], "blur_detection.laplacian_kernel_size");
    int kernelSize = blur["laplacian_kernel_size"].as<int>();
    if (kernelSize != 3) {
        throw std::runtime_error("Invalid config field: blur_detection.laplacian_kernel_size; GPU analyzer supports 3 only");
    }
    config.blurDetection.laplacianKernelSize = kernelSize;

    auto exposure = root["exposure_detection"];
    checkMissing(exposure, "exposure_detection");
    checkRangeInt(exposure["overexpose_pixel_threshold"], "exposure_detection.overexpose_pixel_threshold", 0, 255);
    config.exposureDetection.overexposePixelThreshold = exposure["overexpose_pixel_threshold"].as<int>();

    checkRangeInt(exposure["underexpose_pixel_threshold"], "exposure_detection.underexpose_pixel_threshold", 0, 255);
    config.exposureDetection.underexposePixelThreshold = exposure["underexpose_pixel_threshold"].as<int>();

    checkRangeDouble(exposure["overexpose_ratio_limit"], "exposure_detection.overexpose_ratio_limit", 0.0, 1.0);
    config.exposureDetection.overexposeRatioLimit = exposure["overexpose_ratio_limit"].as<double>();

    checkRangeDouble(exposure["underexpose_ratio_limit"], "exposure_detection.underexpose_ratio_limit", 0.0, 1.0);
    config.exposureDetection.underexposeRatioLimit = exposure["underexpose_ratio_limit"].as<double>();

    auto rawConv = root["raw_conversion"];
    checkMissing(rawConv, "raw_conversion");
    checkRangeInt(rawConv["jpg_quality"], "raw_conversion.jpg_quality", 0, 100);
    config.rawConversion.jpgQuality = rawConv["jpg_quality"].as<int>();

    auto tp = root["thread_pool"];
    checkMissing(tp, "thread_pool");
    checkMissing(tp["worker_count"], "thread_pool.worker_count");
    config.threadPool.workerCount = tp["worker_count"].as<int>();
    config.effectiveWorkerCount = 4;

    auto imageProcessing = root["image_processing"];
    checkMissing(imageProcessing, "image_processing");
    config.imageProcessing.analysisBackend = readImageBackend(
        imageProcessing["analysis_backend"], "image_processing.analysis_backend");
    if (config.imageProcessing.analysisBackend != ImageBackend::Metal) {
        throw std::runtime_error("Invalid config field: image_processing.analysis_backend; only metal is supported");
    }
    config.imageProcessing.rawBackend = readImageBackend(
        imageProcessing["raw_backend"], "image_processing.raw_backend");
    if (config.imageProcessing.rawBackend != ImageBackend::Metal) {
        throw std::runtime_error("Invalid config field: image_processing.raw_backend; only metal is supported by configuration");
    }
    checkMissing(imageProcessing["log_backend"], "image_processing.log_backend");
    config.imageProcessing.logBackend = imageProcessing["log_backend"].as<bool>();

    return config;
}
