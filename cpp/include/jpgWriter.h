/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 声明 ImageIO JPG 一次性写出接口和可写入的基础 TIFF/EXIF 元信息
 */

#pragma once

#include <cstdint>
#include <string>

struct jpgMetadata {
    int quality = 95;
    int orientation = 1;
    int dpi = 180;
    int64_t timestamp = 0;
    std::string make;
    std::string model;
    std::string software;
    std::string lensModel;
    double isoSpeed = 0.0;
    double exposureTime = 0.0;
    double fNumber = 0.0;
    double focalLength = 0.0;
    int focalLength35mm = 0;
    int exposureProgram = 0;
    int flash = 0;
    bool hasFlash = false;
};

bool writeJpgWithImageIo(const std::string& outputPath,
                         int width,
                         int height,
                         int colors,
                         const void* data,
                         const jpgMetadata& metadata,
                         std::string& error);
