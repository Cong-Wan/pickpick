/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-09
 * Description: 声明 JPG 分析接口；实现 IAnalyzer 纯虚接口
 */

#pragma once

#include "iAnalyzer.h"

class ImageAnalyzer : public IAnalyzer {
public:
    AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) override;
};
