/*
 * Author: wilbur
 * Version: 1.7
 * Date: 2026-06-02
 * Description: 定义状态枚举、照片状态、App review 状态、配置结构、任务结构、结果结构、字符串转换函数、共享 summary counts 结构；分析结果时间字段改为 double 毫秒以支持亚毫秒精度
 */

#pragma once

#include <string>
#include <vector>
#include <cstdint>

enum class StageStatus {
    Pending,
    Running,
    Success,
    Failed,
    Skipped
};

enum class FailedStep {
    None,
    RawConversion,
    Analysis
};

enum class ImageBackend {
    Auto,
    Cpu,
    Metal
};

enum class ReviewStatus {
    Active,
    Kept,
    Passed,
    Trashed
};

struct BlurDetectionConfig {
    double laplacianThreshold = 100.0;
    int laplacianKernelSize = 3;
};

struct ExposureDetectionConfig {
    int overexposePixelThreshold = 245;
    int underexposePixelThreshold = 10;
    double overexposeRatioLimit = 0.05;
    double underexposeRatioLimit = 0.05;
};

struct RawConversionConfig {
    int jpgQuality = 95;
};

struct ThreadPoolConfig {
    int workerCount = 4;
};

struct ImageProcessingConfig {
    ImageBackend analysisBackend = ImageBackend::Metal;
    ImageBackend rawBackend = ImageBackend::Metal;
    bool logBackend = true;
};

struct AppConfig {
    BlurDetectionConfig blurDetection;
    ExposureDetectionConfig exposureDetection;
    RawConversionConfig rawConversion;
    ThreadPoolConfig threadPool;
    ImageProcessingConfig imageProcessing;
    int effectiveWorkerCount = 4;
};

struct PhotoTaskState {
    std::string photoId;
    std::string jpgPath;
    std::string rawPath;
    bool rawConverted = false;

    StageStatus rawConversionStatus = StageStatus::Pending;
    StageStatus analysisStatus = StageStatus::Pending;
    FailedStep failedStep = FailedStep::None;

    int rawConversionAttempts = 0;
    int analysisAttempts = 0;
    std::string rawConversionError;
    std::string analysisError;

    bool isBlurry = false;
    double laplacianVariance = 0.0;
    double laplacianMean = 0.0;
    double laplacianStddev = 0.0;
    double laplacianMin = 0.0;
    double laplacianMax = 0.0;
    int laplacianKernelSize = 3;
    double blurThreshold = 100.0;

    std::string exposureStatus = "normal";
    std::vector<int64_t> histogramBins;
    int64_t totalPixels = 0;
    int64_t overexposePixelCount = 0;
    int64_t underexposePixelCount = 0;
    double histOverexposeRatio = 0.0;
    double histUnderexposeRatio = 0.0;
    int overexposePixelThreshold = 245;
    int underexposePixelThreshold = 10;
    double overexposeRatioLimit = 0.05;
    double underexposeRatioLimit = 0.05;

    std::string createdAt;
    std::string updatedAt;

    ReviewStatus reviewStatus = ReviewStatus::Active;
    std::string reviewGroupId;
    std::string templatePhotoId;
    std::string trashedAt;
};

struct RawConvertTask {
    std::string photoId;
    std::string rawPath;
    std::string outputJpgPath;
};

struct RawConvertResult {
    bool success = false;
    std::string photoId;
    std::string rawPath;
    std::string jpgPath;
    int attempts = 0;
    std::string error;
    int64_t elapsedMs = 0;
    int64_t openFileMs = 0;
    int64_t unpackMs = 0;
    int64_t processMs = 0;
    int64_t makeImageMs = 0;
    int64_t writeJpgMs = 0;
};

struct AnalyzeTask {
    std::string photoId;
    std::string jpgPath;
};

struct AnalyzeResult {
    bool success = false;
    std::string photoId;
    std::string jpgPath;
    int attempts = 0;
    std::string error;
    std::string backendUsed = "metal";
    double readImageMs = 0.0;
    double grayMs = 0.0;
    double laplacianMs = 0.0;
    double statsMs = 0.0;
    double histogramMs = 0.0;
    double renderImageMs = 0.0;
    double gpuEncodeMs = 0.0;
    double gpuWaitMs = 0.0;
    double totalWallMs = 0.0;

    bool isBlurry = false;
    std::string exposureStatus = "normal";

    // config snapshot
    BlurDetectionConfig blurConfigSnapshot;
    ExposureDetectionConfig exposureConfigSnapshot;

    // raw data
    struct LaplacianData {
        double variance = 0.0;
        double mean = 0.0;
        double stddev = 0.0;
        double min = 0.0;
        double max = 0.0;
        int kernelSize = 3;
    } laplacianData;

    struct HistogramData {
        int binCount = 256;
        std::vector<int64_t> bins;
        int64_t totalPixels = 0;
        int64_t overexposePixelCount = 0;
        int64_t underexposePixelCount = 0;
        double overexposeRatio = 0.0;
        double underexposeRatio = 0.0;
    } histogramData;
};

std::string toString(StageStatus status);
std::string toString(FailedStep step);
std::string toString(ImageBackend backend);
std::string toString(ReviewStatus status);
StageStatus stageStatusFromString(const std::string& value);
FailedStep failedStepFromString(const std::string& value);
ImageBackend imageBackendFromString(const std::string& value);
ReviewStatus reviewStatusFromString(const std::string& value);
StageStatus normalizeForResume(StageStatus status);
struct SummaryCounts {
    int totalPhotos = 0;
    int rawConversionSuccess = 0;
    int rawConversionFailed = 0;
    int analysisSuccess = 0;
    int analysisFailed = 0;
    int pending = 0;
    int blurry = 0;
    int overexposed = 0;
    int underexposed = 0;
    int normal = 0;
};

SummaryCounts calculateSummaryCounts(const std::vector<PhotoTaskState>& states);

PhotoTaskState makeDefaultPhotoState(const std::string& photoId);
