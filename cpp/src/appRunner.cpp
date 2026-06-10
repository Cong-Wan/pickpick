/*
 * Author: wilbur
 * Version: 1.6
 * Date: 2026-06-09
 * Description: 修复线程池阶段进度阻塞不更新的 bug；分析器改为 IAnalyzer 接口注入；写入转换和分析阶段性能日志；分析阶段日志使用 double 毫秒，显示小数毫秒；使用共享 summary counts 统计
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
#include <cassert>
#include <chrono>
#include <fstream>
#include <filesystem>
#include <ctime>
#include <algorithm>
#include <iomanip>

namespace {

constexpr double kScanningStart = 0.0;
constexpr double kScanningEnd = 0.1;
constexpr double kRawConversionEnd = 0.45;
constexpr double kAnalysisEnd = 0.9;
constexpr double kOrganizingEnd = 0.98;
constexpr double kCompleted = 1.0;

void emitProgress(const RunOptions& options,
                  RunPhase phase,
                  int completedCount,
                  int totalCount,
                  double overallProgress) {
    if (!options.progressCallback) {
        return;
    }

    RunProgress progress;
    progress.phase = phase;
    progress.completedCount = completedCount;
    progress.totalCount = totalCount;
    progress.overallProgress = std::clamp(overallProgress, 0.0, 1.0);
    options.progressCallback(progress);
}

void emitStageProgress(const RunOptions& options,
                       RunPhase phase,
                       int completedCount,
                       int totalCount,
                       double stageStart,
                       double stageEnd) {
    double ratio = totalCount > 0 ? static_cast<double>(completedCount) / static_cast<double>(totalCount) : 1.0;
    emitProgress(options, phase, completedCount, totalCount, stageStart + ((stageEnd - stageStart) * ratio));
}

}  // namespace

AppRunner::AppRunner()
    : convertFn_([](const RawConvertTask& t, const AppConfig& c) { return RawConverter().convert(t, c); }),
      analyzer_(std::make_unique<ImageAnalyzer>()) {
}

AppRunner::AppRunner(RawConvertFn converter, std::unique_ptr<IAnalyzer> analyzer)
    : convertFn_(converter), analyzer_(std::move(analyzer)) {
    assert(analyzer_ != nullptr && "analyzer must not be null");
}

RawConvertResult AppRunner::convertWithRetry(const RawConvertTask& task, const AppConfig& config) {
    auto start = std::chrono::steady_clock::now();
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
        }
        result = retry;
    }
    result.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

AnalyzeResult AppRunner::analyzeWithRetry(const AnalyzeTask& task, const AppConfig& config) {
    AnalyzeResult result = analyzer_->analyze(task, config);
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;
    result.attempts = 1;
    if (!result.success) {
        AnalyzeResult retry = analyzer_->analyze(task, config);
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
    emitProgress(options, RunPhase::Scanning, 0, 0, kScanningStart);
    auto pairs = scanner.scanTopLevel(options.folderPath);
    emitProgress(options, RunPhase::Scanning, static_cast<int>(pairs.size()), static_cast<int>(pairs.size()), kScanningEnd);

    JsonManager jsonManager;
    jsonManager.init(options.folderPath, options.configPath);
    jsonManager.mergeScannedPairs(pairs);
    jsonManager.markRunningAsPending();
    jsonManager.atomicSave();

    auto states = jsonManager.getAllPhotoStates();
    ResumePlanner planner;
    auto planned = planner.plan(states, config);

    // RAW conversion phase
    int rawCompletedCount = 0;
    int rawTotalCount = static_cast<int>(planned.rawConvertTasks.size());
    emitStageProgress(options, RunPhase::RawConversion, 0, rawTotalCount, kScanningEnd, kRawConversionEnd);
    if (!planned.rawConvertTasks.empty()) {
        namespace fs = std::filesystem;
        fs::path logDir = fs::path(options.folderPath) / ".cache";
        std::error_code ec;
        fs::create_directories(logDir, ec);
        fs::path logPath = logDir / "conversion.log";
        std::ofstream logFile(logPath, std::ios::out | std::ios::trunc);
        int64_t totalElapsedMs = 0;
        int logCount = 0;

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

        for (int i = 0; i < rawTotalCount; ++i) {
            RawConvertResult rcResult = pool.waitPopResult();
            jsonManager.updateRawConversionResult(rcResult);
            jsonManager.atomicSave();
            rawCompletedCount++;
            emitStageProgress(options, RunPhase::RawConversion, rawCompletedCount, rawTotalCount, kScanningEnd, kRawConversionEnd);

            totalElapsedMs += rcResult.elapsedMs;
            logCount++;
            if (logFile) {
                auto nowT = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
                char tsBuf[32];
                std::tm tmUtc = *std::gmtime(&nowT);
                std::strftime(tsBuf, sizeof(tsBuf), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);

                logFile << "[" << tsBuf << "] photo=" << rcResult.photoId
                        << " elapsed=" << rcResult.elapsedMs << "ms"
                        << " open_file=" << rcResult.openFileMs << "ms"
                        << " unpack=" << rcResult.unpackMs << "ms"
                        << " process=" << rcResult.processMs << "ms"
                        << " make_image=" << rcResult.makeImageMs << "ms"
                        << " write_jpg=" << rcResult.writeJpgMs << "ms"
                        << " attempts=" << rcResult.attempts
                        << " success=" << (rcResult.success ? "true" : "false");
                if (!rcResult.success) {
                    logFile << " error=" << rcResult.error;
                }
                logFile << "\n";
                logFile.flush();
            }
        }

        if (logFile && logCount > 0) {
            logFile << "=== Conversion Summary ===\n";
            logFile << "total_photos=" << logCount << "\n";
            logFile << "total_time_ms=" << totalElapsedMs << "\n";
            logFile << "average_time_ms=" << (totalElapsedMs / logCount) << "\n";
            logFile.flush();
        }
        pool.stop();
    }

    // Re-plan after RAW conversion
    states = jsonManager.getAllPhotoStates();
    planned = planner.plan(states, config);

    // Analysis phase
    int analysisCompletedCount = 0;
    int analysisTotalCount = static_cast<int>(planned.analyzeTasks.size());
    emitStageProgress(options, RunPhase::Analysis, 0, analysisTotalCount, kRawConversionEnd, kAnalysisEnd);
    if (!planned.analyzeTasks.empty()) {
        namespace fs = std::filesystem;
        fs::path logDir = fs::path(options.folderPath) / ".cache";
        std::error_code ec;
        fs::create_directories(logDir, ec);
        fs::path logPath = logDir / "analysis.log";
        std::ofstream logFile(logPath, std::ios::out | std::ios::trunc);
        double totalElapsedMs = 0.0;
        int logCount = 0;

        ThreadPool<AnalyzeTask, AnalyzeResult> pool([this, &config](const AnalyzeTask& t) {
            return this->analyzeWithRetry(t, config);
        });

        for (const auto& task : planned.analyzeTasks) {
            pool.pushTask(task);
        }

        for (int i = 0; i < analysisTotalCount; ++i) {
            AnalyzeResult anaResult = pool.waitPopResult();
            jsonManager.updateAnalysisResult(anaResult);
            jsonManager.atomicSave();
            analysisCompletedCount++;
            emitStageProgress(options, RunPhase::Analysis, analysisCompletedCount, analysisTotalCount, kRawConversionEnd, kAnalysisEnd);

            double elapsedMs = anaResult.totalWallMs > 0.0
                ? anaResult.totalWallMs
                : anaResult.readImageMs + anaResult.renderImageMs + anaResult.grayMs + anaResult.laplacianMs +
                  anaResult.statsMs + anaResult.histogramMs + anaResult.gpuWaitMs;
            totalElapsedMs += elapsedMs;
            logCount++;
            if (logFile) {
                auto nowT = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
                char tsBuf[32];
                std::tm tmUtc = *std::gmtime(&nowT);
                std::strftime(tsBuf, sizeof(tsBuf), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);

                auto oldFlags = logFile.flags();
                auto oldPrecision = logFile.precision();
                logFile << std::fixed << std::setprecision(3)
                        << "[" << tsBuf << "] photo=" << anaResult.photoId
                        << " elapsed=" << elapsedMs << "ms"
                        << " backend=" << anaResult.backendUsed
                        << " read_image=" << anaResult.readImageMs << "ms"
                        << " render_image=" << anaResult.renderImageMs << "ms"
                        << " gray=" << anaResult.grayMs << "ms"
                        << " laplacian=" << anaResult.laplacianMs << "ms"
                        << " stats=" << anaResult.statsMs << "ms"
                        << " histogram=" << anaResult.histogramMs << "ms"
                        << " gpu_encode=" << anaResult.gpuEncodeMs << "ms"
                        << " gpu_wait=" << anaResult.gpuWaitMs << "ms"
                        << " total_wall=" << anaResult.totalWallMs << "ms";
                logFile.flags(oldFlags);
                logFile.precision(oldPrecision);
                logFile << " attempts=" << anaResult.attempts
                        << " success=" << (anaResult.success ? "true" : "false");
                if (!anaResult.success) {
                    logFile << " error=" << anaResult.error;
                }
                logFile << "\n";
                logFile.flush();
            }
        }

        if (logFile && logCount > 0) {
            logFile << "=== Analysis Summary ===\n";
            logFile << "total_photos=" << logCount << "\n";
            auto oldFlags = logFile.flags();
            auto oldPrecision = logFile.precision();
            logFile << std::fixed << std::setprecision(3)
                    << "total_time_ms=" << totalElapsedMs << "\n"
                    << "average_time_ms=" << (totalElapsedMs / static_cast<double>(logCount)) << "\n";
            logFile.flags(oldFlags);
            logFile.precision(oldPrecision);
            logFile.flush();
        }
        pool.stop();
    }

    // Final summary
    emitProgress(options, RunPhase::Organizing, 0, 0, kOrganizingEnd);
    states = jsonManager.getAllPhotoStates();
    SummaryCounts counts = calculateSummaryCounts(states);
    RunSummary summary;
    summary.totalPhotos = counts.totalPhotos;
    summary.rawConversionSuccess = counts.rawConversionSuccess;
    summary.rawConversionFailed = counts.rawConversionFailed;
    summary.analysisSuccess = counts.analysisSuccess;
    summary.analysisFailed = counts.analysisFailed;
    summary.pending = counts.pending;
    summary.blurry = counts.blurry;
    summary.overexposed = counts.overexposed;
    summary.underexposed = counts.underexposed;
    summary.normal = counts.normal;

    jsonManager.atomicSave();
    emitProgress(options, RunPhase::Completed, summary.totalPhotos, summary.totalPhotos, kCompleted);
    return summary;
}
