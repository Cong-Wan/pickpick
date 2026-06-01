/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 验证 JPG 分析器 backend 调度、Metal 可用路径和 CPU fallback 行为
 */

#include "testAssert.h"
#include "gpuSupport.h"
#include "imageAnalyzer.h"
#include <cmath>
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
    config.imageProcessing.rawBackend = ImageBackend::Cpu;
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
    std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 95};
    cv::imwrite(path.string(), image, params);
    return path.string();
}

static AnalyzeTask makeBackendTask(const std::string& path) {
    AnalyzeTask task;
    task.photoId = "backend";
    task.jpgPath = path;
    return task;
}

static bool imageAnalyzerCpuBackendUsesCpu() {
    std::string path = writeBackendImage("rawviewer-backend-cpu.jpg");
    AnalyzeResult result = ImageAnalyzer().analyze(makeBackendTask(path), makeBackendConfig(ImageBackend::Cpu));
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.backendUsed == "cpu");
    return true;
}

static bool imageAnalyzerAutoBackendFallsBackOrUsesMetal() {
    std::string path = writeBackendImage("rawviewer-backend-auto.jpg");
    AnalyzeResult result = ImageAnalyzer().analyze(makeBackendTask(path), makeBackendConfig(ImageBackend::Auto));
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.backendUsed == "cpu" || result.backendUsed == "metal");
    return true;
}

static bool imageAnalyzerMetalBackendMatchesCpuDecisionsWhenAvailable() {
    GpuSupport support = getGpuSupport();
    if (!support.hasMetal) {
        return true;
    }

    std::string path = writeBackendImage("rawviewer-backend-metal.jpg");
    AnalyzeTask task = makeBackendTask(path);
    AnalyzeResult cpuResult = ImageAnalyzer().analyze(task, makeBackendConfig(ImageBackend::Cpu));
    AnalyzeResult metalResult = ImageAnalyzer().analyze(task, makeBackendConfig(ImageBackend::Metal));

    TEST_REQUIRE(cpuResult.success);
    TEST_REQUIRE(metalResult.success);
    TEST_REQUIRE(metalResult.backendUsed == "metal");
    TEST_REQUIRE(cpuResult.exposureStatus == metalResult.exposureStatus);
    TEST_REQUIRE(cpuResult.isBlurry == metalResult.isBlurry);
    TEST_REQUIRE(cpuResult.histogramData.totalPixels == metalResult.histogramData.totalPixels);

    double base = std::max(std::abs(cpuResult.laplacianData.variance), 1.0);
    double relDiff = std::abs(cpuResult.laplacianData.variance - metalResult.laplacianData.variance) / base;
    TEST_REQUIRE(relDiff < 0.05);
    return true;
}

std::vector<TestCase> makeImageAnalyzerBackendTests() {
    return {
        {"imageAnalyzerBackend.cpuBackendUsesCpu", imageAnalyzerCpuBackendUsesCpu},
        {"imageAnalyzerBackend.autoBackendFallsBackOrUsesMetal", imageAnalyzerAutoBackendFallsBackOrUsesMetal},
        {"imageAnalyzerBackend.metalBackendMatchesCpuDecisionsWhenAvailable", imageAnalyzerMetalBackendMatchesCpuDecisionsWhenAvailable},
    };
}
