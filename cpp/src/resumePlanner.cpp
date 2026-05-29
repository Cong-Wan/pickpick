/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 实现断点续跑、失败重试、running 回滚、缺 JPG 标记失败的规划逻辑
 */

#include "resumePlanner.h"
#include <filesystem>

PlannedTasks ResumePlanner::plan(const std::vector<PhotoTaskState>& states, const AppConfig& config) const {
    (void)config;
    PlannedTasks planned;
    for (const auto& state : states) {
        // RAW 转换队列规则
        bool needsRawConversion = false;
        if (!state.jpgPath.empty() && !state.rawPath.empty()) {
            // 有原始 JPG，跳过 RAW 转换
            needsRawConversion = false;
        } else if (state.rawPath.empty()) {
            // 无 RAW
            needsRawConversion = false;
        } else if (state.rawConversionStatus == StageStatus::Success || state.rawConversionStatus == StageStatus::Skipped) {
            needsRawConversion = false;
        } else {
            // Pending, Running, Failed
            needsRawConversion = true;
        }

        if (needsRawConversion) {
            RawConvertTask task;
            task.photoId = state.photoId;
            task.rawPath = state.rawPath;
            task.outputJpgPath = std::filesystem::path(state.rawPath).parent_path().string() + "/.cache/converted/" + state.photoId + ".JPG";
            planned.rawConvertTasks.push_back(task);
        }

        // 分析队列规则
        bool needsAnalysis = false;
        if (state.analysisStatus == StageStatus::Success) {
            needsAnalysis = false;
        } else if (state.jpgPath.empty()) {
            needsAnalysis = false;
        } else {
            // Pending, Running, Failed，且 JPG 路径存在
            needsAnalysis = true;
        }

        if (needsAnalysis) {
            AnalyzeTask task;
            task.photoId = state.photoId;
            task.jpgPath = state.jpgPath;
            planned.analyzeTasks.push_back(task);
        }
    }
    return planned;
}
