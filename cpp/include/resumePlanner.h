/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明基于 JSON 状态生成 RAW 转换队列和 JPG 分析队列的接口
 */

#pragma once

#include "taskState.h"
#include <vector>

struct PlannedTasks {
    std::vector<RawConvertTask> rawConvertTasks;
    std::vector<AnalyzeTask> analyzeTasks;
};

class ResumePlanner {
public:
    PlannedTasks plan(const std::vector<PhotoTaskState>& states, const AppConfig& config) const;
};
