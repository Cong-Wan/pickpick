/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 声明 macOS GPU 能力检测结果和 Metal 可用性查询接口
 */

#pragma once

#include <string>

struct GpuSupport {
    bool hasMetal = false;
    std::string deviceName;
    std::string reason;
};

GpuSupport getGpuSupport();
