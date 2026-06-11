/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: LibRaw 极简 ObjC++ 包装, 只做 open + unpack + 返回 Bayer 数据。v1.1 open/unpack 失败时释放 handle 并返回 nullptr
*/

#include "libRawBridge.h"
#include <libraw.h>
#include <string>

struct RawHandle {
    LibRaw processor;
    std::string lastError;
};

void* rwRawOpen(const char* path) {
    if (path == nullptr) return nullptr;

    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        delete h;
        return nullptr;
    }

    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
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
