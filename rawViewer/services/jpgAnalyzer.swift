/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析。v1.2 contextProvider 惰性初始化、maxJpgPixels 保护、encoder guard
*/

import Foundation
import Metal
import CoreImage

// MARK: - Protocol

public protocol jpgAnalyzing: AnyObject {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

// MARK: - GPU 共享结构 (镜像 metal shader)

struct jpgHistConfig {
    var totalPixels: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}

struct jpgLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

// MARK: - Analyzer

public final class jpgAnalyzer: jpgAnalyzing {
    private let contextProvider: () throws -> metalAnalysisContext
    private let maxJpgPixels: Int

    public init(
        contextProvider: @escaping () throws -> metalAnalysisContext = metalAnalysisContext.shared,
        maxJpgPixels: Int = 100_000_000
    ) {
        self.contextProvider = contextProvider
        self.maxJpgPixels = maxJpgPixels
    }

    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        let ciContext = CIContext(mtlDevice: context.device)

        // a. Load CIImage from jpgPath
        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            throw makeError("Failed to load CIImage from \(jpgPath)")
        }

        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else {
            throw makeError("CIImage has zero dimensions")
        }
        let totalPixels = width * height
        guard totalPixels <= maxJpgPixels else {
            throw makeError("JPG too large: \(width)x\(height)")
        }

        // b. Create RGBA8 texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = .shaderRead
        texDesc.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: texDesc) else {
            throw makeError("Failed to create RGBA texture")
        }

        // c. Allocate buffers
        guard let grayBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt8>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc grayBuffer") }

        guard let lapBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }

        guard let histBuffer = context.device.makeBuffer(
            length: 256 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.size)

        guard let exposureBuffer = context.device.makeBuffer(
            length: 2 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)

        // d. Create command buffer
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // e. Render CIImage to texture
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ciImage, to: texture, commandBuffer: cmd, bounds: ciImage.extent, colorSpace: colorSpace)

        // Compute absolute thresholds (0–255 range)
        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)

        // f. Dispatch 1: rgbToGrayPipeline
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.rgbToGrayPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            var totalPx = UInt32(totalPixels)
            encoder.setBytes(&totalPx, length: MemoryLayout<UInt32>.size, index: 1)
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        }

        // g. Dispatch 2: jpgHistogramPipeline
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.jpgHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            var histConfig = jpgHistConfig(
                totalPixels: UInt32(totalPixels),
                overThreshold: absOver,
                underThreshold: absUnder
            )
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
            let histGroupSize = 256
            let histGroupCount = (totalPixels + histGroupSize - 1) / histGroupSize
            encoder.dispatchThreadgroups(
                MTLSize(width: histGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: histGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // h. Dispatch 3: jpgLaplacianPipeline
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.jpgLaplacianPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            var lapConfig = jpgLaplacianConfig(
                width: UInt32(width),
                height: UInt32(height)
            )
            encoder.setBytes(&lapConfig, length: MemoryLayout<jpgLaplacianConfig>.size, index: 2)
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        }

        // i. Dispatch 4: reducePipeline (reuse from rawBayerAnalyzer)
        let reduceGroupSize = 256
        let reduceGroupCount = (totalPixels + reduceGroupSize - 1) / reduceGroupSize
        guard let partialStats = context.device.makeBuffer(
            length: reduceGroupCount * MemoryLayout<partialStatsGpu>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc partialStats") }

        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.reducePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(partialStats, offset: 0, index: 1)
            var greenLapConfig = greenLaplacianConfig(
                width: UInt32(width),
                height: UInt32(height)
            )
            encoder.setBytes(&greenLapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: reduceGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: reduceGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // j. Commit + wait
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // k. CPU: read exposure counts → determine exposureStatus
        let exposurePtr = exposureBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
        let overCount = UInt64(exposurePtr[0])
        let underCount = UInt64(exposurePtr[1])
        let totalPix = UInt64(totalPixels)
        let overRatio = totalPix > 0 ? Double(overCount) / Double(totalPix) : 0
        let underRatio = totalPix > 0 ? Double(underCount) / Double(totalPix) : 0

        let exposureStatus: String
        if overRatio > config.exposure.overexposeRatioLimit {
            exposureStatus = "overexposed"
        } else if underRatio > config.exposure.underexposeRatioLimit {
            exposureStatus = "underexposed"
        } else {
            exposureStatus = "normal"
        }

        // l. CPU: read partialStats → compute variance → determine isBlurry
        let partialPtr = partialStats.contents().bindMemory(to: partialStatsGpu.self, capacity: reduceGroupCount)
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<reduceGroupCount {
            sum += Double(partialPtr[i].sum)
            sumSq += Double(partialPtr[i].sumSq)
        }
        let total = Double(totalPixels)
        let mean = total > 0 ? sum / total : 0
        let variance = total > 0 ? max(0, sumSq / total - mean * mean) : 0
        let isBlurry = variance < config.blur.laplacianThresholdJpg

        // m. CPU: read histogram → compute p01/p999 percentiles → dynamicRangeData
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        let histArray = Array(UnsafeBufferPointer(start: histPtr, count: 256))
        let (p01, p999) = computePercentiles(histogram: histArray, totalPixels: totalPix)

        let sceneSpreadEv = p01 > 0 ? log2(Double(p999) / Double(p01)) : 0
        let codeRangeEv = p01 > 0 ? log2(255.0 / Double(p01)) : 0
        let dr = dynamicRangeData(
            sceneSpreadEv: sceneSpreadEv,
            codeRangeEv: codeRangeEv,
            blackLevel: 0,
            whiteLevel: 255
        )

        // n. Return result
        return rawAnalysisResult(
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            dynamicRange: dr,
            blackLevel: 0,
            whiteLevel: 255,
            analysisSource: "jpg"
        )
    }

    // MARK: - Private helpers

    private func computePercentiles(histogram: [UInt32], totalPixels: UInt64) -> (UInt32, UInt32) {
        guard totalPixels > 0, !histogram.isEmpty else { return (0, 0) }
        let p01Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.001)))
        let p999Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.999)))
        var cum: UInt64 = 0
        var p01Bin: UInt32?
        var p999Bin: UInt32?

        for i in 0..<histogram.count {
            cum += UInt64(histogram[i])
            if p01Bin == nil, cum >= p01Target {
                p01Bin = UInt32(i)
            }
            if p999Bin == nil, cum >= p999Target {
                p999Bin = UInt32(i)
                break
            }
        }

        return (
            p01Bin ?? 0,
            p999Bin ?? UInt32(max(0, histogram.count - 1))
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(
            domain: "rawViewer.jpgAnalyzer", code: 999,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}
