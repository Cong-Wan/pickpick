/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 声明端到端流程编排器、进度回调模型，允许测试注入 fake converter/analyzer
 */

#pragma once

#include "taskState.h"
#include <functional>

enum class RunPhase {
    Scanning,
    RawConversion,
    Analysis,
    Organizing,
    Completed
};

struct RunProgress {
    RunPhase phase = RunPhase::Scanning;
    int completedCount = 0;
    int totalCount = 0;
    double overallProgress = 0.0;
};

struct RunOptions {
    std::string folderPath;
    std::string configPath;
    bool resume = false;
    std::function<void(const RunProgress&)> progressCallback;
};

struct RunSummary {
    int totalPhotos = 0;
    int rawConversionSuccess = 0;
    int rawConversionFailed = 0;
    int analysisSuccess = 0;
    int analysisFailed = 0;
    int pending = 0;
    int blurry = 0;
    int overexposed = 0;
    int underexposed = 0;
    int normal = 0;
};

class AppRunner {
public:
    using RawConvertFn = std::function<RawConvertResult(const RawConvertTask&, const AppConfig&)>;
    using AnalyzeFn = std::function<AnalyzeResult(const AnalyzeTask&, const AppConfig&)>;

    AppRunner();
    explicit AppRunner(RawConvertFn converter, AnalyzeFn analyzer);

    RunSummary run(const RunOptions& options);

    RawConvertResult convertWithRetry(const RawConvertTask& task, const AppConfig& config);
    AnalyzeResult analyzeWithRetry(const AnalyzeTask& task, const AppConfig& config);

private:
    RawConvertFn convertFn_;
    AnalyzeFn analyzeFn_;
};
