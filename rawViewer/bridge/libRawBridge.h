/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: LibRaw 最小 C 桥接头, 暴露 open / getBayerData / close。v1.1 补充 rawImage 指针生命周期说明
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
} rwRawBayerData;

void* rwRawOpen(const char* path);
rwRawBayerData rwRawGetBayerData(void* handle);
const char* rwRawLastError(void* handle);
void rwRawClose(void* handle);

#ifdef __cplusplus
}
#endif

#endif
