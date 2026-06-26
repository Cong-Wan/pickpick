/*
Author: wilbur
Version: 1.2
Date: 2026-06-25
Description: LibRaw 极简 ObjC++ 包装, 只做 open + unpack + 返回 Bayer 数据。v1.1 open/unpack 失败时释放 handle 并返回 nullptr；v1.2 填充 LibRaw 错误和可见区域 Bayer pattern
*/

#include "libRawBridge.h"
#include <libraw.h>
#include <string>
#include <cstdio>

struct RawHandle {
    LibRaw processor;
    std::string lastError;
};

static void writeError(char* errorBuffer, int errorBufferSize, const char* message) {
    if (errorBuffer == nullptr || errorBufferSize <= 0) return;
    if (message == nullptr) message = "unknown LibRaw error";
    snprintf(errorBuffer, static_cast<size_t>(errorBufferSize), "%s", message);
}

static int colorCodeForChar(char c) {
    switch (c) {
        case 'R': return 0;
        case 'G': return 1;
        case 'B': return 2;
        default: return 3;
    }
}

void* rwRawOpen(const char* path) {
    return rwRawOpenWithError(path, nullptr, 0);
}

void* rwRawOpenWithError(const char* path, char* errorBuffer, int errorBufferSize) {
    if (path == nullptr) {
        writeError(errorBuffer, errorBufferSize, "path is null");
        return nullptr;
    }

    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        writeError(errorBuffer, errorBufferSize, libraw_strerror(ret));
        delete h;
        return nullptr;
    }

    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        writeError(errorBuffer, errorBufferSize, libraw_strerror(ret));
        delete h;
        return nullptr;
    }

    return h;
}

rwRawBayerData rwRawGetBayerData(void* handle) {
    rwRawBayerData data = {};
    if (handle == nullptr) return data;
    auto* h = static_cast<RawHandle*>(handle);
    auto& sizes = h->processor.imgdata.sizes;
    auto& raw = h->processor.imgdata.rawdata;
    auto& color = h->processor.imgdata.color;
    data.rawImage = raw.raw_image;
    data.rawWidth = sizes.raw_width;
    data.rawHeight = sizes.raw_height;
    data.visibleOffsetX = sizes.left_margin;
    data.visibleOffsetY = sizes.top_margin;
    data.visibleWidth = sizes.width;
    data.visibleHeight = sizes.height;
    data.blackLevel = color.black;
    data.whiteLevel = color.maximum;
    auto& idata = h->processor.imgdata.idata;
    int greenCount = 0;
    for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
            int colorIndex = h->processor.COLOR(data.visibleOffsetY + dy, data.visibleOffsetX + dx);
            char colorChar = idata.cdesc[colorIndex];
            int code = colorCodeForChar(colorChar);
            if (dy == 0 && dx == 0) data.color00 = code;
            if (dy == 0 && dx == 1) data.color01 = code;
            if (dy == 1 && dx == 0) data.color10 = code;
            if (dy == 1 && dx == 1) data.color11 = code;
            if (code == 1) {
                if (greenCount == 0) {
                    data.green1OffsetX = dx;
                    data.green1OffsetY = dy;
                } else if (greenCount == 1) {
                    data.green2OffsetX = dx;
                    data.green2OffsetY = dy;
                }
                greenCount += 1;
            }
        }
    }
    data.greenPixelCount = greenCount;
    return data;
}

const char* rwRawLastError(void* handle) {
    if (handle == nullptr) return "";
    auto* h = static_cast<RawHandle*>(handle);
    return h->lastError.c_str();
}

void rwRawClose(void* handle) {
    delete static_cast<RawHandle*>(handle);
}
