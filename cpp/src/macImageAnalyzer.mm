/*
 * Author: wilbur
 * Version: 3.3
 * Date: 2026-06-02
 * Description: 使用自定义 Metal compute shader 完成 GPU-only JPG 分析；中间灰度和拉普拉斯数据不回传 CPU；记录 wall time、CPU encode 和 GPU wait；macOS 分析主体包入 @autoreleasepool 以释放 autoreleased 临时对象；Metal device/queue/CIContext/library/pipelines 在多次分析间共享同一个 context
 */

#include "macImageAnalyzer.h"
#include "gpuSupport.h"
#include "perfTimer.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

#if defined(__APPLE__)
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
static std::atomic<int> gMetalAnalyzerContextCreateCount{0};
#endif

@interface RawViewerMetalAnalyzerContext : NSObject
@property(nonatomic, strong, readonly) id<MTLDevice> device;
@property(nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong, readonly) CIContext* ciContext;
@property(nonatomic, strong, readonly) id<MTLLibrary> library;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> rgbToGrayPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> laplacianPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> histogramPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> reducePipeline;
- (instancetype)initWithError:(NSString**)errorMessage;
@end
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

static RawViewerMetalAnalyzerContext* sharedMetalAnalyzerContext(std::string& error) {
    static std::mutex mutex;
    static RawViewerMetalAnalyzerContext* context = nil;
    static std::string cachedError;

    std::lock_guard<std::mutex> lock(mutex);
    if (context != nil) {
        return context;
    }
    if (!cachedError.empty()) {
        error = cachedError;
        return nil;
    }

    NSString* errorMessage = nil;
    context = [[RawViewerMetalAnalyzerContext alloc] initWithError:&errorMessage];
    if (context == nil) {
        cachedError = errorMessage != nil ? std::string([errorMessage UTF8String]) : "Failed to create Metal analyzer context";
        error = cachedError;
        return nil;
    }
    return context;
}
#endif  // __APPLE__

}  // namespace

#if defined(__APPLE__)
@implementation RawViewerMetalAnalyzerContext

- (instancetype)initWithError:(NSString**)errorMessage {
    self = [super init];
    if (self == nil) return nil;

    _device = MTLCreateSystemDefaultDevice();
    if (_device == nil) {
        if (errorMessage != nil) *errorMessage = @"MTLCreateSystemDefaultDevice returned nil";
        return nil;
    }

    _commandQueue = [_device newCommandQueue];
    if (_commandQueue == nil) {
        if (errorMessage != nil) *errorMessage = @"Failed to create MTLCommandQueue";
        return nil;
    }

    _ciContext = [CIContext contextWithMTLDevice:_device options:nil];
    if (_ciContext == nil) {
        if (errorMessage != nil) *errorMessage = @"Failed to create Metal-backed CIContext";
        return nil;
    }

    NSError* sourceError = nil;
    NSString* sourcePath = shaderPath();
    NSString* source = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&sourceError];
    if (source == nil) {
        if (errorMessage != nil) {
            *errorMessage = [NSString stringWithFormat:@"Failed to read gpuImageKernels.metal: %@", sourceError.localizedDescription ?: @"unknown"];
        }
        return nil;
    }

    NSError* libraryError = nil;
    _library = [_device newLibraryWithSource:source options:nil error:&libraryError];
    if (_library == nil) {
        if (errorMessage != nil) {
            *errorMessage = [NSString stringWithFormat:@"Failed to compile gpuImageKernels.metal: %@", libraryError.localizedDescription ?: @"unknown"];
        }
        return nil;
    }

    std::string pipelineError;
    _rgbToGrayPipeline = makePipeline(_device, _library, @"rgbToGrayKernel", pipelineError);
    if (_rgbToGrayPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _laplacianPipeline = makePipeline(_device, _library, @"laplacianKernel", pipelineError);
    if (_laplacianPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _histogramPipeline = makePipeline(_device, _library, @"histogramKernel", pipelineError);
    if (_histogramPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _reducePipeline = makePipeline(_device, _library, @"reduceLaplacianKernel", pipelineError);
    if (_reducePipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
    gMetalAnalyzerContextCreateCount.fetch_add(1, std::memory_order_relaxed);
#endif
    return self;
}

@end
#endif  // __APPLE__

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
    PerfTimer totalTimer;
    @autoreleasepool {
        GpuSupport support = getGpuSupport();
        if (!support.hasMetal) {
            result.success = false;
            result.error = support.reason;
            result.totalWallMs = totalTimer.elapsedMs();
            return result;
        }

        @try {
            std::string contextError;
            RawViewerMetalAnalyzerContext* context = sharedMetalAnalyzerContext(contextError);
            if (context == nil) {
                fillError(result, contextError);
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }

            id<MTLDevice> device = context.device;
            id<MTLCommandQueue> commandQueue = context.commandQueue;
            CIContext* ciContext = context.ciContext;
            id<MTLComputePipelineState> rgbToGrayPipeline = context.rgbToGrayPipeline;
            id<MTLComputePipelineState> laplacianPipeline = context.laplacianPipeline;
            id<MTLComputePipelineState> histogramPipeline = context.histogramPipeline;
            id<MTLComputePipelineState> reducePipeline = context.reducePipeline;

            PerfTimer phaseTimer;
            NSString* path = [NSString stringWithUTF8String:task.jpgPath.c_str()];
            if (path == nil) {
                fillError(result, "Invalid image path: " + task.jpgPath);
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }
            NSURL* url = [NSURL fileURLWithPath:path];
            CIImage* ciImage = [CIImage imageWithContentsOfURL:url];
            result.readImageMs = phaseTimer.elapsedMs();
            if (ciImage == nil) {
                fillError(result, "Core Image failed to read image: " + task.jpgPath);
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }

            CGRect extent = [ciImage extent];
            uint32_t width = static_cast<uint32_t>(std::lround(CGRectGetWidth(extent)));
            uint32_t height = static_cast<uint32_t>(std::lround(CGRectGetHeight(extent)));
            if (width == 0 || height == 0) {
                fillError(result, "Metal analyzer received invalid image size: " + task.jpgPath);
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }

            uint64_t totalPixels64 = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
            if (totalPixels64 > std::numeric_limits<uint32_t>::max()) {
                fillError(result, "Metal analyzer image is too large: " + task.jpgPath);
                result.totalWallMs = totalTimer.elapsedMs();
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
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }

            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
            if (commandBuffer == nil) {
                fillError(result, "Failed to create MTLCommandBuffer");
                result.totalWallMs = totalTimer.elapsedMs();
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
            result.renderImageMs = phaseTimer.elapsedMs();

            id<MTLBuffer> grayBuffer = [device newBufferWithLength:totalPixels options:MTLResourceStorageModeShared];
            id<MTLBuffer> laplacianBuffer = [device newBufferWithLength:totalPixels * sizeof(float) options:MTLResourceStorageModeShared];
            id<MTLBuffer> histogramBuffer = [device newBufferWithLength:kHistogramBins * sizeof(uint32_t) options:MTLResourceStorageModeShared];
            id<MTLBuffer> exposureCountsBuffer = [device newBufferWithLength:2 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
            id<MTLBuffer> partialStatsBuffer = [device newBufferWithLength:groupCount * sizeof(PartialStatsGpu) options:MTLResourceStorageModeShared];
            id<MTLBuffer> configBuffer = [device newBufferWithLength:sizeof(AnalysisConfigGpu) options:MTLResourceStorageModeShared];
            if (grayBuffer == nil || laplacianBuffer == nil || histogramBuffer == nil ||
                exposureCountsBuffer == nil || partialStatsBuffer == nil || configBuffer == nil) {
                fillError(result, "Failed to allocate Metal analysis buffers");
                result.totalWallMs = totalTimer.elapsedMs();
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

            int64_t encodeMs = 0;
            phaseTimer.reset();
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            if (encoder == nil) {
                fillError(result, "Failed to create rgbToGray encoder");
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }
            [encoder setComputePipelineState:rgbToGrayPipeline];
            [encoder setTexture:rgbaTexture atIndex:0];
            [encoder setBuffer:grayBuffer offset:0 atIndex:0];
            [encoder setBuffer:configBuffer offset:0 atIndex:1];
            [encoder dispatchThreadgroups:groups2d threadsPerThreadgroup:threads2d];
            [encoder endEncoding];
            result.grayMs = phaseTimer.elapsedMs();
            encodeMs += result.grayMs;

            phaseTimer.reset();
            encoder = [commandBuffer computeCommandEncoder];
            if (encoder == nil) {
                fillError(result, "Failed to create laplacian encoder");
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }
            [encoder setComputePipelineState:laplacianPipeline];
            [encoder setBuffer:grayBuffer offset:0 atIndex:0];
            [encoder setBuffer:laplacianBuffer offset:0 atIndex:1];
            [encoder setBuffer:configBuffer offset:0 atIndex:2];
            [encoder dispatchThreadgroups:groups2d threadsPerThreadgroup:threads2d];
            [encoder endEncoding];
            result.laplacianMs = phaseTimer.elapsedMs();
            encodeMs += result.laplacianMs;

            phaseTimer.reset();
            encoder = [commandBuffer computeCommandEncoder];
            if (encoder == nil) {
                fillError(result, "Failed to create histogram encoder");
                result.totalWallMs = totalTimer.elapsedMs();
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
            encodeMs += result.histogramMs;

            phaseTimer.reset();
            encoder = [commandBuffer computeCommandEncoder];
            if (encoder == nil) {
                fillError(result, "Failed to create reduce encoder");
                result.totalWallMs = totalTimer.elapsedMs();
                return result;
            }
            [encoder setComputePipelineState:reducePipeline];
            [encoder setBuffer:laplacianBuffer offset:0 atIndex:0];
            [encoder setBuffer:partialStatsBuffer offset:0 atIndex:1];
            [encoder setBuffer:configBuffer offset:0 atIndex:2];
            [encoder dispatchThreadgroups:groups1d threadsPerThreadgroup:threads1d];
            [encoder endEncoding];
            result.statsMs = phaseTimer.elapsedMs();
            encodeMs += result.statsMs;

            result.gpuEncodeMs = encodeMs;
            [commandBuffer commit];
            phaseTimer.reset();
            [commandBuffer waitUntilCompleted];
            result.gpuWaitMs = phaseTimer.elapsedMs();
            if (commandBuffer.status == MTLCommandBufferStatusError) {
                fillError(result, "Metal command buffer failed: " + nsErrorMessage(commandBuffer.error));
                result.totalWallMs = totalTimer.elapsedMs();
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
            result.totalWallMs = totalTimer.elapsedMs();
            return result;
        } @catch (NSException* ex) {
            NSString* reason = ex.reason ?: @"unknown";
            result.success = false;
            result.error = std::string("Metal analysis threw: ") + [reason UTF8String];
            result.totalWallMs = totalTimer.elapsedMs();
            return result;
        }
    }
#endif
}

#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
int rawViewerMetalAnalyzerContextCreateCountForTests() {
#if defined(__APPLE__)
    return gMetalAnalyzerContextCreateCount.load(std::memory_order_relaxed);
#else
    return 0;
#endif
}
#endif
