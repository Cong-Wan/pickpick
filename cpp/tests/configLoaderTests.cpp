/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 验证配置读取器对图片处理 backend 配置的成功解析和非法值拒绝
 */

#include "testAssert.h"
#include "configLoader.h"
#include "taskState.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

static std::string makeConfigText(const std::string& analysisBackend, const std::string& rawBackend) {
    return "blur_detection:\n"
           "  laplacian_threshold: 100.0\n"
           "  laplacian_kernel_size: 3\n"
           "exposure_detection:\n"
           "  overexpose_pixel_threshold: 245\n"
           "  underexpose_pixel_threshold: 10\n"
           "  overexpose_ratio_limit: 0.05\n"
           "  underexpose_ratio_limit: 0.05\n"
           "raw_conversion:\n"
           "  jpg_quality: 95\n"
           "image_processing:\n"
           "  analysis_backend: " + analysisBackend + "\n"
           "  raw_backend: " + rawBackend + "\n"
           "  log_backend: true\n"
           "thread_pool:\n"
           "  worker_count: 4\n";
}

static std::string writeTempConfig(const std::string& fileName, const std::string& content) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / fileName;
    std::ofstream out(path);
    out << content;
    return path.string();
}

static bool configLoaderParsesValidImageBackends() {
    ConfigLoader loader;
    const std::vector<std::string> values = {"auto", "cpu", "metal"};

    for (const auto& value : values) {
        std::string path = writeTempConfig("rawviewer-valid-" + value + ".yaml", makeConfigText(value, value));
        AppConfig config = loader.loadFromFile(path);
        TEST_REQUIRE(toString(config.imageProcessing.analysisBackend) == value);
        TEST_REQUIRE(toString(config.imageProcessing.rawBackend) == value);
        TEST_REQUIRE(config.imageProcessing.logBackend);
    }

    return true;
}

static bool configLoaderRejectsInvalidImageBackend() {
    ConfigLoader loader;
    std::string path = writeTempConfig("rawviewer-invalid-backend.yaml", makeConfigText("opencl", "auto"));

    try {
        loader.loadFromFile(path);
    } catch (const std::runtime_error& err) {
        TEST_REQUIRE(std::string(err.what()).find("Invalid config field: image_processing.analysis_backend") != std::string::npos);
        return true;
    }

    TEST_REQUIRE(false);
    return false;
}

std::vector<TestCase> makeConfigLoaderTests() {
    return {
        {"configLoader.parsesValidImageBackends", configLoaderParsesValidImageBackends},
        {"configLoader.rejectsInvalidImageBackend", configLoaderRejectsInvalidImageBackend},
    };
}
