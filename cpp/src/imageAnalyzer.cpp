/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 使用 OpenCV 读取 JPG，计算拉普拉斯统计和 256-bin 灰度直方图，生成配置快照
 */

#include "imageAnalyzer.h"
#include <opencv2/opencv.hpp>
#include <vector>

AnalyzeResult ImageAnalyzer::analyze(const AnalyzeTask& task, const AppConfig& config) const {
    AnalyzeResult result;
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;

    cv::Mat img = cv::imread(task.jpgPath, cv::IMREAD_COLOR);
    if (img.empty()) {
        result.success = false;
        result.error = "Failed to read JPG: " + task.jpgPath;
        return result;
    }

    cv::Mat gray;
    cv::cvtColor(img, gray, cv::COLOR_BGR2GRAY);

    // Laplacian
    cv::Mat laplacian;
    int ksize = config.blurDetection.laplacianKernelSize;
    cv::Laplacian(gray, laplacian, CV_64F, ksize);

    cv::Scalar meanVal, stddevVal;
    cv::meanStdDev(laplacian, meanVal, stddevVal);
    double minVal, maxVal;
    cv::minMaxLoc(laplacian, &minVal, &maxVal);

    double mean = meanVal[0];
    double stddev = stddevVal[0];
    double variance = stddev * stddev;

    // Histogram (256 bins)
    std::vector<int64_t> bins(256, 0);
    int64_t totalPixels = gray.rows * gray.cols;
    int64_t overCount = 0;
    int64_t underCount = 0;

    for (int r = 0; r < gray.rows; ++r) {
        for (int c = 0; c < gray.cols; ++c) {
            uint8_t v = gray.at<uint8_t>(r, c);
            bins[v]++;
            if (v > config.exposureDetection.overexposePixelThreshold) overCount++;
            if (v < config.exposureDetection.underexposePixelThreshold) underCount++;
        }
    }

    double overRatio = totalPixels > 0 ? static_cast<double>(overCount) / totalPixels : 0.0;
    double underRatio = totalPixels > 0 ? static_cast<double>(underCount) / totalPixels : 0.0;

    std::string exposureStatus = "normal";
    if (overRatio > config.exposureDetection.overexposeRatioLimit) {
        exposureStatus = "overexposed";
    } else if (underRatio > config.exposureDetection.underexposeRatioLimit) {
        exposureStatus = "underexposed";
    }

    // Fill result
    result.success = true;
    result.isBlurry = variance < config.blurDetection.laplacianThreshold;
    result.exposureStatus = exposureStatus;

    result.blurConfigSnapshot = config.blurDetection;
    result.exposureConfigSnapshot = config.exposureDetection;

    result.laplacianData.variance = variance;
    result.laplacianData.mean = mean;
    result.laplacianData.stddev = stddev;
    result.laplacianData.min = minVal;
    result.laplacianData.max = maxVal;
    result.laplacianData.kernelSize = ksize;

    result.histogramData.binCount = 256;
    result.histogramData.bins = bins;
    result.histogramData.totalPixels = totalPixels;
    result.histogramData.overexposePixelCount = overCount;
    result.histogramData.underexposePixelCount = underCount;
    result.histogramData.overexposeRatio = overRatio;
    result.histogramData.underexposeRatio = underRatio;

    return result;
}
