/*
 * Author: wilbur
 * Version: 1.3
 * Date: 2026-06-01
 * Description: 使用 OpenCV 或 macOS Metal-backed Core Image 分析 JPG，并保留 CPU fallback
 */

#include "imageAnalyzer.h"
#include "gpuSupport.h"
#include "imageAnalysisCore.h"
#include "macImageAnalyzer.h"
#include "perfTimer.h"
#include <opencv2/opencv.hpp>

static AnalyzeResult analyzeWithCpu(const AnalyzeTask& task, const AppConfig& config) {
    AnalyzeResult result;
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;
    result.backendUsed = "cpu";

    PerfTimer phaseTimer;
    cv::Mat img = cv::imread(task.jpgPath, cv::IMREAD_COLOR);
    result.readImageMs = phaseTimer.elapsedMs();
    if (img.empty()) {
        result.success = false;
        result.error = "Failed to read JPG: " + task.jpgPath;
        return result;
    }

    cv::Mat gray;
    phaseTimer.reset();
    cv::cvtColor(img, gray, cv::COLOR_BGR2GRAY);
    result.grayMs = phaseTimer.elapsedMs();

    fillAnalyzeResultFromGray(gray, config, result);
    result.backendUsed = "cpu";
    return result;
}

AnalyzeResult ImageAnalyzer::analyze(const AnalyzeTask& task, const AppConfig& config) const {
    if (config.imageProcessing.analysisBackend == ImageBackend::Cpu) {
        return analyzeWithCpu(task, config);
    }

    if (config.imageProcessing.analysisBackend == ImageBackend::Metal) {
        return analyzeWithMacMetal(task, config);
    }

    GpuSupport support = getGpuSupport();
    if (!support.hasMetal) {
        return analyzeWithCpu(task, config);
    }

    AnalyzeResult metalResult = analyzeWithMacMetal(task, config);
    if (metalResult.success) {
        return metalResult;
    }

    return analyzeWithCpu(task, config);
}
