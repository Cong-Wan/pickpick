/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-02
 * Description: 声明 macOS Metal-backed Core Image JPG 分析入口；增加 Metal context 复用诊断接口
 */

#pragma once

#include "taskState.h"

AnalyzeResult analyzeWithMacMetal(const AnalyzeTask& task, const AppConfig& config);

#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
int rawViewerMetalAnalyzerContextCreateCountForTests();
#endif
