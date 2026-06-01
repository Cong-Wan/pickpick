/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 声明 macOS Metal-backed Core Image JPG 分析入口
 */

#pragma once

#include "taskState.h"

AnalyzeResult analyzeWithMacMetal(const AnalyzeTask& task, const AppConfig& config);
