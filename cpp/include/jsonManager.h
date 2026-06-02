/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 声明 JSON 初始化、读取、合并、分析更新、App review 更新、summary 计算、原子保存接口
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
    void updateReviewStatus(const std::string& photoId, ReviewStatus status, const std::string& trashedAt);
    void updateDuplicateTemplate(const std::string& reviewGroupId, const std::string& templatePhotoId);
    std::vector<PhotoTaskState> getAllPhotoStates() const;
    PhotoTaskState getPhotoState(const std::string& photoId) const;
    void atomicSave();
    std::string jsonPath() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
