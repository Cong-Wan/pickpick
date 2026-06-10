/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-09
 * Description: IAnalyzer 纯虚接口，定义图片分析契约
 */

#pragma once
#include "taskState.h"

class IAnalyzer {
public:
    virtual ~IAnalyzer() = default;
    virtual AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) = 0;
};