/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 声明 macOS 元数据拍摄时间读取结果和读取器，用于 RAW 优先、JPG 兜底写入 JSON 拍摄时间
 */

#pragma once

#include <cstdint>
#include <string>

struct shootingTimeResult {
    bool found = false;
    int64_t epochSeconds = 0;
    std::string isoUtc;
    std::string source = "none";
};

class photoMetadataReader {
public:
    shootingTimeResult readBestShootingTime(const std::string& rawPath, const std::string& jpgPath) const;
    shootingTimeResult readFileShootingTime(const std::string& filePath, const std::string& source) const;
};
