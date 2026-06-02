/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-02
 * Description: 提供基于灰度图的共享分析逻辑，供 CPU 和 macOS GPU 渲染路径复用；使用精细毫秒计时
 */

#pragma once

#include "perfTimer.h"
#include "taskState.h"
#include <opencv2/opencv.hpp>
#include <cstdint>
#include <string>
#include <vector>

inline void fillAnalyzeResultFromGray(const cv::Mat& gray, const AppConfig& config, AnalyzeResult& result) {
    cv::Mat laplacian;
    int ksize = config.blurDetection.laplacianKernelSize;
    PerfTimer phaseTimer;
    cv::Laplacian(gray, laplacian, CV_64F, ksize);
    result.laplacianMs = phaseTimer.elapsedMsPrecise();

    phaseTimer.reset();
    cv::Scalar meanVal, stddevVal;
    cv::meanStdDev(laplacian, meanVal, stddevVal);
    double minVal, maxVal;
    cv::minMaxLoc(laplacian, &minVal, &maxVal);
    result.statsMs = phaseTimer.elapsedMsPrecise();

    double mean = meanVal[0];
    double stddev = stddevVal[0];
    double variance = stddev * stddev;

    std::vector<int64_t> bins(256, 0);
    int64_t totalPixels = static_cast<int64_t>(gray.rows) * gray.cols;
    int64_t overCount = 0;
    int64_t underCount = 0;

    phaseTimer.reset();
    for (int r = 0; r < gray.rows; ++r) {
        const uint8_t* row = gray.ptr<uint8_t>(r);
        for (int c = 0; c < gray.cols; ++c) {
            uint8_t v = row[c];
            bins[v]++;
            if (v > config.exposureDetection.overexposePixelThreshold) overCount++;
            if (v < config.exposureDetection.underexposePixelThreshold) underCount++;
        }
    }
    result.histogramMs = phaseTimer.elapsedMsPrecise();

    double overRatio = totalPixels > 0 ? static_cast<double>(overCount) / totalPixels : 0.0;
    double underRatio = totalPixels > 0 ? static_cast<double>(underCount) / totalPixels : 0.0;

    std::string exposureStatus = "normal";
    if (overRatio > config.exposureDetection.overexposeRatioLimit) {
        exposureStatus = "overexposed";
    } else if (underRatio > config.exposureDetection.underexposeRatioLimit) {
        exposureStatus = "underexposed";
    }

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
}
