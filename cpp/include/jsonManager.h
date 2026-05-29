/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明 JSON 初始化、读取、合并、更新、summary 计算、原子保存接口
 */

#pragma once

#include "taskState.h"
#include "fileScanner.h"
#include <string>
#include <vector>
#include <memory>

class JsonManager {
public:
    JsonManager();
    ~JsonManager();

    void init(const std::string& folderPath, const std::string& configPath);
    void mergeScannedPairs(const std::vector<PhotoPair>& pairs);
    void markRunningAsPending();
    void updateRawConversionResult(const RawConvertResult& result);
    void updateAnalysisResult(const AnalyzeResult& result);
    std::vector<PhotoTaskState> getAllPhotoStates() const;
    PhotoTaskState getPhotoState(const std::string& photoId) const;
    void atomicSave();
    std::string jsonPath() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
