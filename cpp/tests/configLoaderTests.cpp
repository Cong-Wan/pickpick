/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 验证配置读取器只接受 Metal 图片处理 backend，并拒绝 CPU/auto 配置
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

static std::string writeTempConfig(const std::string& content) {
    return writeTempConfig("rawviewer-metal-only-config.yaml", content);
}

static bool configLoaderAcceptsMetalOnlyBackends() {
    std::string path = writeTempConfig(makeConfigText("metal", "metal"));
    AppConfig config = ConfigLoader().loadFromFile(path);
    TEST_REQUIRE(config.imageProcessing.analysisBackend == ImageBackend::Metal);
    TEST_REQUIRE(config.imageProcessing.rawBackend == ImageBackend::Metal);
    return true;
}

static bool configLoaderRejectsCpuAnalysisBackend() {
    std::string path = writeTempConfig(makeConfigText("cpu", "metal"));
    try {
        (void)ConfigLoader().loadFromFile(path);
    } catch (const std::runtime_error& err) {
        TEST_REQUIRE(std::string(err.what()).find("only metal is supported") != std::string::npos);
        return true;
    }
    TEST_REQUIRE(false);
    return false;
}

static bool configLoaderRejectsAutoAnalysisBackend() {
    std::string path = writeTempConfig(makeConfigText("auto", "metal"));
    try {
        (void)ConfigLoader().loadFromFile(path);
    } catch (const std::runtime_error& err) {
        TEST_REQUIRE(std::string(err.what()).find("only metal is supported") != std::string::npos);
        return true;
    }
    TEST_REQUIRE(false);
    return false;
}

std::vector<TestCase> makeConfigLoaderTests() {
    return {
        {"configLoader.acceptsMetalOnlyBackends", configLoaderAcceptsMetalOnlyBackends},
        {"configLoader.rejectsCpuAnalysisBackend", configLoaderRejectsCpuAnalysisBackend},
        {"configLoader.rejectsAutoAnalysisBackend", configLoaderRejectsAutoAnalysisBackend},
    };
}
