/*
 * Author: wilbur
 * Version: 1.9
 * Date: 2026-06-10
 * Description: 使用 LibRaw 解码 RAW 文件，通过 ImageIO 写出带 TIFF/EXIF 元信息的 JPG；根据 RAW 扩展名从配置中选择对应参数 profile；支持 .cube 3D LUT 色彩校正
 */

#include "rawConverter.h"
#include "perfTimer.h"
#include "jpgWriter.h"
#include <libraw.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_map>

namespace {

std::string getExtensionLower(const std::string& path) {
    std::filesystem::path p(path);
    std::string ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext;
}

// ---- .cube 3D LUT ----

struct CubeLut {
    int size = 33;
    std::vector<float> data;   // size^3 * 3, R/G/B interleaved
    float domainMin[3] = {0,0,0};
    float domainMax[3] = {1,1,1};
};

// LUT 缓存：同一文件只加载一次
static std::unordered_map<std::string, CubeLut> gLutCache;
static std::mutex gLutCacheMutex;

static bool loadCubeLut(const std::string& path, CubeLut& lut, std::string& error) {
    std::ifstream f(path);
    if (!f) {
        error = "cannot open LUT: " + path;
        return false;
    }

    lut.data.clear();
    lut.size = 33;
    lut.domainMin[0] = lut.domainMin[1] = lut.domainMin[2] = 0.0f;
    lut.domainMax[0] = lut.domainMax[1] = lut.domainMax[2] = 1.0f;

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        size_t start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        line = line.substr(start);

        if (line.rfind("LUT_3D_SIZE", 0) == 0) {
            lut.size = std::stoi(line.substr(11));
        } else if (line.rfind("DOMAIN_MIN", 0) == 0) {
            std::istringstream iss(line.substr(10));
            iss >> lut.domainMin[0] >> lut.domainMin[1] >> lut.domainMin[2];
        } else if (line.rfind("DOMAIN_MAX", 0) == 0) {
            std::istringstream iss(line.substr(10));
            iss >> lut.domainMax[0] >> lut.domainMax[1] >> lut.domainMax[2];
        } else {
            std::istringstream iss(line);
            float r, g, b;
            if (iss >> r >> g >> b) {
                lut.data.push_back(r);
                lut.data.push_back(g);
                lut.data.push_back(b);
            }
        }
    }

    int expectedSize = lut.size * lut.size * lut.size * 3;
    if (static_cast<int>(lut.data.size()) != expectedSize) {
        error = "LUT data mismatch: expected " + std::to_string(expectedSize) +
                " floats, got " + std::to_string(lut.data.size());
        return false;
    }
    return true;
}

static const CubeLut* getOrLoadLut(const std::string& lutPath, std::string& error) {
    std::lock_guard<std::mutex> lock(gLutCacheMutex);
    auto it = gLutCache.find(lutPath);
    if (it != gLutCache.end()) {
        return &it->second;
    }

    CubeLut lut;
    if (!loadCubeLut(lutPath, lut, error)) {
        return nullptr;
    }
    auto& cached = gLutCache[lutPath] = std::move(lut);
    return &cached;
}

// 三线性插值查表
static void lutLookup(const CubeLut& lut, float r, float g, float b,
                       unsigned char& outR, unsigned char& outG, unsigned char& outB) {
    float fx = std::clamp((r - lut.domainMin[0]) / (lut.domainMax[0] - lut.domainMin[0]), 0.0f, 1.0f) * (lut.size - 1);
    float fy = std::clamp((g - lut.domainMin[1]) / (lut.domainMax[1] - lut.domainMin[1]), 0.0f, 1.0f) * (lut.size - 1);
    float fz = std::clamp((b - lut.domainMin[2]) / (lut.domainMax[2] - lut.domainMin[2]), 0.0f, 1.0f) * (lut.size - 1);

    int x0 = static_cast<int>(std::floor(fx));
    int y0 = static_cast<int>(std::floor(fy));
    int z0 = static_cast<int>(std::floor(fz));
    int x1 = std::min(x0 + 1, lut.size - 1);
    int y1 = std::min(y0 + 1, lut.size - 1);
    int z1 = std::min(z0 + 1, lut.size - 1);

    float dx = fx - x0, dy = fy - y0, dz = fz - z0;

    auto sample = [&](int x, int y, int z, int ch) -> float {
        return lut.data[(z * lut.size * lut.size + y * lut.size + x) * 3 + ch];
    };

    auto interp = [&](int ch) -> float {
        float c000 = sample(x0,y0,z0,ch), c001 = sample(x0,y0,z1,ch);
        float c010 = sample(x0,y1,z0,ch), c011 = sample(x0,y1,z1,ch);
        float c100 = sample(x1,y0,z0,ch), c101 = sample(x1,y0,z1,ch);
        float c110 = sample(x1,y1,z0,ch), c111 = sample(x1,y1,z1,ch);
        float c00 = c000*(1-dx) + c100*dx;
        float c01 = c001*(1-dx) + c101*dx;
        float c10 = c010*(1-dx) + c110*dx;
        float c11 = c011*(1-dx) + c111*dx;
        float c0 = c00*(1-dy) + c10*dy;
        float c1 = c01*(1-dy) + c11*dy;
        return c0*(1-dz) + c1*dz;
    };

    outR = static_cast<unsigned char>(std::clamp(interp(0) * 255.0f, 0.0f, 255.0f) + 0.5f);
    outG = static_cast<unsigned char>(std::clamp(interp(1) * 255.0f, 0.0f, 255.0f) + 0.5f);
    outB = static_cast<unsigned char>(std::clamp(interp(2) * 255.0f, 0.0f, 255.0f) + 0.5f);
}

static void applyLut(const CubeLut& lut, unsigned char* data, int totalPixels) {
    for (int i = 0; i < totalPixels; ++i) {
        float r = data[i*3+0] / 255.0f;
        float g = data[i*3+1] / 255.0f;
        float b = data[i*3+2] / 255.0f;
        lutLookup(lut, r, g, b, data[i*3+0], data[i*3+1], data[i*3+2]);
    }
}

}  // namespace

RawConvertResult RawConverter::convert(const RawConvertTask& task, const AppConfig& config) const {
    RawConvertResult result;
    result.photoId = task.photoId;
    result.rawPath = task.rawPath;
    result.jpgPath = task.outputJpgPath;

    if (!std::filesystem::exists(task.rawPath)) {
        result.success = false;
        result.error = "RAW file not found: " + task.rawPath;
        return result;
    }

    std::filesystem::path outDir = std::filesystem::path(task.outputJpgPath).parent_path();
    if (!outDir.empty() && !std::filesystem::exists(outDir)) {
        std::filesystem::create_directories(outDir);
    }

    // 根据扩展名选择参数 profile
    std::string ext = getExtensionLower(task.rawPath);
    const RawProfile& profile = config.rawConversion.getProfile(ext);

    LibRaw rawProcessor;
    PerfTimer phaseTimer;
    int ret = rawProcessor.open_file(task.rawPath.c_str());
    result.openFileMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw open failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    // 通用参数
    rawProcessor.imgdata.params.use_camera_wb = 1;
    rawProcessor.imgdata.params.use_auto_wb = 0;
    rawProcessor.imgdata.params.output_color = 1;
    rawProcessor.imgdata.params.output_bps = 8;
    rawProcessor.imgdata.params.use_camera_matrix = 1;
    rawProcessor.imgdata.params.user_qual = 3;
    rawProcessor.imgdata.params.exp_correc = 0;

    // 从 profile 读取的参数
    rawProcessor.imgdata.params.gamm[0] = profile.gamma0;
    rawProcessor.imgdata.params.gamm[1] = profile.gamma1;
    rawProcessor.imgdata.params.gamm[2] = 0.0;
    rawProcessor.imgdata.params.gamm[3] = 0.0;
    rawProcessor.imgdata.params.gamm[4] = 0.0;
    rawProcessor.imgdata.params.gamm[5] = 0.0;
    rawProcessor.imgdata.params.no_auto_bright = profile.noAutoBright;
    rawProcessor.imgdata.params.bright = profile.bright;

    phaseTimer.reset();
    ret = rawProcessor.unpack();
    result.unpackMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw unpack failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    ret = rawProcessor.dcraw_process();
    result.processMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw process failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    libraw_processed_image_t* img = rawProcessor.dcraw_make_mem_image(&ret);
    result.makeImageMs = phaseTimer.elapsedMs();
    if (!img || ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw make image failed";
        if (img) rawProcessor.dcraw_clear_mem(img);
        return result;
    }

    if (img->bits != 8) {
        result.success = false;
        result.error = "LibRaw output bits mismatch: expected 8, got " + std::to_string(img->bits);
        rawProcessor.dcraw_clear_mem(img);
        return result;
    }

    // 应用 3D LUT（如果配置了）
    if (img->colors == 3 && !profile.lutPath.empty()) {
        std::string lutError;
        const CubeLut* lut = getOrLoadLut(profile.lutPath, lutError);
        if (lut) {
            applyLut(*lut, img->data, img->width * img->height);
        } else {
            // LUT 加载失败不阻塞转换，只记录警告
            std::cerr << "Warning: LUT load failed for " << profile.lutPath
                      << ": " << lutError << std::endl;
        }
    }

    jpgMetadata metadata;
    metadata.quality = config.rawConversion.jpgQuality;
    metadata.timestamp = static_cast<int64_t>(rawProcessor.imgdata.other.timestamp);
    metadata.make = rawProcessor.imgdata.idata.make;
    metadata.model = rawProcessor.imgdata.idata.model;
    metadata.software = rawProcessor.imgdata.idata.software;
    metadata.isoSpeed = rawProcessor.imgdata.other.iso_speed;
    metadata.exposureTime = rawProcessor.imgdata.other.shutter;
    metadata.fNumber = rawProcessor.imgdata.other.aperture;
    metadata.focalLength = rawProcessor.imgdata.other.focal_len;
    metadata.lensModel = rawProcessor.imgdata.lens.Lens;
    if (rawProcessor.imgdata.lens.FocalLengthIn35mmFormat > 0) {
        metadata.focalLength35mm = rawProcessor.imgdata.lens.FocalLengthIn35mmFormat;
    } else if (rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0.0f) {
        metadata.focalLength35mm = static_cast<int>(rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat + 0.5f);
    }
    if (rawProcessor.imgdata.shootinginfo.ExposureProgram > 0) {
        metadata.exposureProgram = rawProcessor.imgdata.shootinginfo.ExposureProgram;
    }
    metadata.flash = rawProcessor.imgdata.color.flash_used > 0.0f ? 1 : 0;
    metadata.hasFlash = true;

    std::string writeError;
    phaseTimer.reset();
    bool written = writeJpgWithImageIo(task.outputJpgPath, img->width, img->height, img->colors, img->data, metadata, writeError);
    result.writeJpgMs = phaseTimer.elapsedMs();
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        result.success = false;
        result.error = "ImageIO write failed: " + writeError;
        return result;
    }

    result.success = true;
    return result;
}
