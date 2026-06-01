/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 实现枚举和状态结构的字符串转换、默认值构造、状态归一化；补充图片处理 backend 字符串转换
 */

#include "taskState.h"
#include <stdexcept>

std::string toString(StageStatus status) {
    switch (status) {
        case StageStatus::Pending: return "pending";
        case StageStatus::Running: return "running";
        case StageStatus::Success: return "success";
        case StageStatus::Failed: return "failed";
        case StageStatus::Skipped: return "skipped";
    }
    return "unknown";
}

std::string toString(FailedStep step) {
    switch (step) {
        case FailedStep::None: return "none";
        case FailedStep::RawConversion: return "raw_conversion";
        case FailedStep::Analysis: return "analysis";
    }
    return "unknown";
}

std::string toString(ImageBackend backend) {
    switch (backend) {
        case ImageBackend::Auto: return "auto";
        case ImageBackend::Cpu: return "cpu";
        case ImageBackend::Metal: return "metal";
    }
    return "unknown";
}

StageStatus stageStatusFromString(const std::string& value) {
    if (value == "pending") return StageStatus::Pending;
    if (value == "running") return StageStatus::Running;
    if (value == "success") return StageStatus::Success;
    if (value == "failed") return StageStatus::Failed;
    if (value == "skipped") return StageStatus::Skipped;
    throw std::invalid_argument("Invalid StageStatus: " + value);
}

FailedStep failedStepFromString(const std::string& value) {
    if (value == "none") return FailedStep::None;
    if (value == "raw_conversion") return FailedStep::RawConversion;
    if (value == "analysis") return FailedStep::Analysis;
    throw std::invalid_argument("Invalid FailedStep: " + value);
}

ImageBackend imageBackendFromString(const std::string& value) {
    if (value == "auto") return ImageBackend::Auto;
    if (value == "cpu") return ImageBackend::Cpu;
    if (value == "metal") return ImageBackend::Metal;
    throw std::invalid_argument("Invalid ImageBackend: " + value);
}

StageStatus normalizeForResume(StageStatus status) {
    if (status == StageStatus::Running) {
        return StageStatus::Pending;
    }
    return status;
}

PhotoTaskState makeDefaultPhotoState(const std::string& photoId) {
    PhotoTaskState state;
    state.photoId = photoId;
    state.rawConversionStatus = StageStatus::Pending;
    state.analysisStatus = StageStatus::Pending;
    state.failedStep = FailedStep::None;
    state.rawConversionAttempts = 0;
    state.analysisAttempts = 0;
    state.histogramBins.resize(256, 0);
    return state;
}
