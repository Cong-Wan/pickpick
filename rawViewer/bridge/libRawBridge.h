/*
Author: wilbur
Version: 1.2
Date: 2026-06-25
Description: LibRaw 最小 C 桥接头, 暴露 open / getBayerData / close。v1.1 补充 rawImage 指针生命周期说明；v1.2 返回可见区域 Bayer pattern 并提供 open 错误输出
*/

#ifndef RAW_VIEWER_LIB_RAW_BRIDGE_H
#define RAW_VIEWER_LIB_RAW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    // rawImage points to LibRaw internal raw_image.
    // It remains valid after rwRawOpen until rwRawClose.
    // Do not call dcraw_process/recycle/clear_mem before Swift copies it.
    const uint16_t* rawImage;
    int rawWidth;
    int rawHeight;
    int visibleOffsetX;
    int visibleOffsetY;
    int visibleWidth;
    int visibleHeight;
    int blackLevel;
    int whiteLevel;
    int color00;
    int color01;
    int color10;
    int color11;
    int green1OffsetX;
    int green1OffsetY;
    int green2OffsetX;
    int green2OffsetY;
    int greenPixelCount;
} rwRawBayerData;

void* rwRawOpen(const char* path);
void* rwRawOpenWithError(const char* path, char* errorBuffer, int errorBufferSize);
rwRawBayerData rwRawGetBayerData(void* handle);
const char* rwRawLastError(void* handle);
void rwRawClose(void* handle);

#ifdef __cplusplus
}
#endif

#endif
