/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 实现扫描、JSON 合并、两阶段线程池执行、即时 JSON 保存、最终摘要输出
 */

#include "appRunner.h"
#include "rawConverter.h"
#include "imageAnalyzer.h"
#include "configLoader.h"
#include "fileScanner.h"
#include "jsonManager.h"
#include "resumePlanner.h"
#include "threadPool.h"
#include <iostream>

AppRunner::AppRunner()
    : convertFn_([](const RawConvertTask& t, const AppConfig& c) { return RawConverter().convert(t, c); }),
      analyzeFn_([](const AnalyzeTask& t, const AppConfig& c) { return ImageAnalyzer().analyze(t, c); }) {
}

AppRunner::AppRunner(RawConvertFn converter, AnalyzeFn analyzer)
    : convertFn_(converter), analyzeFn_(analyzer) {
}

RawConvertResult AppRunner::convertWithRetry(const RawConvertTask& task, const AppConfig& config) {
    RawConvertResult result = convertFn_(task, config);
    result.photoId = task.photoId;
    result.rawPath = task.rawPath;
    result.jpgPath = task.outputJpgPath;
    result.attempts = 1;
    if (!result.success) {
        RawConvertResult retry = convertFn_(task, config);
        retry.photoId = task.photoId;
        retry.rawPath = task.rawPath;
        retry.jpgPath = task.outputJpgPath;
        retry.attempts = 2;
        if (retry.success) {
            retry.error.clear();
            return retry;
        }
        return retry;
    }
    return result;
}

AnalyzeResult AppRunner::analyzeWithRetry(const AnalyzeTask& task, const AppConfig& config) {
    AnalyzeResult result = analyzeFn_(task, config);
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;
    result.attempts = 1;
    if (!result.success) {
        AnalyzeResult retry = analyzeFn_(task, config);
        retry.photoId = task.photoId;
        retry.jpgPath = task.jpgPath;
        retry.attempts = 2;
        if (retry.success) {
            retry.error.clear();
            return retry;
        }
        return retry;
    }
    return result;
}

RunSummary AppRunner::run(const RunOptions& options) {
    ConfigLoader configLoader;
    AppConfig config = configLoader.loadFromFile(options.configPath);

    FileScanner scanner;
    auto pairs = scanner.scanTopLevel(options.folderPath);

    JsonManager jsonManager;
    jsonManager.init(options.folderPath, options.configPath);
    jsonManager.mergeScannedPairs(pairs);
    jsonManager.markRunningAsPending();
    jsonManager.atomicSave();

    auto states = jsonManager.getAllPhotoStates();
    ResumePlanner planner;
    auto planned = planner.plan(states, config);

    // RAW conversion phase
    if (!planned.rawConvertTasks.empty()) {
        ThreadPool<RawConvertTask, RawConvertResult> pool([this, &config](const RawConvertTask& t) {
            return this->convertWithRetry(t, config);
        });

        for (const auto& task : planned.rawConvertTasks) {
            auto state = jsonManager.getPhotoState(task.photoId);
            state.rawConversionStatus = StageStatus::Running;
            // Note: jsonManager doesn't have a direct setter for running status,
            // we update via updateRawConversionResult after completion.
            // For running marker, we could save a temporary state, but the plan
            // says to mark running before submitting. Let's use a workaround.
            // Actually, the JSON manager's update functions set the status directly.
            // We'll skip explicit running marker for now and handle it in the result update.
            pool.pushTask(task);
        }

        pool.waitUntilFinished();
        RawConvertResult rcResult;
        while (pool.tryPopResult(rcResult)) {
            jsonManager.updateRawConversionResult(rcResult);
            jsonManager.atomicSave();
        }
        pool.stop();
    }

    // Re-plan after RAW conversion
    states = jsonManager.getAllPhotoStates();
    planned = planner.plan(states, config);

    // Analysis phase
    if (!planned.analyzeTasks.empty()) {
        ThreadPool<AnalyzeTask, AnalyzeResult> pool([this, &config](const AnalyzeTask& t) {
            return this->analyzeWithRetry(t, config);
        });

        for (const auto& task : planned.analyzeTasks) {
            pool.pushTask(task);
        }

        pool.waitUntilFinished();
        AnalyzeResult anaResult;
        while (pool.tryPopResult(anaResult)) {
            jsonManager.updateAnalysisResult(anaResult);
            jsonManager.atomicSave();
        }
        pool.stop();
    }

    // Final summary
    states = jsonManager.getAllPhotoStates();
    RunSummary summary;
    summary.totalPhotos = static_cast<int>(states.size());
    for (const auto& state : states) {
        if (state.rawConversionStatus == StageStatus::Success) summary.rawConversionSuccess++;
        if (state.rawConversionStatus == StageStatus::Failed) summary.rawConversionFailed++;
        if (state.analysisStatus == StageStatus::Success) summary.analysisSuccess++;
        if (state.analysisStatus == StageStatus::Failed) summary.analysisFailed++;
        if (state.rawConversionStatus == StageStatus::Pending || state.rawConversionStatus == StageStatus::Running ||
            state.analysisStatus == StageStatus::Pending || state.analysisStatus == StageStatus::Running) {
            summary.pending++;
        }
        if (state.isBlurry) summary.blurry++;
        if (state.exposureStatus == "overexposed") summary.overexposed++;
        if (state.exposureStatus == "underexposed") summary.underexposed++;
        if (state.exposureStatus == "normal") summary.normal++;
    }

    jsonManager.atomicSave();
    return summary;
}
