/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 使用 Metal-backed Core Image 渲染图片，并复用共享灰度分析逻辑生成 AnalyzeResult
 */

#include "macImageAnalyzer.h"
#include "gpuSupport.h"
#include "imageAnalysisCore.h"
#include "perfTimer.h"
#include <opencv2/opencv.hpp>
#include <cmath>

#if defined(__APPLE__)
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#endif

AnalyzeResult analyzeWithMacMetal(const AnalyzeTask& task, const AppConfig& config) {
    AnalyzeResult result;
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;
    result.backendUsed = "metal";

#if defined(__APPLE__)
    @autoreleasepool {
        GpuSupport support = getGpuSupport();
        if (!support.hasMetal) {
            result.success = false;
            result.error = support.reason;
            return result;
        }

        PerfTimer phaseTimer;
        NSString* path = [NSString stringWithUTF8String:task.jpgPath.c_str()];
        if (path == nil) {
            result.success = false;
            result.error = "Invalid image path: " + task.jpgPath;
            return result;
        }

        NSURL* url = [NSURL fileURLWithPath:path];
        CIImage* image = [CIImage imageWithContentsOfURL:url];
        result.readImageMs = phaseTimer.elapsedMs();
        if (image == nil) {
            result.success = false;
            result.error = "Core Image failed to read image: " + task.jpgPath;
            return result;
        }

        CGRect extent = [image extent];
        int width = static_cast<int>(std::lround(CGRectGetWidth(extent)));
        int height = static_cast<int>(std::lround(CGRectGetHeight(extent)));
        if (width <= 0 || height <= 0) {
            result.success = false;
            result.error = "Core Image returned invalid image size: " + task.jpgPath;
            return result;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CIContext* context = [CIContext contextWithMTLDevice:device options:nil];
        if (context == nil) {
            result.success = false;
            result.error = "Failed to create Metal-backed Core Image context";
            return result;
        }

        phaseTimer.reset();
        cv::Mat rgba(height, width, CV_8UC4);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        [context render:image
               toBitmap:rgba.data
               rowBytes:rgba.step
                 bounds:CGRectMake(extent.origin.x, extent.origin.y, width, height)
                 format:kCIFormatRGBA8
             colorSpace:colorSpace];
        CGColorSpaceRelease(colorSpace);

        cv::Mat gray;
        cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY);
        result.grayMs = phaseTimer.elapsedMs();

        fillAnalyzeResultFromGray(gray, config, result);
        result.backendUsed = "metal";
        return result;
    }
#else
    result.success = false;
    result.error = "Metal analyzer is only available on Apple platforms";
    return result;
#endif
}
