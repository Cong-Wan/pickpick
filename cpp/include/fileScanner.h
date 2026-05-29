/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明顶层目录扫描接口和 PhotoPair 结构
 */

#pragma once

#include <string>
#include <vector>

struct PhotoPair {
    std::string photoId;
    std::string jpgPath;
    std::string rawPath;
    bool hasJpg = false;
    bool hasRaw = false;
};

class FileScanner {
public:
    std::vector<PhotoPair> scanTopLevel(const std::string& folderPath) const;
};
