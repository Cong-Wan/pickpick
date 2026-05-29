/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 扫描顶层 JPG/RW2/CR2，按 stem 配对，不递归
 */

#include "fileScanner.h"
#include <filesystem>
#include <map>
#include <algorithm>
#include <stdexcept>

static bool endsWithIgnoreCase(const std::string& str, const std::string& suffix) {
    if (str.size() < suffix.size()) return false;
    for (size_t i = 0; i < suffix.size(); ++i) {
        if (std::tolower(str[str.size() - suffix.size() + i]) != std::tolower(suffix[i])) {
            return false;
        }
    }
    return true;
}

static bool isJpg(const std::string& filename) {
    return endsWithIgnoreCase(filename, ".jpg") || endsWithIgnoreCase(filename, ".jpeg");
}

static bool isRaw(const std::string& filename) {
    return endsWithIgnoreCase(filename, ".rw2") || endsWithIgnoreCase(filename, ".cr2");
}

std::vector<PhotoPair> FileScanner::scanTopLevel(const std::string& folderPath) const {
    namespace fs = std::filesystem;
    fs::path dir(folderPath);
    if (!fs::exists(dir) || !fs::is_directory(dir)) {
        throw std::runtime_error("Not a directory: " + folderPath);
    }

    std::map<std::string, PhotoPair> pairs;

    for (const auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        std::string filename = entry.path().filename().string();
        std::string stem = entry.path().stem().string();
        std::string fullPath = entry.path().string();

        if (isJpg(filename)) {
            pairs[stem].photoId = stem;
            pairs[stem].jpgPath = fullPath;
            pairs[stem].hasJpg = true;
        } else if (isRaw(filename)) {
            pairs[stem].photoId = stem;
            pairs[stem].rawPath = fullPath;
            pairs[stem].hasRaw = true;
        }
    }

    std::vector<PhotoPair> result;
    for (auto& [stem, pair] : pairs) {
        result.push_back(pair);
    }

    std::sort(result.begin(), result.end(), [](const PhotoPair& a, const PhotoPair& b) {
        return a.photoId < b.photoId;
    });

    return result;
}
