/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-01
 * Description: 实现 .cache/analysis.json 的完整读写、临时文件 rename 覆盖，并记录分析 backend
 */

#include "jsonManager.h"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <chrono>
#include <ctime>

using json = nlohmann::json;

static std::string utcNow() {
    auto now = std::chrono::system_clock::now();
    auto timeT = std::chrono::system_clock::to_time_t(now);
    std::tm tm = *std::gmtime(&timeT);
    char buf[64];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

static json configToJson(const BlurDetectionConfig& blur, const ExposureDetectionConfig& exp) {
    json j;
    j["blur_detection"]["laplacian_threshold"] = blur.laplacianThreshold;
    j["blur_detection"]["laplacian_kernel_size"] = blur.laplacianKernelSize;
    j["exposure_detection"]["overexpose_pixel_threshold"] = exp.overexposePixelThreshold;
    j["exposure_detection"]["underexpose_pixel_threshold"] = exp.underexposePixelThreshold;
    j["exposure_detection"]["overexpose_ratio_limit"] = exp.overexposeRatioLimit;
    j["exposure_detection"]["underexpose_ratio_limit"] = exp.underexposeRatioLimit;
    return j;
}

class JsonManager::Impl {
public:
    std::string folderPath_;
    std::string configPath_;
    json root_;
    bool initialized_ = false;

    void ensureInit() const {
        if (!initialized_) throw std::runtime_error("JsonManager not initialized");
    }

    json& photo(const std::string& photoId) {
        return root_["photos"][photoId];
    }

    void updateSummary() {
        auto& sum = root_["summary"];
        int total = 0, rawSucc = 0, rawFail = 0, anaSucc = 0, anaFail = 0, pending = 0, blurry = 0, over = 0, under = 0, normal = 0;
        for (auto& [key, val] : root_["photos"].items()) {
            total++;
            std::string rs = (val.contains("raw_conversion_status") && !val["raw_conversion_status"].is_null()) ? val["raw_conversion_status"].get<std::string>() : "pending";
            std::string as = (val.contains("analysis_status") && !val["analysis_status"].is_null()) ? val["analysis_status"].get<std::string>() : "pending";
            if (rs == "success") rawSucc++;
            if (rs == "failed") rawFail++;
            if (as == "success") {
                anaSucc++;
                std::string es = (val.contains("exposure_status") && !val["exposure_status"].is_null()) ? val["exposure_status"].get<std::string>() : "normal";
                if (es == "overexposed") over++;
                else if (es == "underexposed") under++;
                else normal++;
                bool blurryFlag = (val.contains("is_blurry") && !val["is_blurry"].is_null()) ? val["is_blurry"].get<bool>() : false;
                if (blurryFlag) blurry++;
            }
            if (as == "failed") anaFail++;
            if (rs == "pending" || rs == "running" || as == "pending" || as == "running") pending++;
        }
        sum["total_photos"] = total;
        sum["raw_conversion_success"] = rawSucc;
        sum["raw_conversion_failed"] = rawFail;
        sum["analysis_success"] = anaSucc;
        sum["analysis_failed"] = anaFail;
        sum["pending"] = pending;
        sum["blurry"] = blurry;
        sum["overexposed"] = over;
        sum["underexposed"] = under;
        sum["normal"] = normal;
    }
};

JsonManager::JsonManager() : impl_(std::make_unique<Impl>()) {}
JsonManager::~JsonManager() = default;

void JsonManager::init(const std::string& folderPath, const std::string& configPath) {
    impl_->folderPath_ = folderPath;
    impl_->configPath_ = configPath;
    namespace fs = std::filesystem;
    fs::path cacheDir = fs::path(folderPath) / ".cache";
    fs::path jsonFile = cacheDir / "analysis.json";

    if (fs::exists(jsonFile)) {
        std::ifstream ifs(jsonFile);
        if (ifs) {
            ifs >> impl_->root_;
        }
    }

    if (!impl_->root_.contains("schema_version")) {
        impl_->root_ = json::object();
        impl_->root_["schema_version"] = "1.3";
        impl_->root_["folder_path"] = folderPath;
        impl_->root_["config_path"] = configPath;
        impl_->root_["created_at"] = utcNow();
        impl_->root_["max_workers"] = 4;
        impl_->root_["summary"] = json::object();
        impl_->root_["photos"] = json::object();
    }

    impl_->root_["folder_path"] = folderPath;
    impl_->root_["config_path"] = configPath;
    impl_->initialized_ = true;
}

void JsonManager::mergeScannedPairs(const std::vector<PhotoPair>& pairs) {
    impl_->ensureInit();
    for (const auto& pair : pairs) {
        auto& p = impl_->photo(pair.photoId);
        if (!p.contains("photo_id")) {
            p["photo_id"] = pair.photoId;
            p["raw_conversion_status"] = pair.hasRaw && !pair.hasJpg ? "pending" : "skipped";
            p["analysis_status"] = "pending";
            p["failed_step"] = "none";
            p["raw_conversion_attempts"] = 0;
            p["analysis_attempts"] = 0;
            p["raw_conversion_error"] = nullptr;
            p["analysis_error"] = nullptr;
            p["is_blurry"] = nullptr;
            p["exposure_status"] = nullptr;
            p["analysis_config_snapshot"] = nullptr;
            p["analysis_raw_data"] = nullptr;
            p["raw_converted"] = false;
            p["created_at"] = utcNow();
        }
        // Update paths
        if (pair.hasJpg) {
            p["file_name"] = std::filesystem::path(pair.jpgPath).filename().string();
            p["file_path"] = pair.jpgPath;
        }
        if (pair.hasRaw) {
            p["raw_file_name"] = std::filesystem::path(pair.rawPath).filename().string();
            p["raw_file_path"] = pair.rawPath;
        }
        p["updated_at"] = utcNow();
    }
    impl_->updateSummary();
}

void JsonManager::markRunningAsPending() {
    impl_->ensureInit();
    for (auto& [key, val] : impl_->root_["photos"].items()) {
        std::string rcs = (val.contains("raw_conversion_status") && !val["raw_conversion_status"].is_null()) ? val["raw_conversion_status"].get<std::string>() : "";
        if (rcs == "running") {
            val["raw_conversion_status"] = "pending";
        }
        std::string ans = (val.contains("analysis_status") && !val["analysis_status"].is_null()) ? val["analysis_status"].get<std::string>() : "";
        if (ans == "running") {
            val["analysis_status"] = "pending";
        }
    }
    impl_->updateSummary();
}

void JsonManager::updateRawConversionResult(const RawConvertResult& result) {
    impl_->ensureInit();
    auto& p = impl_->photo(result.photoId);
    if (result.success) {
        p["raw_conversion_status"] = "success";
        p["raw_converted"] = true;
        p["file_path"] = result.jpgPath;
        p["file_name"] = std::filesystem::path(result.jpgPath).filename().string();
        p["failed_step"] = "none";
        p["raw_conversion_error"] = nullptr;
    } else {
        p["raw_conversion_status"] = "failed";
        p["failed_step"] = "raw_conversion";
        p["raw_conversion_error"] = result.error;
    }
    p["raw_conversion_attempts"] = result.attempts;
    p["updated_at"] = utcNow();
    impl_->updateSummary();
}

void JsonManager::updateAnalysisResult(const AnalyzeResult& result) {
    impl_->ensureInit();
    auto& p = impl_->photo(result.photoId);
    if (result.success) {
        p["analysis_status"] = "success";
        p["analysis_backend"] = result.backendUsed;
        p["failed_step"] = "none";
        p["is_blurry"] = result.isBlurry;
        p["exposure_status"] = result.exposureStatus;
        p["analysis_config_snapshot"] = configToJson(result.blurConfigSnapshot, result.exposureConfigSnapshot);
        json rawData;
        rawData["laplacian"]["variance"] = result.laplacianData.variance;
        rawData["laplacian"]["mean"] = result.laplacianData.mean;
        rawData["laplacian"]["stddev"] = result.laplacianData.stddev;
        rawData["laplacian"]["min"] = result.laplacianData.min;
        rawData["laplacian"]["max"] = result.laplacianData.max;
        rawData["laplacian"]["kernel_size"] = result.laplacianData.kernelSize;
        rawData["histogram"]["bin_count"] = result.histogramData.binCount;
        rawData["histogram"]["bins"] = result.histogramData.bins;
        rawData["histogram"]["total_pixels"] = result.histogramData.totalPixels;
        rawData["histogram"]["overexpose_pixel_count"] = result.histogramData.overexposePixelCount;
        rawData["histogram"]["underexpose_pixel_count"] = result.histogramData.underexposePixelCount;
        rawData["histogram"]["overexpose_ratio"] = result.histogramData.overexposeRatio;
        rawData["histogram"]["underexpose_ratio"] = result.histogramData.underexposeRatio;
        p["analysis_raw_data"] = rawData;
        p["analysis_error"] = nullptr;
    } else {
        p["analysis_status"] = "failed";
        p["analysis_backend"] = result.backendUsed;
        p["failed_step"] = "analysis";
        p["analysis_error"] = result.error;
    }
    p["analysis_attempts"] = result.attempts;
    p["updated_at"] = utcNow();
    impl_->updateSummary();
}

std::vector<PhotoTaskState> JsonManager::getAllPhotoStates() const {
    impl_->ensureInit();
    std::vector<PhotoTaskState> states;
    for (auto& [key, val] : impl_->root_["photos"].items()) {
        PhotoTaskState state;
        state.photoId = val.value("photo_id", std::string(key));
        state.jpgPath = (val.contains("file_path") && !val["file_path"].is_null()) ? val["file_path"].get<std::string>() : "";
        state.rawPath = (val.contains("raw_file_path") && !val["raw_file_path"].is_null()) ? val["raw_file_path"].get<std::string>() : "";
        state.rawConverted = val.value("raw_converted", false);
        state.rawConversionStatus = stageStatusFromString((val.contains("raw_conversion_status") && !val["raw_conversion_status"].is_null()) ? val["raw_conversion_status"].get<std::string>() : "pending");
        state.analysisStatus = stageStatusFromString((val.contains("analysis_status") && !val["analysis_status"].is_null()) ? val["analysis_status"].get<std::string>() : "pending");
        state.failedStep = failedStepFromString((val.contains("failed_step") && !val["failed_step"].is_null()) ? val["failed_step"].get<std::string>() : "none");
        state.rawConversionAttempts = val.value("raw_conversion_attempts", 0);
        state.analysisAttempts = val.value("analysis_attempts", 0);
        state.rawConversionError = (val.contains("raw_conversion_error") && !val["raw_conversion_error"].is_null()) ? val["raw_conversion_error"].get<std::string>() : "";
        state.analysisError = (val.contains("analysis_error") && !val["analysis_error"].is_null()) ? val["analysis_error"].get<std::string>() : "";
        state.isBlurry = (val.contains("is_blurry") && !val["is_blurry"].is_null()) ? val["is_blurry"].get<bool>() : false;
        state.exposureStatus = (val.contains("exposure_status") && !val["exposure_status"].is_null()) ? val["exposure_status"].get<std::string>() : "normal";
        state.createdAt = (val.contains("created_at") && !val["created_at"].is_null()) ? val["created_at"].get<std::string>() : "";
        state.updatedAt = (val.contains("updated_at") && !val["updated_at"].is_null()) ? val["updated_at"].get<std::string>() : "";
        if (val.contains("analysis_raw_data") && !val["analysis_raw_data"].is_null()) {
            auto& rd = val["analysis_raw_data"];
            if (rd.contains("histogram") && rd["histogram"].contains("bins")) {
                state.histogramBins = rd["histogram"]["bins"].get<std::vector<int64_t>>();
            }
        }
        if (state.histogramBins.empty()) {
            state.histogramBins.resize(256, 0);
        }
        states.push_back(state);
    }
    return states;
}

PhotoTaskState JsonManager::getPhotoState(const std::string& photoId) const {
    impl_->ensureInit();
    auto& p = impl_->root_["photos"];
    if (!p.contains(photoId)) {
        return PhotoTaskState{};
    }
    auto states = getAllPhotoStates();
    for (auto& s : states) {
        if (s.photoId == photoId) return s;
    }
    return PhotoTaskState{};
}

void JsonManager::atomicSave() {
    impl_->ensureInit();
    namespace fs = std::filesystem;
    fs::path cacheDir = fs::path(impl_->folderPath_) / ".cache";
    fs::create_directories(cacheDir);
    fs::path finalPath = cacheDir / "analysis.json";
    fs::path tmpPath = cacheDir / "analysis.json.tmp";

    impl_->root_["updated_at"] = utcNow();

    {
        std::ofstream ofs(tmpPath, std::ios::binary);
        if (!ofs) {
            throw std::runtime_error("Failed to write temp JSON: " + tmpPath.string());
        }
        ofs << impl_->root_.dump(2);
        ofs.flush();
    }

    fs::rename(tmpPath, finalPath);
}

std::string JsonManager::jsonPath() const {
    impl_->ensureInit();
    return (std::filesystem::path(impl_->folderPath_) / ".cache" / "analysis.json").string();
}
