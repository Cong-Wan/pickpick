/*
 * Author: wilbur
 * Version: 2.0
 * Date: 2026-06-01
 * Description: 验证 GPU-only JPG 分析器匹配测试内 CPU reference 的直方图、曝光和拉普拉斯统计
 */

#include "testAssert.h"
#include "imageAnalyzer.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <opencv2/opencv.hpp>
#include <string>
#include <vector>

struct ReferenceAnalysis {
    std::vector<int64_t> bins;
    int64_t totalPixels = 0;
    int64_t overCount = 0;
    int64_t underCount = 0;
    double overRatio = 0.0;
    double underRatio = 0.0;
    std::string exposureStatus = "normal";
    double mean = 0.0;
    double variance = 0.0;
    double stddev = 0.0;
    double minVal = 0.0;
    double maxVal = 0.0;
    bool isBlurry = false;
};

static AppConfig makeAnalyzerConfig() {
    AppConfig config;
    config.blurDetection.laplacianThreshold = 100.0;
    config.blurDetection.laplacianKernelSize = 3;
    config.exposureDetection.overexposePixelThreshold = 245;
    config.exposureDetection.underexposePixelThreshold = 10;
    config.exposureDetection.overexposeRatioLimit = 0.05;
    config.exposureDetection.underexposeRatioLimit = 0.05;
    config.imageProcessing.analysisBackend = ImageBackend::Metal;
    config.imageProcessing.rawBackend = ImageBackend::Metal;
    return config;
}

static std::string writeImage(const std::string& fileName, const cv::Mat& image) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / fileName;
    std::vector<int> params = {cv::IMWRITE_PNG_COMPRESSION, 0};
    cv::imwrite(path.string(), image, params);
    return path.string();
}

static AnalyzeTask makeTask(const std::string& photoId, const std::string& path) {
    AnalyzeTask task;
    task.photoId = photoId;
    task.jpgPath = path;
    return task;
}

static ReferenceAnalysis makeReference(const cv::Mat& bgrImage, const AppConfig& config) {
    ReferenceAnalysis ref;
    ref.bins.assign(256, 0);
    ref.totalPixels = static_cast<int64_t>(bgrImage.rows) * bgrImage.cols;

    std::vector<int> gray(static_cast<size_t>(ref.totalPixels), 0);
    for (int y = 0; y < bgrImage.rows; ++y) {
        for (int x = 0; x < bgrImage.cols; ++x) {
            cv::Vec3b bgr = bgrImage.at<cv::Vec3b>(y, x);
            double b = bgr[0];
            double g = bgr[1];
            double r = bgr[2];
            int value = static_cast<int>(std::floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5));
            value = std::clamp(value, 0, 255);
            gray[static_cast<size_t>(y * bgrImage.cols + x)] = value;
            ref.bins[value]++;
            if (value > config.exposureDetection.overexposePixelThreshold) ref.overCount++;
            if (value < config.exposureDetection.underexposePixelThreshold) ref.underCount++;
        }
    }

    ref.overRatio = ref.totalPixels > 0 ? static_cast<double>(ref.overCount) / ref.totalPixels : 0.0;
    ref.underRatio = ref.totalPixels > 0 ? static_cast<double>(ref.underCount) / ref.totalPixels : 0.0;
    if (ref.overRatio > config.exposureDetection.overexposeRatioLimit) {
        ref.exposureStatus = "overexposed";
    } else if (ref.underRatio > config.exposureDetection.underexposeRatioLimit) {
        ref.exposureStatus = "underexposed";
    }

    double sum = 0.0;
    double sumSq = 0.0;
    ref.minVal = std::numeric_limits<double>::infinity();
    ref.maxVal = -std::numeric_limits<double>::infinity();
    for (int y = 0; y < bgrImage.rows; ++y) {
        for (int x = 0; x < bgrImage.cols; ++x) {
            int leftX = x == 0 ? 0 : x - 1;
            int rightX = x + 1 >= bgrImage.cols ? bgrImage.cols - 1 : x + 1;
            int upY = y == 0 ? 0 : y - 1;
            int downY = y + 1 >= bgrImage.rows ? bgrImage.rows - 1 : y + 1;
            double center = gray[static_cast<size_t>(y * bgrImage.cols + x)];
            double left = gray[static_cast<size_t>(y * bgrImage.cols + leftX)];
            double right = gray[static_cast<size_t>(y * bgrImage.cols + rightX)];
            double up = gray[static_cast<size_t>(upY * bgrImage.cols + x)];
            double down = gray[static_cast<size_t>(downY * bgrImage.cols + x)];
            double laplacian = center * 4.0 - left - right - up - down;
            sum += laplacian;
            sumSq += laplacian * laplacian;
            ref.minVal = std::min(ref.minVal, laplacian);
            ref.maxVal = std::max(ref.maxVal, laplacian);
        }
    }

    ref.mean = ref.totalPixels > 0 ? sum / static_cast<double>(ref.totalPixels) : 0.0;
    ref.variance = ref.totalPixels > 0 ? sumSq / static_cast<double>(ref.totalPixels) - ref.mean * ref.mean : 0.0;
    ref.variance = std::max(0.0, ref.variance);
    ref.stddev = std::sqrt(ref.variance);
    ref.isBlurry = ref.variance < config.blurDetection.laplacianThreshold;
    return ref;
}

static bool assertMatchesReference(const AnalyzeResult& result, const ReferenceAnalysis& ref) {
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.backendUsed == "metal");
    TEST_REQUIRE(result.histogramData.totalPixels == ref.totalPixels);
    TEST_REQUIRE(result.histogramData.bins == ref.bins);
    TEST_REQUIRE(result.histogramData.overexposePixelCount == ref.overCount);
    TEST_REQUIRE(result.histogramData.underexposePixelCount == ref.underCount);
    TEST_REQUIRE(result.exposureStatus == ref.exposureStatus);
    TEST_REQUIRE(result.isBlurry == ref.isBlurry);
    TEST_REQUIRE(std::abs(result.laplacianData.variance - ref.variance) <= std::max(1.0, ref.variance) * 0.001);
    return true;
}

static bool imageAnalyzerGpuDetectsUnderexposedBlackImage() {
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(0, 0, 0));
    std::string path = writeImage("rawviewer-gpu-black.png", image);
    ReferenceAnalysis ref = makeReference(image, config);
    AnalyzeResult result = ImageAnalyzer().analyze(makeTask("black", path), config);
    return assertMatchesReference(result, ref);
}

static bool imageAnalyzerGpuDetectsOverexposedWhiteImage() {
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(255, 255, 255));
    std::string path = writeImage("rawviewer-gpu-white.png", image);
    ReferenceAnalysis ref = makeReference(image, config);
    AnalyzeResult result = ImageAnalyzer().analyze(makeTask("white", path), config);
    return assertMatchesReference(result, ref);
}

static bool imageAnalyzerGpuMatchesReferenceForCheckerImage() {
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(0, 0, 0));
    for (int r = 0; r < image.rows; ++r) {
        for (int c = 0; c < image.cols; ++c) {
            uint8_t value = ((r + c) % 2 == 0) ? 0 : 255;
            image.at<cv::Vec3b>(r, c) = cv::Vec3b(value, value, value);
        }
    }
    std::string path = writeImage("rawviewer-gpu-checker.png", image);
    ReferenceAnalysis ref = makeReference(image, config);
    AnalyzeResult result = ImageAnalyzer().analyze(makeTask("checker", path), config);
    return assertMatchesReference(result, ref);
}

static bool imageAnalyzerGpuMatchesReferenceForGradientImage() {
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(32, 32, CV_8UC3, cv::Scalar(0, 0, 0));
    for (int r = 0; r < image.rows; ++r) {
        for (int c = 0; c < image.cols; ++c) {
            uint8_t value = static_cast<uint8_t>((r * 7 + c * 11) % 256);
            image.at<cv::Vec3b>(r, c) = cv::Vec3b(value, value, value);
        }
    }
    std::string path = writeImage("rawviewer-gpu-gradient.png", image);
    ReferenceAnalysis ref = makeReference(image, config);
    AnalyzeResult result = ImageAnalyzer().analyze(makeTask("gradient", path), config);
    return assertMatchesReference(result, ref);
}

std::vector<TestCase> makeImageAnalyzerTests() {
    return {
        {"imageAnalyzer.gpuDetectsUnderexposedBlackImage", imageAnalyzerGpuDetectsUnderexposedBlackImage},
        {"imageAnalyzer.gpuDetectsOverexposedWhiteImage", imageAnalyzerGpuDetectsOverexposedWhiteImage},
        {"imageAnalyzer.gpuMatchesReferenceForCheckerImage", imageAnalyzerGpuMatchesReferenceForCheckerImage},
        {"imageAnalyzer.gpuMatchesReferenceForGradientImage", imageAnalyzerGpuMatchesReferenceForGradientImage},
    };
}
