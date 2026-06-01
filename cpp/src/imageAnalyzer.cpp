/*
 * Author: wilbur
 * Version: 2.0
 * Date: 2026-06-01
 * Description: 使用 macOS Metal GPU-only 路径分析 JPG，不再提供 CPU 或 auto fallback
 */

#include "imageAnalyzer.h"
#include "macImageAnalyzer.h"

AnalyzeResult ImageAnalyzer::analyze(const AnalyzeTask& task, const AppConfig& config) const {
    return analyzeWithMacMetal(task, config);
}
