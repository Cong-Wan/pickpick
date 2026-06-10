/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-10
 * Description: RAW 转 JPG 测试工具，支持读取 .cube 3D LUT 文件对 LibRaw 输出做色彩校正
 *              用法: testRawConvert <input.raw> <output.jpg> [--lut=path.cube]
 */

#include "rawConverter.h"
#include "configLoader.h"
#include "jpgWriter.h"
#include <libraw.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <cstring>
#include <algorithm>
#include <cmath>
#include <vector>

// ---- .cube LUT 加载器 ----

struct CubeLut {
    int size = 33;                    // LUT_3D_SIZE，默认 33
    std::vector<float> data;          // size^3 * 3，R/G/B 交错存储
    float domainMin[3] = {0,0,0};     // DOMAIN_MIN（可选）
    float domainMax[3] = {1,1,1};     // DOMAIN_MAX（可选）

    bool loaded = false;

    // 三线性插值查表
    void lookup(float r, float g, float b, float& outR, float& outG, float& outB) const {
        // 归一化到 [0, size-1]
        float fx = std::clamp((r - domainMin[0]) / (domainMax[0] - domainMin[0]), 0.0f, 1.0f) * (size - 1);
        float fy = std::clamp((g - domainMin[1]) / (domainMax[1] - domainMin[1]), 0.0f, 1.0f) * (size - 1);
        float fz = std::clamp((b - domainMin[2]) / (domainMax[2] - domainMin[2]), 0.0f, 1.0f) * (size - 1);

        int x0 = static_cast<int>(std::floor(fx));
        int y0 = static_cast<int>(std::floor(fy));
        int z0 = static_cast<int>(std::floor(fz));
        int x1 = std::min(x0 + 1, size - 1);
        int y1 = std::min(y0 + 1, size - 1);
        int z1 = std::min(z0 + 1, size - 1);

        float dx = fx - x0, dy = fy - y0, dz = fz - z0;

        // 8 个角的插值
        auto sample = [&](int x, int y, int z, int ch) -> float {
            // .cube 存储: R 快速变化（x），然后 G（y），最后 B（z）
            int idx = (z * size * size + y * size + x) * 3 + ch;
            return data[idx];
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

        outR = interp(0);
        outG = interp(1);
        outB = interp(2);
    }
};

static bool loadCubeLut(const std::string& path, CubeLut& lut, std::string& error) {
    std::ifstream f(path);
    if (!f) {
        error = "cannot open: " + path;
        return false;
    }

    lut.data.clear();
    lut.size = 33;
    lut.domainMin[0] = lut.domainMin[1] = lut.domainMin[2] = 0.0f;
    lut.domainMax[0] = lut.domainMax[1] = lut.domainMax[2] = 1.0f;

    std::string line;
    while (std::getline(f, line)) {
        // 跳过注释和空行
        if (line.empty() || line[0] == '#') continue;

        // 去行首空白
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
            // 数据行: r g b
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

    lut.loaded = true;
    return true;
}

// ---- 主逻辑 ----

static bool parseArg(int argc, char* argv[], const char* prefix, std::string& out) {
    for (int i = 3; i < argc; ++i) {
        if (std::strncmp(argv[i], prefix, std::strlen(prefix)) == 0) {
            out = argv[i] + std::strlen(prefix);
            return true;
        }
    }
    return false;
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::cerr << "Usage: testRawConvert <input.raw> <output.jpg> [--lut=path.cube] [--mode=neutral|lut|embed]" << std::endl;
        std::cerr << "  neutral : LibRaw 中性参数，不做色彩校正" << std::endl;
        std::cerr << "  lut     : LibRaw 中性参数 + .cube LUT 色彩校正" << std::endl;
        std::cerr << "  embed   : 提取相机内嵌 JPEG" << std::endl;
        return 1;
    }

    std::string inputPath = argv[1];
    std::string outputPath = argv[2];
    std::string mode = "lut";
    std::string lutPath;

    parseArg(argc, argv, "--mode=", mode);
    parseArg(argc, argv, "--lut=", lutPath);

    // --- mode=embed ---
    if (mode == "embed") {
        std::cout << "Mode: extract embedded JPEG" << std::endl;
        LibRaw rawProcessor;
        int ret = rawProcessor.open_file(inputPath.c_str());
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "FAIL: " << rawProcessor.strerror(ret) << std::endl;
            return 1;
        }
        if (rawProcessor.imgdata.thumbnail.tlength == 0) {
            std::cerr << "FAIL: no embedded thumbnail" << std::endl;
            return 1;
        }
        std::cout << "  thumb: " << rawProcessor.imgdata.thumbnail.twidth
                  << "x" << rawProcessor.imgdata.thumbnail.theight << std::endl;
        ret = rawProcessor.unpack_thumb();
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "FAIL: " << rawProcessor.strerror(ret) << std::endl;
            return 1;
        }
        int mr = 0;
        libraw_processed_image_t* thumb = rawProcessor.dcraw_make_mem_thumb(&mr);
        if (!thumb || mr != LIBRAW_SUCCESS) {
            std::cerr << "FAIL: make_mem_thumb" << std::endl;
            if (thumb) rawProcessor.dcraw_clear_mem(thumb);
            return 1;
        }
        std::ofstream outFile(outputPath, std::ios::binary);
        outFile.write(reinterpret_cast<const char*>(thumb->data), thumb->data_size);
        outFile.close();
        rawProcessor.dcraw_clear_mem(thumb);
        std::cout << "OK: " << outputPath << std::endl;
        return 0;
    }

    // --- 加载 LUT（如果需要）---
    CubeLut lut;
    if (mode == "lut") {
        if (lutPath.empty()) {
            // 默认在同目录找 rw2.cube
            std::string exeDir = std::filesystem::path(argv[0]).parent_path().string();
            lutPath = exeDir + "/rw2.cube";
        }
        std::string lutError;
        std::cout << "Loading LUT: " << lutPath << std::endl;
        if (!loadCubeLut(lutPath, lut, lutError)) {
            std::cerr << "FAIL: " << lutError << std::endl;
            return 1;
        }
        std::cout << "  LUT size: " << lut.size << " (" << (lut.size*lut.size*lut.size) << " entries)" << std::endl;
    }

    // --- LibRaw 中性参数解码 ---
    std::cout << "Mode: " << mode << std::endl;
    LibRaw rawProcessor;
    int ret = rawProcessor.open_file(inputPath.c_str());
    if (ret != LIBRAW_SUCCESS) {
        std::cerr << "FAIL: " << rawProcessor.strerror(ret) << std::endl;
        return 1;
    }

    std::cout << "  RAW: " << rawProcessor.imgdata.sizes.width
              << "x" << rawProcessor.imgdata.sizes.height << std::endl;

    // 中性参数：不做任何色调处理，作为 LUT 的输入
    rawProcessor.imgdata.params.use_camera_wb = 1;
    rawProcessor.imgdata.params.use_auto_wb = 0;
    rawProcessor.imgdata.params.output_color = 1;   // sRGB
    rawProcessor.imgdata.params.output_bps = 8;
    rawProcessor.imgdata.params.use_camera_matrix = 1;
    rawProcessor.imgdata.params.user_qual = 3;
    rawProcessor.imgdata.params.no_auto_bright = 1;
    rawProcessor.imgdata.params.bright = 1.0f;
    rawProcessor.imgdata.params.exp_correc = 0;
    // 标准 sRGB gamma
    rawProcessor.imgdata.params.gamm[0] = 0.45;
    rawProcessor.imgdata.params.gamm[1] = 4.5;
    rawProcessor.imgdata.params.gamm[2] = 0.0;
    rawProcessor.imgdata.params.gamm[3] = 0.0;
    rawProcessor.imgdata.params.gamm[4] = 0.0;
    rawProcessor.imgdata.params.gamm[5] = 0.0;

    ret = rawProcessor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        std::cerr << "FAIL: unpack: " << rawProcessor.strerror(ret) << std::endl;
        return 1;
    }

    ret = rawProcessor.dcraw_process();
    if (ret != LIBRAW_SUCCESS) {
        std::cerr << "FAIL: process: " << rawProcessor.strerror(ret) << std::endl;
        return 1;
    }

    int mr = 0;
    libraw_processed_image_t* img = rawProcessor.dcraw_make_mem_image(&mr);
    if (!img || mr != LIBRAW_SUCCESS) {
        std::cerr << "FAIL: make image" << std::endl;
        if (img) rawProcessor.dcraw_clear_mem(img);
        return 1;
    }

    std::cout << "  output: " << img->width << "x" << img->height
              << "x" << img->colors << std::endl;

    // --- 应用 LUT ---
    if (mode == "lut" && img->colors == 3) {
        int totalPixels = img->width * img->height;
        std::cout << "  applying LUT to " << totalPixels << " pixels..." << std::flush;
        for (int i = 0; i < totalPixels; ++i) {
            float r = img->data[i*3+0] / 255.0f;
            float g = img->data[i*3+1] / 255.0f;
            float b = img->data[i*3+2] / 255.0f;

            float or_, og, ob;
            lut.lookup(r, g, b, or_, og, ob);

            img->data[i*3+0] = static_cast<unsigned char>(std::clamp(or_ * 255.0f, 0.0f, 255.0f) + 0.5f);
            img->data[i*3+1] = static_cast<unsigned char>(std::clamp(og * 255.0f, 0.0f, 255.0f) + 0.5f);
            img->data[i*3+2] = static_cast<unsigned char>(std::clamp(ob * 255.0f, 0.0f, 255.0f) + 0.5f);
        }
        std::cout << " done" << std::endl;
    }

    // --- 写出 JPG ---
    jpgMetadata metadata;
    metadata.quality = 100;
    metadata.timestamp = static_cast<int64_t>(rawProcessor.imgdata.other.timestamp);
    metadata.make = rawProcessor.imgdata.idata.make;
    metadata.model = rawProcessor.imgdata.idata.model;

    std::string writeError;
    bool written = writeJpgWithImageIo(outputPath, img->width, img->height, img->colors, img->data, metadata, writeError);
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        std::cerr << "FAIL: write: " << writeError << std::endl;
        return 1;
    }

    std::cout << "OK: " << outputPath << std::endl;
    return 0;
}
