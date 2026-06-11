/*
Author: wilbur
Version: 1.0
Date: 2026-06-10
Description: RAW Bayer 4 通道直方图 + Green plane 提取 + Laplacian + 规约 kernels; JPG 复用 rgbToGray/histogram/laplacian
*/

#include <metal_stdlib>
using namespace metal;

// MARK: - 共享结构体

struct BayerHistConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;
    uint visibleOffsetY;
    uint visibleWidth;
    uint visibleHeight;
    uint binCount;
    uint blackLevel;
    uint whiteLevel;
    uint overThreshold;
    uint underThreshold;
};

struct GreenPlaneConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;
    uint visibleOffsetY;
    uint greenWidth;
    uint greenHeight;
    uint blackLevel;
};

struct GreenLaplacianConfig {
    uint width;
    uint height;
};

struct PartialStats {
    float sum;
    float sumSq;
    float minVal;
    float maxVal;
};

// MARK: - RAW 路径 kernels

// 4 通道 (R/G1/B/G2) 原子直方图, 同时统计过曝/欠曝计数
kernel void bayerHistogramKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
    constant BayerHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint totalVisible = config.visibleWidth * config.visibleHeight;
    if (gid >= totalVisible) return;

    uint localX = gid % config.visibleWidth;
    uint localY = gid / config.visibleWidth;
    uint x = localX + config.visibleOffsetX;
    uint y = localY + config.visibleOffsetY;
    if (x >= config.rawWidth || y >= config.rawHeight) return;

    uint rawValue = static_cast<uint>(rawBuffer[y * config.rawWidth + x]);
    int valueSigned = static_cast<int>(rawValue) - static_cast<int>(config.blackLevel);
    valueSigned = max(0, min(static_cast<int>(config.whiteLevel - config.blackLevel), valueSigned));

    uint channel = ((x & 1) == 0) ? ((y & 1) == 0 ? 0u : 3u) : ((y & 1) == 0 ? 1u : 2u);

    uint bin = config.binCount > 0
        ? static_cast<uint>(valueSigned) * config.binCount / (config.whiteLevel - config.blackLevel + 1u)
        : 0u;
    if (bin >= config.binCount) bin = config.binCount - 1u;

    atomic_fetch_add_explicit(&histogram[channel * config.binCount + bin], 1u, memory_order_relaxed);

    if (rawValue >= config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 0], 1u, memory_order_relaxed);
    }
    if (rawValue <= config.underThreshold && rawValue > 0) {
        atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 1], 1u, memory_order_relaxed);
    }
}

// Bayer 2x2 block -> Green Plane (半分辨率)
kernel void bayerToGreenPlaneKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device float* greenPlane [[buffer(1)]],
    constant GreenPlaneConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.greenWidth || gid.y >= config.greenHeight) return;

    uint baseX = config.visibleOffsetX + gid.x * 2u;
    uint baseY = config.visibleOffsetY + gid.y * 2u;
    if (baseX + 1u >= config.rawWidth || baseY + 1u >= config.rawHeight) return;

    uint g1 = static_cast<uint>(rawBuffer[baseY * config.rawWidth + (baseX + 1u)]);
    uint g2 = static_cast<uint>(rawBuffer[(baseY + 1u) * config.rawWidth + baseX]);

    int g1Signed = static_cast<int>(g1) - static_cast<int>(config.blackLevel);
    int g2Signed = static_cast<int>(g2) - static_cast<int>(config.blackLevel);
    float greenValue = (static_cast<float>(max(0, g1Signed)) + static_cast<float>(max(0, g2Signed))) * 0.5f;

    greenPlane[gid.y * config.greenWidth + gid.x] = greenValue;
}

// Green Plane Laplacian (3x3, 边界 0 填充)
kernel void greenLaplacianKernel(
    device const float* greenPlane [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;

    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1u;
    uint rightX = x + 1u >= config.width ? config.width - 1u : x + 1u;
    uint upY = y == 0 ? 0 : y - 1u;
    uint downY = y + 1u >= config.height ? config.height - 1u : y + 1u;

    float center = greenPlane[y * config.width + x];
    float left = greenPlane[y * config.width + leftX];
    float right = greenPlane[y * config.width + rightX];
    float up = greenPlane[upY * config.width + x];
    float down = greenPlane[downY * config.width + x];

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}

// 并行规约, 256 threads/group
kernel void reduceLaplacianKernel(
    device const float* laplacianBuffer [[buffer(0)]],
    device PartialStats* partialStats [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint tid [[thread_position_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    threadgroup float localMin[256];
    threadgroup float localMax[256];

    uint total = config.width * config.height;
    uint index = groupId * threadsPerGroup + tid;
    float value = 0.0f;
    bool valid = index < total;
    if (valid) { value = laplacianBuffer[index]; }

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

// MARK: - JPG 路径 kernels

struct JpgHistConfig {
    uint totalPixels;
    uint overThreshold;
    uint underThreshold;
};

struct JpgLaplacianConfig {
    uint width;
    uint height;
};

kernel void rgbToGrayKernel(
    texture2d<float, access::read> rgbaTexture [[texture(0)]],
    device uchar* grayBuffer [[buffer(0)]],
    constant uint& totalPixels [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= rgbaTexture.get_width() || gid.y >= rgbaTexture.get_height()) return;
    float4 rgba = rgbaTexture.read(gid);
    float grayFloat = rgba.r * 255.0f * 0.299f + rgba.g * 255.0f * 0.587f + rgba.b * 255.0f * 0.114f;
    grayFloat = clamp(grayFloat, 0.0f, 255.0f);
    uchar gray = static_cast<uchar>(grayFloat + 0.5f);
    grayBuffer[gid.y * rgbaTexture.get_width() + gid.x] = gray;
}

kernel void jpgHistogramKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* exposureCounts [[buffer(2)]],
    constant JpgHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= config.totalPixels) return;
    uint gray = static_cast<uint>(grayBuffer[gid]);
    atomic_fetch_add_explicit(&histogram[gray], 1u, memory_order_relaxed);
    if (gray > config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    }
    if (gray < config.underThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
    }
}

kernel void jpgLaplacianKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant JpgLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1u;
    uint rightX = x + 1u >= config.width ? config.width - 1u : x + 1u;
    uint upY = y == 0 ? 0 : y - 1u;
    uint downY = y + 1u >= config.height ? config.height - 1u : y + 1u;

    float center = static_cast<float>(grayBuffer[y * config.width + x]);
    float left = static_cast<float>(grayBuffer[y * config.width + leftX]);
    float right = static_cast<float>(grayBuffer[y * config.width + rightX]);
    float up = static_cast<float>(grayBuffer[upY * config.width + x]);
    float down = static_cast<float>(grayBuffer[downY * config.width + x]);

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}
