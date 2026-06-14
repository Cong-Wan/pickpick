/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: RAW Bayer 原始值分析: LibRaw 取数据, Metal GPU 4 个 kernel, CPU 后处理曝光/虚焦/DR。v1.4 让 contextProvider 可从后台分析任务调用并标注 task group 捕获安全
*/

import Foundation
import Metal

nonisolated public struct rawAnalysisResult: Sendable {
    public let isBlurry: Bool
    public let exposureStatus: String
    public let dynamicRange: dynamicRangeData?
    public let blackLevel: Int
    public let whiteLevel: Int
    public let analysisSource: String

    public init(
        isBlurry: Bool,
        exposureStatus: String,
        dynamicRange: dynamicRangeData?,
        blackLevel: Int,
        whiteLevel: Int,
        analysisSource: String = "raw"
    ) {
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.dynamicRange = dynamicRange
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.analysisSource = analysisSource
    }
}

nonisolated public protocol rawBayerAnalyzing: AnyObject, Sendable {
    func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

// MARK: - GPU 共享结构 (镜像 metal shader)

struct bayerHistConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var visibleWidth: UInt32
    var visibleHeight: UInt32
    var binCount: UInt32
    var blackLevel: UInt32
    var whiteLevel: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}

struct greenPlaneConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var greenWidth: UInt32
    var greenHeight: UInt32
    var blackLevel: UInt32
}

struct greenLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

struct partialStatsGpu {
    var sum: Float
    var sumSq: Float
    var minVal: Float
    var maxVal: Float
}

nonisolated public final class rawBayerAnalyzer: rawBayerAnalyzing, @unchecked Sendable {
    private let contextProvider: @Sendable () throws -> metalAnalysisContext

    public init(contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() }) {
        self.contextProvider = contextProvider
    }

    public func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        guard let handle = rwRawOpen(rawPath) else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw open_file returned null for \(rawPath)"]
            )
        }
        defer { rwRawClose(handle) }

        let errorMsg = String(cString: rwRawLastError(handle))
        if !errorMsg.isEmpty {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw error: \(errorMsg)"]
            )
        }

        let data = rwRawGetBayerData(handle)
        guard data.rawWidth > 0, data.rawHeight > 0, data.rawImage != nil else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LibRaw returned empty Bayer data"]
            )
        }

        let black = Int(data.blackLevel)
        let white = Int(data.whiteLevel)
        guard white > black else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid black/white level: black=\(black) white=\(white)"]
            )
        }

        let visibleW = Int(data.visibleWidth)
        let visibleH = Int(data.visibleHeight)
        let rawW = Int(data.rawWidth)
        let rawH = Int(data.rawHeight)

        // 1. 上传 rawImage 到 GPU
        let totalRaw = rawW * rawH
        guard let rawBuffer = context.device.makeBuffer(
            length: totalRaw * MemoryLayout<UInt16>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, totalRaw * MemoryLayout<UInt16>.size)

        // 2. 计算绝对阈值
        let absOver = UInt32(black) + UInt32(Double(white - black) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(black) + UInt32(Double(white - black) * config.exposure.underexposePixelThreshold)

        // 3. 分配 GPU 输出 buffer
        let binCount: UInt32 = 4096
        guard let histBuffer = context.device.makeBuffer(
            length: Int(4 * binCount) * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, Int(4 * binCount) * MemoryLayout<UInt32>.size)

        guard let exposureBuffer = context.device.makeBuffer(
            length: 8 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 8 * MemoryLayout<UInt32>.size)

        // 4. 启动 command buffer
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // Dispatch 1: bayerHistogramKernel
        var histConfig = bayerHistConfig(
            rawWidth: UInt32(rawW),
            rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX),
            visibleOffsetY: UInt32(data.visibleOffsetY),
            visibleWidth: UInt32(visibleW),
            visibleHeight: UInt32(visibleH),
            binCount: binCount,
            blackLevel: UInt32(black),
            whiteLevel: UInt32(white),
            overThreshold: absOver,
            underThreshold: absUnder
        )

        let totalVisible = visibleW * visibleH
        let histGroupSize = 256
        let histGroupCount = (totalVisible + histGroupSize - 1) / histGroupSize

        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.bayerHistogramPipeline)
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            encoder.setBytes(&histConfig, length: MemoryLayout<bayerHistConfig>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: histGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: histGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 2: bayerToGreenPlaneKernel
        let greenW = visibleW / 2
        let greenH = visibleH / 2
        guard greenW > 0, greenH > 0 else {
            throw NSError(
                domain: "rawViewer.rawBayerAnalyzer", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Visible area too small for green plane"]
            )
        }
        guard let greenBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc greenBuffer") }

        var greenConfig = greenPlaneConfig(
            rawWidth: UInt32(rawW),
            rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX),
            visibleOffsetY: UInt32(data.visibleOffsetY),
            greenWidth: UInt32(greenW),
            greenHeight: UInt32(greenH),
            blackLevel: UInt32(black)
        )

        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.bayerToGreenPlanePipeline)
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(greenBuffer, offset: 0, index: 1)
            encoder.setBytes(&greenConfig, length: MemoryLayout<greenPlaneConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 3: greenLaplacianKernel
        guard let lapBuffer = context.device.makeBuffer(
            length: greenW * greenH * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc lapBuffer") }

        var lapConfig = greenLaplacianConfig(
            width: UInt32(greenW),
            height: UInt32(greenH)
        )

        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else {
                throw makeError("makeComputeCommandEncoder failed")
            }
            encoder.setComputePipelineState(context.greenLaplacianPipeline)
            encoder.setBuffer(greenBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            encoder.setBytes(&lapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 4: reduceLaplacianKernel
        let reduceGroupSize = 256
        let reduceGroupCount = (greenW * greenH + reduceGroupSize - 1) / reduceGroupSize
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
            encoder.setBytes(&lapConfig, length: MemoryLayout<greenLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: reduceGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: reduceGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // 5. CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 4 * Int(binCount))
        let greenHist = Array(UnsafeBufferPointer(start: histPtr.advanced(by: Int(binCount)), count: Int(binCount)))

        let exposurePtr = exposureBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        var overCount: UInt64 = 0
        var underCount: UInt64 = 0
        for ch in 0..<4 {
            overCount += UInt64(exposurePtr[ch * 2 + 0])
            underCount += UInt64(exposurePtr[ch * 2 + 1])
        }
        let totalPixels = UInt64(totalVisible)
        let overRatio = Double(overCount) / Double(totalPixels)
        let underRatio = Double(underCount) / Double(totalPixels)

        let exposureStatus: String
        if overRatio > config.exposure.overexposeRatioLimit {
            exposureStatus = "overexposed"
        } else if underRatio > config.exposure.underexposeRatioLimit {
            exposureStatus = "underexposed"
        } else {
            exposureStatus = "normal"
        }

        let partialPtr = partialStats.contents().bindMemory(to: partialStatsGpu.self, capacity: reduceGroupCount)
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<reduceGroupCount {
            sum += Double(partialPtr[i].sum)
            sumSq += Double(partialPtr[i].sumSq)
        }
        let total = Double(greenW * greenH)
        let mean = total > 0 ? sum / total : 0
        let variance = total > 0 ? max(0, sumSq / total - mean * mean) : 0
        let isBlurry = variance < config.blur.laplacianThresholdRaw

        let (p01, p999) = computePercentiles(greenHist: greenHist, totalPixels: UInt64(greenW * greenH), binCount: Int(binCount))
        let maxBin = Double(binCount - 1)
        let p01Code = Double(p01) / maxBin * Double(white - black)
        let p999Code = Double(p999) / maxBin * Double(white - black)
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(Double(white - black) / p01Code) : 0
        let dr = dynamicRangeData(
            sceneSpreadEv: sceneSpreadEv,
            codeRangeEv: codeRangeEv,
            blackLevel: black,
            whiteLevel: white
        )

        return rawAnalysisResult(
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            dynamicRange: dr,
            blackLevel: black,
            whiteLevel: white
        )
    }

    private func computePercentiles(greenHist: [UInt32], totalPixels: UInt64, binCount: Int) -> (UInt32, UInt32) {
        guard totalPixels > 0, !greenHist.isEmpty, binCount > 0 else { return (0, 0) }
        let p01Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.001)))
        let p999Target = max(UInt64(1), UInt64(ceil(Double(totalPixels) * 0.999)))
        var cum: UInt64 = 0
        var p01Bin: UInt32?
        var p999Bin: UInt32?

        for i in 0..<min(binCount, greenHist.count) {
            cum += UInt64(greenHist[i])
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
            p999Bin ?? UInt32(max(0, min(binCount, greenHist.count) - 1))
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(
            domain: "rawViewer.rawBayerAnalyzer", code: 999,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }
}
