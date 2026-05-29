/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明 JPG 分析接口、拉普拉斯统计、直方图统计、分析结果结构
 */

#pragma once

#include "taskState.h"

class ImageAnalyzer {
public:
    AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) const;
};
