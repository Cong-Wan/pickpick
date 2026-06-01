/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: Metal compute kernels for GPU-only image analysis: grayscale, Laplacian, histogram, exposure counts and reductions
 */

#include <metal_stdlib>
using namespace metal;

struct AnalysisConfigGpu {
    uint width;
    uint height;
    uint totalPixels;
    uint overThreshold;
    uint underThreshold;
};

struct PartialStatsGpu {
    float sum;
    float sumSq;
    float minVal;
    float maxVal;
};

kernel void rgbToGrayKernel(texture2d<float, access::read> rgbaTexture [[texture(0)]],
                            device uchar* grayBuffer [[buffer(0)]],
                            constant AnalysisConfigGpu& config [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= config.width || gid.y >= config.height) {
        return;
    }

    float4 rgba = rgbaTexture.read(gid);
    float grayFloat = rgba.r * 255.0f * 0.299f + rgba.g * 255.0f * 0.587f + rgba.b * 255.0f * 0.114f;
    grayFloat = clamp(grayFloat, 0.0f, 255.0f);
    uchar gray = static_cast<uchar>(grayFloat + 0.5f);
    grayBuffer[gid.y * config.width + gid.x] = gray;
}

kernel void laplacianKernel(device const uchar* grayBuffer [[buffer(0)]],
                            device float* laplacianBuffer [[buffer(1)]],
                            constant AnalysisConfigGpu& config [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= config.width || gid.y >= config.height) {
        return;
    }

    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1;
    uint rightX = x + 1 >= config.width ? config.width - 1 : x + 1;
    uint upY = y == 0 ? 0 : y - 1;
    uint downY = y + 1 >= config.height ? config.height - 1 : y + 1;

    float center = static_cast<float>(grayBuffer[y * config.width + x]);
    float left = static_cast<float>(grayBuffer[y * config.width + leftX]);
    float right = static_cast<float>(grayBuffer[y * config.width + rightX]);
    float up = static_cast<float>(grayBuffer[upY * config.width + x]);
    float down = static_cast<float>(grayBuffer[downY * config.width + x]);

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}

kernel void histogramKernel(device const uchar* grayBuffer [[buffer(0)]],
                            device atomic_uint* histogram [[buffer(1)]],
                            device atomic_uint* exposureCounts [[buffer(2)]],
                            constant AnalysisConfigGpu& config [[buffer(3)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid >= config.totalPixels) {
        return;
    }

    uint gray = static_cast<uint>(grayBuffer[gid]);
    atomic_fetch_add_explicit(&histogram[gray], 1u, memory_order_relaxed);
    if (gray > config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    }
    if (gray < config.underThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
    }
}

kernel void reduceLaplacianKernel(device const float* laplacianBuffer [[buffer(0)]],
                                  device PartialStatsGpu* partialStats [[buffer(1)]],
                                  constant AnalysisConfigGpu& config [[buffer(2)]],
                                  uint tid [[thread_position_in_threadgroup]],
                                  uint groupId [[threadgroup_position_in_grid]],
                                  uint threadsPerGroup [[threads_per_threadgroup]]) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    threadgroup float localMin[256];
    threadgroup float localMax[256];

    uint index = groupId * threadsPerGroup + tid;
    float value = 0.0f;
    bool valid = index < config.totalPixels;
    if (valid) {
        value = laplacianBuffer[index];
    }

    localSum[tid] = valid ? value : 0.0f;
    localSumSq[tid] = valid ? value * value : 0.0f;
    localMin[tid] = valid ? value : INFINITY;
    localMax[tid] = valid ? value : -INFINITY;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = threadsPerGroup / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            localSum[tid] += localSum[tid + stride];
            localSumSq[tid] += localSumSq[tid + stride];
            localMin[tid] = min(localMin[tid], localMin[tid + stride]);
            localMax[tid] = max(localMax[tid], localMax[tid + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partialStats[groupId].sum = localSum[0];
        partialStats[groupId].sumSq = localSumSq[0];
        partialStats[groupId].minVal = localMin[0];
        partialStats[groupId].maxVal = localMax[0];
    }
}
