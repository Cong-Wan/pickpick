/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 验证 JPG 分析器在典型曝光图像上的直方图、曝光状态和模糊判断输出
 */

#include "testAssert.h"
#include "imageAnalyzer.h"
#include <filesystem>
#include <numeric>
#include <opencv2/opencv.hpp>
#include <string>
#include <vector>

static AppConfig makeAnalyzerConfig() {
    AppConfig config;
    config.blurDetection.laplacianThreshold = 100.0;
    config.blurDetection.laplacianKernelSize = 3;
    config.exposureDetection.overexposePixelThreshold = 245;
    config.exposureDetection.underexposePixelThreshold = 10;
    config.exposureDetection.overexposeRatioLimit = 0.05;
    config.exposureDetection.underexposeRatioLimit = 0.05;
    return config;
}

static std::string writeImage(const std::string& fileName, const cv::Mat& image) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / fileName;
    cv::imwrite(path.string(), image);
    return path.string();
}

static int64_t sumBins(const std::vector<int64_t>& bins) {
    return std::accumulate(bins.begin(), bins.end(), int64_t{0});
}

static bool imageAnalyzerDetectsUnderexposedBlackImage() {
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(0, 0, 0));
    std::string path = writeImage("rawviewer-black.png", image);

    AnalyzeTask task;
    task.photoId = "black";
    task.jpgPath = path;

    AnalyzeResult result = ImageAnalyzer().analyze(task, makeAnalyzerConfig());
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.histogramData.totalPixels == 256);
    TEST_REQUIRE(result.histogramData.bins.size() == 256);
    TEST_REQUIRE(result.histogramData.bins[0] == 256);
    TEST_REQUIRE(result.histogramData.underexposePixelCount == 256);
    TEST_REQUIRE(result.histogramData.underexposeRatio == 1.0);
    TEST_REQUIRE(result.exposureStatus == "underexposed");
    return true;
}

static bool imageAnalyzerDetectsOverexposedWhiteImage() {
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(255, 255, 255));
    std::string path = writeImage("rawviewer-white.png", image);

    AnalyzeTask task;
    task.photoId = "white";
    task.jpgPath = path;

    AnalyzeResult result = ImageAnalyzer().analyze(task, makeAnalyzerConfig());
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.histogramData.totalPixels == 256);
    TEST_REQUIRE(result.histogramData.bins.size() == 256);
    TEST_REQUIRE(result.histogramData.bins[255] == 256);
    TEST_REQUIRE(result.histogramData.overexposePixelCount == 256);
    TEST_REQUIRE(result.histogramData.overexposeRatio == 1.0);
    TEST_REQUIRE(result.exposureStatus == "overexposed");
    return true;
}

static bool imageAnalyzerKeepsMixedHistogramTotalAndBlurDecision() {
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(128, 128, 128));
    for (int r = 0; r < image.rows; ++r) {
        for (int c = 0; c < image.cols; ++c) {
            if ((r + c) % 2 == 0) {
                image.at<cv::Vec3b>(r, c) = cv::Vec3b(0, 0, 0);
            } else {
                image.at<cv::Vec3b>(r, c) = cv::Vec3b(255, 255, 255);
            }
        }
    }
    std::string path = writeImage("rawviewer-mixed.png", image);

    AnalyzeTask task;
    task.photoId = "mixed";
    task.jpgPath = path;

    AnalyzeResult result = ImageAnalyzer().analyze(task, makeAnalyzerConfig());
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.histogramData.totalPixels == 256);
    TEST_REQUIRE(sumBins(result.histogramData.bins) == 256);
    TEST_REQUIRE(result.laplacianData.variance >= 0.0);
    TEST_REQUIRE(result.isBlurry == (result.laplacianData.variance < result.blurConfigSnapshot.laplacianThreshold));
    return true;
}

std::vector<TestCase> makeImageAnalyzerTests() {
    return {
        {"imageAnalyzer.detectsUnderexposedBlackImage", imageAnalyzerDetectsUnderexposedBlackImage},
        {"imageAnalyzer.detectsOverexposedWhiteImage", imageAnalyzerDetectsOverexposedWhiteImage},
        {"imageAnalyzer.keepsMixedHistogramTotalAndBlurDecision", imageAnalyzerKeepsMixedHistogramTotalAndBlurDecision},
    };
}
