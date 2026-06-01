/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 使用 Apple Metal API 检测当前机器是否具备 GPU 图片处理能力
 */

#include "gpuSupport.h"

#if defined(__APPLE__)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#endif

GpuSupport getGpuSupport() {
#if defined(__APPLE__)
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return {false, "", "Metal device is unavailable"};
        }

        NSString* name = [device name];
        return {true, name ? std::string([name UTF8String]) : std::string(), ""};
    }
#else
    return {false, "", "Metal is only available on Apple platforms"};
#endif
}
