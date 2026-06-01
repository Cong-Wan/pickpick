/*
 * Author: wilbur
 * Version: 2.0
 * Date: 2026-06-01
 * Description: 验证 JPG 分析器始终使用 Metal-only backend
 */

#include "testAssert.h"
#include "imageAnalyzer.h"
#include <filesystem>
#include <opencv2/opencv.hpp>
#include <string>
#include <vector>

static AppConfig makeBackendConfig(ImageBackend backend) {
    AppConfig config;
    config.blurDetection.laplacianThreshold = 100.0;
    config.blurDetection.laplacianKernelSize = 3;
    config.exposureDetection.overexposePixelThreshold = 245;
    config.exposureDetection.underexposePixelThreshold = 10;
    config.exposureDetection.overexposeRatioLimit = 0.05;
    config.exposureDetection.underexposeRatioLimit = 0.05;
    config.imageProcessing.analysisBackend = backend;
    config.imageProcessing.rawBackend = ImageBackend::Metal;
    return config;
}

static std::string writeBackendImage(const std::string& fileName) {
    cv::Mat image(32, 32, CV_8UC3, cv::Scalar(120, 120, 120));
    for (int r = 0; r < image.rows; ++r) {
        for (int c = 0; c < image.cols; ++c) {
            uint8_t v = static_cast<uint8_t>((r * 7 + c * 5) % 256);
            image.at<cv::Vec3b>(r, c) = cv::Vec3b(v, v, v);
        }
    }

    std::filesystem::path path = std::filesystem::temp_directory_path() / fileName;
    std::vector<int> params = {cv::IMWRITE_PNG_COMPRESSION, 0};
    cv::imwrite(path.string(), image, params);
    return path.string();
}

static AnalyzeTask makeBackendTask(const std::string& path) {
    AnalyzeTask task;
    task.photoId = "backend";
    task.jpgPath = path;
    return task;
}

static bool imageAnalyzerAlwaysUsesMetalBackend() {
    std::string path = writeBackendImage("rawviewer-backend-metal-only.png");
    AnalyzeResult result = ImageAnalyzer().analyze(makeBackendTask(path), makeBackendConfig(ImageBackend::Metal));
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.backendUsed == "metal");
    return true;
}

std::vector<TestCase> makeImageAnalyzerBackendTests() {
    return {
        {"imageAnalyzerBackend.alwaysUsesMetalBackend", imageAnalyzerAlwaysUsesMetalBackend},
    };
}
