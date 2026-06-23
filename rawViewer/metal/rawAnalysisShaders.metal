/*
Author: wilbur
Version: 1.1
Date: 2026-06-22
Description: RAW/JPG 直方图 + Green/Gray 平面 + Laplacian + 每格统计 kernels。v1.1 新增网格直方图与每格 Laplacian 规约，保留旧全局 reduce 以保证分步构建通过
*/

#include <metal_stdlib>
using namespace metal;

struct BayerHistConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint visibleWidth; uint visibleHeight;
    uint binCount; uint blackLevel; uint whiteLevel;
    uint overThreshold; uint underThreshold;
};

struct GreenPlaneConfig {
    uint rawWidth; uint rawHeight;
    uint visibleOffsetX; uint visibleOffsetY;
    uint greenWidth; uint greenHeight; uint blackLevel;
};

struct GreenLaplacianConfig { uint width; uint height; };

struct RawGridHistConfig {
    uint planeWidth; uint planeHeight;
    uint gridRows; uint gridCols; uint binCount;
    float range; float darkThreshold;
    float deepDarkThreshold; float highlightThreshold;
};

struct JpgGridHistConfig {
    uint planeWidth; uint planeHeight;
    uint gridRows; uint gridCols; uint binCount;
    float darkThreshold; float deepDarkThreshold; float highlightThreshold;
};

struct GridReduceConfig { uint width; uint height; uint gridRows; uint gridCols; };
struct PerTileStats { float sum; float sumSq; };

// 旧全局 reduce 过渡期保留，直到 RAW/JPG analyzer 都不再引用 reducePipeline
struct PartialStats { float sum; float sumSq; float minVal; float maxVal; };

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
    if (rawValue >= config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 0], 1u, memory_order_relaxed);
    if (rawValue <= config.underThreshold && rawValue > 0) atomic_fetch_add_explicit(&exposureCounts[channel * 2 + 1], 1u, memory_order_relaxed);
}

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

kernel void greenLaplacianKernel(
    device const float* greenPlane [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant GreenLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x; uint y = gid.y;
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

// 旧全局 Laplacian 规约：过渡期保留，保证 Task 2 后旧 analyzer 仍可编译运行
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
    bool valid = index < total;
    float value = valid ? laplacianBuffer[index] : 0.0f;
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

// 每格 Laplacian 规约：一个 threadgroup 处理一个 tile
kernel void reduceLaplacianPerTileKernel(
    device const float* laplacianBuffer [[buffer(0)]],
    device PerTileStats* tileStats [[buffer(1)]],
    constant GridReduceConfig& config [[buffer(2)]],
    uint tid [[thread_position_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]],
    uint threadsPerGroup [[threads_per_threadgroup]]
) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    uint tileRow = groupId / config.gridCols;
    uint tileCol = groupId % config.gridCols;
    uint baseTileW = config.width / config.gridCols;
    uint baseTileH = config.height / config.gridRows;
    uint startX = tileCol * baseTileW;
    uint startY = tileRow * baseTileH;
    uint tileW = (tileCol == config.gridCols - 1u) ? (config.width - startX) : baseTileW;
    uint tileH = (tileRow == config.gridRows - 1u) ? (config.height - startY) : baseTileH;
    float sum = 0.0f; float sumSq = 0.0f;
    uint tilePixels = tileW * tileH;
    for (uint idx = tid; idx < tilePixels; idx += threadsPerGroup) {
        uint lx = idx % tileW; uint ly = idx / tileW;
        float v = laplacianBuffer[(startY + ly) * config.width + (startX + lx)];
        sum += v; sumSq += v * v;
    }
    localSum[tid] = sum; localSumSq[tid] = sumSq;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = threadsPerGroup / 2; stride > 0; stride >>= 1) {
        if (tid < stride) { localSum[tid] += localSum[tid + stride]; localSumSq[tid] += localSumSq[tid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) { tileStats[groupId].sum = localSum[0]; tileStats[groupId].sumSq = localSumSq[0]; }
}

// RAW 每格直方图（Green Plane，float，0~range）
kernel void rawGridHistogramKernel(
    device const float* plane [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* counts [[buffer(2)]],
    constant RawGridHistConfig& config [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.planeWidth || gid.y >= config.planeHeight) return;
    uint tileCol = gid.x * config.gridCols / config.planeWidth;
    uint tileRow = gid.y * config.gridRows / config.planeHeight;
    if (tileCol >= config.gridCols) tileCol = config.gridCols - 1u;
    if (tileRow >= config.gridRows) tileRow = config.gridRows - 1u;
    uint tileIdx = tileRow * config.gridCols + tileCol;
    float v = plane[gid.y * config.planeWidth + gid.x];
    uint bin = config.range > 0.0f ? static_cast<uint>(v / config.range * static_cast<float>(config.binCount)) : 0u;
    if (bin >= config.binCount) bin = config.binCount - 1u;
    atomic_fetch_add_explicit(&histogram[tileIdx * config.binCount + bin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&counts[tileIdx * 4u + 0u], 1u, memory_order_relaxed);
    if (v <= config.darkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 1u], 1u, memory_order_relaxed);
    if (v <= config.deepDarkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 2u], 1u, memory_order_relaxed);
    if (v >= config.highlightThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 3u], 1u, memory_order_relaxed);
}

struct JpgHistConfig { uint totalPixels; uint overThreshold; uint underThreshold; };
struct JpgLaplacianConfig { uint width; uint height; };

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
    grayBuffer[gid.y * rgbaTexture.get_width() + gid.x] = static_cast<uchar>(grayFloat + 0.5f);
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
    if (gray > config.overThreshold) atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    if (gray < config.underThreshold) atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
}

kernel void jpgLaplacianKernel(
    device const uchar* grayBuffer [[buffer(0)]],
    device float* laplacianBuffer [[buffer(1)]],
    constant JpgLaplacianConfig& config [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.width || gid.y >= config.height) return;
    uint x = gid.x; uint y = gid.y;
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

// JPG 每格直方图（Gray，uchar，0~255）
kernel void jpgGridHistogramKernel(
    device const uchar* plane [[buffer(0)]],
    device atomic_uint* histogram [[buffer(1)]],
    device atomic_uint* counts [[buffer(2)]],
    constant JpgGridHistConfig& config [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= config.planeWidth || gid.y >= config.planeHeight) return;
    uint tileCol = gid.x * config.gridCols / config.planeWidth;
    uint tileRow = gid.y * config.gridRows / config.planeHeight;
    if (tileCol >= config.gridCols) tileCol = config.gridCols - 1u;
    if (tileRow >= config.gridRows) tileRow = config.gridRows - 1u;
    uint tileIdx = tileRow * config.gridCols + tileCol;
    float v = static_cast<float>(plane[gid.y * config.planeWidth + gid.x]);
    uint bin = static_cast<uint>(v / 255.0f * static_cast<float>(config.binCount));
    if (bin >= config.binCount) bin = config.binCount - 1u;
    atomic_fetch_add_explicit(&histogram[tileIdx * config.binCount + bin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&counts[tileIdx * 4u + 0u], 1u, memory_order_relaxed);
    if (v <= config.darkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 1u], 1u, memory_order_relaxed);
    if (v <= config.deepDarkThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 2u], 1u, memory_order_relaxed);
    if (v >= config.highlightThreshold) atomic_fetch_add_explicit(&counts[tileIdx * 4u + 3u], 1u, memory_order_relaxed);
}
