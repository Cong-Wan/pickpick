/*
 * Author: wilbur
 * Version: 3.0
 * Date: 2026-06-01
 * Description: 使用自定义 Metal compute shader 完成 GPU-only JPG 分析；中间灰度和拉普拉斯数据不回传 CPU
 */

#include "macImageAnalyzer.h"
#include "gpuSupport.h"
#include "perfTimer.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#if defined(__APPLE__)
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#endif

namespace {

#if defined(__APPLE__)
constexpr int kHistogramBins = 256;
constexpr int kLaplacianKernelSize = 3;
constexpr NSUInteger kThreadsPerGroup1d = 256;

struct AnalysisConfigGpu {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t totalPixels = 0;
    uint32_t overThreshold = 0;
    uint32_t underThreshold = 0;
};

struct PartialStatsGpu {
    float sum = 0.0f;
    float sumSq = 0.0f;
    float minVal = 0.0f;
    float maxVal = 0.0f;
};

static NSString* shaderPath() {
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* bundled = [bundle pathForResource:@"gpuImageKernels" ofType:@"metal"];
    if (bundled != nil) return bundled;
    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString* cwdPath = [cwd stringByAppendingPathComponent:@"gpuImageKernels.metal"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cwdPath]) return cwdPath;
    NSString* exeDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString* exePath = [exeDir stringByAppendingPathComponent:@"gpuImageKernels.metal"];
    return exePath;
}

static std::string nsErrorMessage(NSError* error) {
    if (error == nil) {
        return "unknown";
    }
    NSString* message = error.localizedDescription ?: error.description ?: @"unknown";
    return std::string([message UTF8String]);
}

static id<MTLComputePipelineState> makePipeline(id<MTLDevice> device,
                                                id<MTLLibrary> library,
                                                NSString* functionName,
                                                std::string& error) {
    id<MTLFunction> function = [library newFunctionWithName:functionName];
    if (function == nil) {
        error = "Failed to load Metal function: " + std::string([functionName UTF8String]);
        return nil;
    }

    NSError* pipelineError = nil;
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&pipelineError];
    if (pipeline == nil) {
        error = "Failed to create Metal pipeline " + std::string([functionName UTF8String]) + ": " + nsErrorMessage(pipelineError);
        return nil;
    }
    return pipeline;
}

static bool fillError(AnalyzeResult& result, const std::string& error) {
    result.success = false;
    result.error = error;
    return false;
}
#endif  // __APPLE__

}  // namespace

AnalyzeResult analyzeWithMacMetal(const AnalyzeTask& task, const AppConfig& config) {
    AnalyzeResult result;
    result.photoId = task.photoId;
    result.jpgPath = task.jpgPath;
    result.backendUsed = "metal";

#if !defined(__APPLE__)
    result.success = false;
    result.error = "Metal analyzer is only available on Apple platforms";
    return result;
#else
    GpuSupport support = getGpuSupport();
    if (!support.hasMetal) {
        result.success = false;
        result.error = support.reason;
        return result;
    }

    @try {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fillError(result, "MTLCreateSystemDefaultDevice returned nil");
            return result;
        }

        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        if (commandQueue == nil) {
            fillError(result, "Failed to create MTLCommandQueue");
            return result;
        }

        CIContext* ciContext = [CIContext contextWithMTLDevice:device options:nil];
        if (ciContext == nil) {
            fillError(result, "Failed to create Metal-backed CIContext");
            return result;
        }

        NSError* sourceError = nil;
        NSString* sourcePath = shaderPath();
        NSString* source = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&sourceError];
        if (source == nil) {
            fillError(result, "Failed to read gpuImageKernels.metal: " + nsErrorMessage(sourceError));
            return result;
        }

        NSError* libraryError = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&libraryError];
        if (library == nil) {
            fillError(result, "Failed to compile gpuImageKernels.metal: " + nsErrorMessage(libraryError));
            return result;
        }

        std::string pipelineError;
        id<MTLComputePipelineState> rgbToGrayPipeline = makePipeline(device, library, @"rgbToGrayKernel", pipelineError);
        if (rgbToGrayPipeline == nil) { fillError(result, pipelineError); return result; }
        id<MTLComputePipelineState> laplacianPipeline = makePipeline(device, library, @"laplacianKernel", pipelineError);
        if (laplacianPipeline == nil) { fillError(result, pipelineError); return result; }
        id<MTLComputePipelineState> histogramPipeline = makePipeline(device, library, @"histogramKernel", pipelineError);
        if (histogramPipeline == nil) { fillError(result, pipelineError); return result; }
        id<MTLComputePipelineState> reducePipeline = makePipeline(device, library, @"reduceLaplacianKernel", pipelineError);
        if (reducePipeline == nil) { fillError(result, pipelineError); return result; }

        PerfTimer phaseTimer;
        NSString* path = [NSString stringWithUTF8String:task.jpgPath.c_str()];
        if (path == nil) {
            fillError(result, "Invalid image path: " + task.jpgPath);
            return result;
        }
        NSURL* url = [NSURL fileURLWithPath:path];
        CIImage* ciImage = [CIImage imageWithContentsOfURL:url];
        result.readImageMs = phaseTimer.elapsedMs();
        if (ciImage == nil) {
            fillError(result, "Core Image failed to read image: " + task.jpgPath);
            return result;
        }

        CGRect extent = [ciImage extent];
        uint32_t width = static_cast<uint32_t>(std::lround(CGRectGetWidth(extent)));
        uint32_t height = static_cast<uint32_t>(std::lround(CGRectGetHeight(extent)));
        if (width == 0 || height == 0) {
            fillError(result, "Metal analyzer received invalid image size: " + task.jpgPath);
            return result;
        }

        uint64_t totalPixels64 = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
        if (totalPixels64 > std::numeric_limits<uint32_t>::max()) {
            fillError(result, "Metal analyzer image is too large: " + task.jpgPath);
            return result;
        }
        uint32_t totalPixels = static_cast<uint32_t>(totalPixels64);
        NSUInteger groupCount = (totalPixels + kThreadsPerGroup1d - 1) / kThreadsPerGroup1d;

        MTLTextureDescriptor* rgbaDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:width height:height mipmapped:NO];
        rgbaDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        rgbaDesc.storageMode = MTLStorageModeShared;
        id<MTLTexture> rgbaTexture = [device newTextureWithDescriptor:rgbaDesc];
        if (rgbaTexture == nil) {
            fillError(result, "Failed to allocate RGBA texture");
            return result;
        }

        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        if (commandBuffer == nil) {
            fillError(result, "Failed to create MTLCommandBuffer");
            return result;
        }

        phaseTimer.reset();
        CGColorSpaceRef rgbaColorSpace = CGColorSpaceCreateDeviceRGB();
        [ciContext render:ciImage
            toMTLTexture:rgbaTexture
           commandBuffer:commandBuffer
                 bounds:CGRectMake(extent.origin.x, extent.origin.y, width, height)
             colorSpace:rgbaColorSpace];
        CGColorSpaceRelease(rgbaColorSpace);
        result.grayMs = phaseTimer.elapsedMs();

        id<MTLBuffer> grayBuffer = [device newBufferWithLength:totalPixels options:MTLResourceStorageModeShared];
        id<MTLBuffer> laplacianBuffer = [device newBufferWithLength:totalPixels * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> histogramBuffer = [device newBufferWithLength:kHistogramBins * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> exposureCountsBuffer = [device newBufferWithLength:2 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> partialStatsBuffer = [device newBufferWithLength:groupCount * sizeof(PartialStatsGpu) options:MTLResourceStorageModeShared];
        id<MTLBuffer> configBuffer = [device newBufferWithLength:sizeof(AnalysisConfigGpu) options:MTLResourceStorageModeShared];
        if (grayBuffer == nil || laplacianBuffer == nil || histogramBuffer == nil ||
            exposureCountsBuffer == nil || partialStatsBuffer == nil || configBuffer == nil) {
            fillError(result, "Failed to allocate Metal analysis buffers");
            return result;
        }

        std::memset([histogramBuffer contents], 0, kHistogramBins * sizeof(uint32_t));
        std::memset([exposureCountsBuffer contents], 0, 2 * sizeof(uint32_t));
        AnalysisConfigGpu gpuConfig;
        gpuConfig.width = width;
        gpuConfig.height = height;
        gpuConfig.totalPixels = totalPixels;
        gpuConfig.overThreshold = static_cast<uint32_t>(config.exposureDetection.overexposePixelThreshold);
        gpuConfig.underThreshold = static_cast<uint32_t>(config.exposureDetection.underexposePixelThreshold);
        std::memcpy([configBuffer contents], &gpuConfig, sizeof(gpuConfig));

        MTLSize threads1d = MTLSizeMake(kThreadsPerGroup1d, 1, 1);
        MTLSize groups1d = MTLSizeMake(groupCount, 1, 1);
        MTLSize threads2d = MTLSizeMake(16, 16, 1);
        MTLSize groups2d = MTLSizeMake((width + 15) / 16, (height + 15) / 16, 1);

        phaseTimer.reset();
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        if (encoder == nil) {
            fillError(result, "Failed to create rgbToGray encoder");
            return result;
        }
        [encoder setComputePipelineState:rgbToGrayPipeline];
        [encoder setTexture:rgbaTexture atIndex:0];
        [encoder setBuffer:grayBuffer offset:0 atIndex:0];
        [encoder setBuffer:configBuffer offset:0 atIndex:1];
        [encoder dispatchThreadgroups:groups2d threadsPerThreadgroup:threads2d];
        [encoder endEncoding];
        result.grayMs += phaseTimer.elapsedMs();

        phaseTimer.reset();
        encoder = [commandBuffer computeCommandEncoder];
        if (encoder == nil) {
            fillError(result, "Failed to create laplacian encoder");
            return result;
        }
        [encoder setComputePipelineState:laplacianPipeline];
        [encoder setBuffer:grayBuffer offset:0 atIndex:0];
        [encoder setBuffer:laplacianBuffer offset:0 atIndex:1];
        [encoder setBuffer:configBuffer offset:0 atIndex:2];
        [encoder dispatchThreadgroups:groups2d threadsPerThreadgroup:threads2d];
        [encoder endEncoding];
        result.laplacianMs = phaseTimer.elapsedMs();

        phaseTimer.reset();
        encoder = [commandBuffer computeCommandEncoder];
        if (encoder == nil) {
            fillError(result, "Failed to create histogram encoder");
            return result;
        }
        [encoder setComputePipelineState:histogramPipeline];
        [encoder setBuffer:grayBuffer offset:0 atIndex:0];
        [encoder setBuffer:histogramBuffer offset:0 atIndex:1];
        [encoder setBuffer:exposureCountsBuffer offset:0 atIndex:2];
        [encoder setBuffer:configBuffer offset:0 atIndex:3];
        [encoder dispatchThreadgroups:groups1d threadsPerThreadgroup:threads1d];
        [encoder endEncoding];
        result.histogramMs = phaseTimer.elapsedMs();

        phaseTimer.reset();
        encoder = [commandBuffer computeCommandEncoder];
        if (encoder == nil) {
            fillError(result, "Failed to create reduce encoder");
            return result;
        }
        [encoder setComputePipelineState:reducePipeline];
        [encoder setBuffer:laplacianBuffer offset:0 atIndex:0];
        [encoder setBuffer:partialStatsBuffer offset:0 atIndex:1];
        [encoder setBuffer:configBuffer offset:0 atIndex:2];
        [encoder dispatchThreadgroups:groups1d threadsPerThreadgroup:threads1d];
        [encoder endEncoding];
        result.statsMs = phaseTimer.elapsedMs();

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status == MTLCommandBufferStatusError) {
            fillError(result, "Metal command buffer failed: " + nsErrorMessage(commandBuffer.error));
            return result;
        }

        const uint32_t* histogram = static_cast<const uint32_t*>([histogramBuffer contents]);
        const uint32_t* exposureCounts = static_cast<const uint32_t*>([exposureCountsBuffer contents]);
        const PartialStatsGpu* partialStats = static_cast<const PartialStatsGpu*>([partialStatsBuffer contents]);

        std::vector<int64_t> bins(kHistogramBins, 0);
        for (int i = 0; i < kHistogramBins; ++i) {
            bins[i] = static_cast<int64_t>(histogram[i]);
        }

        double sum = 0.0;
        double sumSq = 0.0;
        double minVal = std::numeric_limits<double>::infinity();
        double maxVal = -std::numeric_limits<double>::infinity();
        for (NSUInteger i = 0; i < groupCount; ++i) {
            const PartialStatsGpu& s = partialStats[i];
            sum += s.sum;
            sumSq += s.sumSq;
            minVal = std::min(minVal, static_cast<double>(s.minVal));
            maxVal = std::max(maxVal, static_cast<double>(s.maxVal));
        }
        double mean = totalPixels > 0 ? sum / static_cast<double>(totalPixels) : 0.0;
        double variance = totalPixels > 0 ? sumSq / static_cast<double>(totalPixels) - mean * mean : 0.0;
        variance = std::max(0.0, variance);

        int64_t overCount = static_cast<int64_t>(exposureCounts[0]);
        int64_t underCount = static_cast<int64_t>(exposureCounts[1]);
        int64_t totalPixelsResult = static_cast<int64_t>(totalPixels);
        double overRatio = totalPixelsResult > 0 ? static_cast<double>(overCount) / static_cast<double>(totalPixelsResult) : 0.0;
        double underRatio = totalPixelsResult > 0 ? static_cast<double>(underCount) / static_cast<double>(totalPixelsResult) : 0.0;

        std::string exposureStatus = "normal";
        if (overRatio > config.exposureDetection.overexposeRatioLimit) {
            exposureStatus = "overexposed";
        } else if (underRatio > config.exposureDetection.underexposeRatioLimit) {
            exposureStatus = "underexposed";
        }

        result.success = true;
        result.isBlurry = variance < config.blurDetection.laplacianThreshold;
        result.exposureStatus = exposureStatus;
        result.blurConfigSnapshot = config.blurDetection;
        result.exposureConfigSnapshot = config.exposureDetection;
        result.laplacianData.variance = variance;
        result.laplacianData.mean = mean;
        result.laplacianData.stddev = std::sqrt(variance);
        result.laplacianData.min = std::isfinite(minVal) ? minVal : 0.0;
        result.laplacianData.max = std::isfinite(maxVal) ? maxVal : 0.0;
        result.laplacianData.kernelSize = kLaplacianKernelSize;
        result.histogramData.binCount = kHistogramBins;
        result.histogramData.bins = bins;
        result.histogramData.totalPixels = totalPixelsResult;
        result.histogramData.overexposePixelCount = overCount;
        result.histogramData.underexposePixelCount = underCount;
        result.histogramData.overexposeRatio = overRatio;
        result.histogramData.underexposeRatio = underRatio;
        return result;
    } @catch (NSException* ex) {
        NSString* reason = ex.reason ?: @"unknown";
        result.success = false;
        result.error = std::string("Metal analysis threw: ") + [reason UTF8String];
        return result;
    }
#endif
}
