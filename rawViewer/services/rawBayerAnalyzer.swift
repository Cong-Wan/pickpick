/*
Author: wilbur
Version: 1.8
Date: 2026-06-25
Description: RAW Bayer 分析：LibRaw 取数据 + Metal 全局/网格直方图 + 每格 Laplacian + 共享评分引擎。v1.5 用全局+网格特征 + 主因分类替代单阈值；v1.6 greenBuffer/lapBuffer 改 .storageModePrivate（纯 GPU 中间缓冲，语义更正确、省去 CPU 可映射性/coherency 跟踪开销；CPU 后处理只读 histBuffer/gridHistBuffer/gridCountBuffer/perTileStatsBuffer）；v1.7 删除未读回的全局曝光计数 exposure buffer 链路并修正 p99 动态范围变量命名；v1.8 RAW 增加尺寸保护，Bayer pattern 来自 LibRaw，可诊断 open/unpack 错误
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
    public let debugInfo: analysisDebugInfo?

    public init(
        isBlurry: Bool,
        exposureStatus: String,
        dynamicRange: dynamicRangeData?,
        blackLevel: Int,
        whiteLevel: Int,
        analysisSource: String = "raw",
        debugInfo: analysisDebugInfo? = nil
    ) {
        self.isBlurry = isBlurry
        self.exposureStatus = exposureStatus
        self.dynamicRange = dynamicRange
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.analysisSource = analysisSource
        self.debugInfo = debugInfo
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
    var color00: UInt32
    var color01: UInt32
    var color10: UInt32
    var color11: UInt32
}

struct greenPlaneConfig {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var visibleOffsetX: UInt32
    var visibleOffsetY: UInt32
    var greenWidth: UInt32
    var greenHeight: UInt32
    var blackLevel: UInt32
    var green1OffsetX: UInt32
    var green1OffsetY: UInt32
    var green2OffsetX: UInt32
    var green2OffsetY: UInt32
}

struct greenLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

struct rawGridHistConfigGpu {
    var planeWidth: UInt32
    var planeHeight: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
    var binCount: UInt32
    var range: Float
    var darkThreshold: Float
    var deepDarkThreshold: Float
    var highlightThreshold: Float
}

struct gridReduceConfigGpu {
    var width: UInt32
    var height: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
}

struct perTileStatsGpu {
    var sum: Float
    var sumSq: Float
}

nonisolated public final class rawBayerAnalyzer: rawBayerAnalyzing, @unchecked Sendable {
    private let contextProvider: @Sendable () throws -> metalAnalysisContext

    public init(contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() }) {
        self.contextProvider = contextProvider
    }

    public func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        var openError = [CChar](repeating: 0, count: 512)
        let handle = rawPath.withCString { pathPointer in
            openError.withUnsafeMutableBufferPointer { buffer in
                rwRawOpenWithError(pathPointer, buffer.baseAddress, CInt(buffer.count))
            }
        }
        guard let handle else {
            let message = String(cString: openError)
            throw makeError("LibRaw open/unpack failed for \(rawPath): \(message.isEmpty ? "unknown" : message)")
        }
        defer { rwRawClose(handle) }

        let data = rwRawGetBayerData(handle)
        guard data.greenPixelCount == 2 else {
            throw makeError("Unsupported Bayer pattern: expected 2 green pixels, got \(data.greenPixelCount)")
        }
        guard data.rawWidth > 0, data.rawHeight > 0, data.rawImage != nil else {
            throw makeError("LibRaw returned empty Bayer data")
        }

        let black = Int(data.blackLevel)
        let white = Int(data.whiteLevel)
        guard white > black else {
            throw makeError("Invalid black/white level: black=\(black) white=\(white)")
        }

        let visibleW = Int(data.visibleWidth)
        let visibleH = Int(data.visibleHeight)
        let rawW = Int(data.rawWidth)
        let rawH = Int(data.rawHeight)
        let range = Double(white - black)

        let maxRawPixels = 120_000_000
        let maxRawBytesPerTask = 768 * 1024 * 1024
        let totalRaw = try checkedPixelCount(width: rawW, height: rawH, maxPixels: maxRawPixels, label: "RAW")
        let rawByteCount = try checkedByteCount(
            pixelCount: totalRaw,
            bytesPerPixel: MemoryLayout<UInt16>.size,
            maxBytes: maxRawBytesPerTask,
            label: "RAW buffer"
        )
        guard let rawBuffer = context.device.makeBuffer(
            length: rawByteCount,
            options: .storageModeShared
        ) else { throw makeError("alloc rawBuffer") }
        memcpy(rawBuffer.contents(), data.rawImage, rawByteCount)


        let binCount: UInt32 = 4096
        let gridRows = UInt32(config.grid.rows)
        let gridCols = UInt32(config.grid.columns)
        let gridBinCount: UInt32 = 64
        let tileCount = Int(gridRows * gridCols)

        guard let histBuffer = context.device.makeBuffer(
            length: Int(4 * binCount) * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, Int(4 * binCount) * MemoryLayout<UInt32>.size)


        let greenW = visibleW / 2
        let greenH = visibleH / 2
        guard greenW > 0, greenH > 0 else {
            throw makeError("Visible area too small for green plane")
        }
        let greenPixels = try checkedPixelCount(width: greenW, height: greenH, maxPixels: maxRawPixels / 4, label: "RAW green plane")
        let greenByteCount = try checkedByteCount(
            pixelCount: greenPixels,
            bytesPerPixel: MemoryLayout<Float>.size,
            maxBytes: maxRawBytesPerTask,
            label: "RAW green plane"
        )
        guard let greenBuffer = context.device.makeBuffer(
            length: greenByteCount,
            options: .storageModePrivate
        ) else { throw makeError("alloc greenBuffer") }

        guard let lapBuffer = context.device.makeBuffer(
            length: greenByteCount,
            options: .storageModePrivate
        ) else { throw makeError("alloc lapBuffer") }

        guard let gridHistBuffer = context.device.makeBuffer(
            length: tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc gridHistBuffer") }
        memset(gridHistBuffer.contents(), 0, tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size)

        guard let gridCountBuffer = context.device.makeBuffer(
            length: tileCount * 4 * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc gridCountBuffer") }
        memset(gridCountBuffer.contents(), 0, tileCount * 4 * MemoryLayout<UInt32>.size)

        guard let perTileStatsBuffer = context.device.makeBuffer(
            length: tileCount * MemoryLayout<perTileStatsGpu>.size,
            options: .storageModeShared
        ) else { throw makeError("alloc perTileStatsBuffer") }

        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw makeError("makeCommandBuffer")
        }

        // Dispatch 1: bayerHistogramKernel (全局 4 通道直方图)
        var histConfig = bayerHistConfig(
            rawWidth: UInt32(rawW), rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX), visibleOffsetY: UInt32(data.visibleOffsetY),
            visibleWidth: UInt32(visibleW), visibleHeight: UInt32(visibleH),
            binCount: binCount, blackLevel: UInt32(black), whiteLevel: UInt32(white),
            color00: UInt32(data.color00), color01: UInt32(data.color01),
            color10: UInt32(data.color10), color11: UInt32(data.color11)
        )
        let totalVisible = visibleW * visibleH
        let histGroupSize = 256
        let histGroupCount = (totalVisible + histGroupSize - 1) / histGroupSize
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.bayerHistogramPipeline)
            encoder.setBuffer(rawBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBytes(&histConfig, length: MemoryLayout<bayerHistConfig>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: histGroupCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: histGroupSize, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 2: bayerToGreenPlaneKernel
        var greenConfig = greenPlaneConfig(
            rawWidth: UInt32(rawW), rawHeight: UInt32(rawH),
            visibleOffsetX: UInt32(data.visibleOffsetX), visibleOffsetY: UInt32(data.visibleOffsetY),
            greenWidth: UInt32(greenW), greenHeight: UInt32(greenH), blackLevel: UInt32(black),
            green1OffsetX: UInt32(data.green1OffsetX), green1OffsetY: UInt32(data.green1OffsetY),
            green2OffsetX: UInt32(data.green2OffsetX), green2OffsetY: UInt32(data.green2OffsetY)
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
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
        var lapConfig = greenLaplacianConfig(width: UInt32(greenW), height: UInt32(greenH))
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
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

        // Dispatch 4: reduceLaplacianPerTileKernel (每格 Laplacian sum/sumSq)
        var gridReduceConfig = gridReduceConfigGpu(width: UInt32(greenW), height: UInt32(greenH), gridRows: gridRows, gridCols: gridCols)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.reduceLaplacianPerTilePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(perTileStatsBuffer, offset: 0, index: 1)
            encoder.setBytes(&gridReduceConfig, length: MemoryLayout<gridReduceConfigGpu>.size, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: tileCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        // Dispatch 5: rawGridHistogramKernel (每格亮度直方图 + 计数)
        var rawGridConfig = rawGridHistConfigGpu(
            planeWidth: UInt32(greenW), planeHeight: UInt32(greenH),
            gridRows: gridRows, gridCols: gridCols, binCount: gridBinCount,
            range: Float(range),
            darkThreshold: Float(config.exposure.underexposePixelThreshold) * Float(range),
            deepDarkThreshold: Float(config.scoring.deepDarkPixelThreshold) * Float(range),
            highlightThreshold: Float(config.exposure.overexposePixelThreshold) * Float(range)
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.rawGridHistogramPipeline)
            encoder.setBuffer(greenBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridHistBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridCountBuffer, offset: 0, index: 2)
            encoder.setBytes(&rawGridConfig, length: MemoryLayout<rawGridHistConfigGpu>.size, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: (greenW + 15) / 16, height: (greenH + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 4 * Int(binCount))
        let greenHist = Array(UnsafeBufferPointer(start: histPtr.advanced(by: Int(binCount)), count: Int(binCount)))

        let globalFeatures = buildGlobalExposureFeatures(
            histogram: greenHist, binCount: Int(binCount),
            darkThresholdNorm: config.exposure.underexposePixelThreshold,
            deepDarkThresholdNorm: config.scoring.deepDarkPixelThreshold,
            highlightThresholdNorm: config.exposure.overexposePixelThreshold
        )

        let gridHistPtr = gridHistBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * Int(gridBinCount))
        let gridCountPtr = gridCountBuffer.contents().bindMemory(to: UInt32.self, capacity: tileCount * 4)
        let statsPtr = perTileStatsBuffer.contents().bindMemory(to: perTileStatsGpu.self, capacity: tileCount)
        let gridHistArray = Array(UnsafeBufferPointer(start: gridHistPtr, count: tileCount * Int(gridBinCount)))

        var tiles: [tileFeatures] = []
        tiles.reserveCapacity(tileCount)
        for t in 0..<tileCount {
            let pixelCount = Double(gridCountPtr[t * 4 + 0])
            let darkCount = Double(gridCountPtr[t * 4 + 1])
            let deepDarkCount = Double(gridCountPtr[t * 4 + 2])
            let highlightCount = Double(gridCountPtr[t * 4 + 3])
            let tf = buildTileFeatures(
                histogram: gridHistArray, histogramOffset: t * Int(gridBinCount), binCount: Int(gridBinCount),
                pixelCount: pixelCount, darkCount: darkCount, deepDarkCount: deepDarkCount, highlightCount: highlightCount,
                laplacianSum: Double(statsPtr[t].sum), laplacianSumSq: Double(statsPtr[t].sumSq), range: range,
                usableMinBrightness: config.scoring.usableTileMinBrightnessRaw,
                usableMinContrast: config.scoring.usableTileMinContrastRaw
            )
            tiles.append(tf)
        }

        let blur = buildBlurFeatures(
            tiles: tiles, gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns,
            sharpTileLaplacianThreshold: config.scoring.sharpTileLaplacianThresholdRaw,
            lowContrastTileThreshold: config.scoring.lowContrastTileThresholdRaw
        )

        let features = analysisFeatures(
            globalExposure: globalFeatures, tiles: tiles, blur: blur,
            gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns
        )

        let scores = scoringEngine.score(features: features, config: config, valueSpace: .rawLinear)
        let primary = scoringEngine.classify(scores: scores, config: config)
        let fields = mapPrimaryToFields(primary)

        // 动态范围 (复用全局特征百分位)
        let p01Code = globalFeatures.p01Norm * range
        let p99Code = globalFeatures.p99Norm * range
        let sceneSpreadEv = p01Code > 0 ? log2(p99Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
        let dr = dynamicRangeData(sceneSpreadEv: sceneSpreadEv, codeRangeEv: codeRangeEv, blackLevel: black, whiteLevel: white)

        let debugInfo = analysisDebugInfo(features: features, scores: scores, primary: primary)
        return rawAnalysisResult(
            isBlurry: fields.isBlurry,
            exposureStatus: fields.exposureStatus,
            dynamicRange: dr,
            blackLevel: black,
            whiteLevel: white,
            analysisSource: "raw",
            debugInfo: debugInfo
        )
    }

    private func checkedPixelCount(width: Int, height: Int, maxPixels: Int, label: String) throws -> Int {
        guard width > 0, height > 0 else {
            throw makeError("Invalid \(label) dimensions: \(width)x\(height)")
        }
        guard width <= maxPixels / height else {
            throw makeError("\(label) dimension overflow: \(width)x\(height)")
        }
        let pixels = width * height
        guard pixels <= maxPixels else {
            throw makeError("\(label) too large: \(width)x\(height)")
        }
        return pixels
    }

    private func checkedByteCount(pixelCount: Int, bytesPerPixel: Int, maxBytes: Int, label: String) throws -> Int {
        guard pixelCount > 0, bytesPerPixel > 0 else {
            throw makeError("Invalid \(label) byte count input")
        }
        guard pixelCount <= maxBytes / bytesPerPixel else {
            throw makeError("\(label) memory budget exceeded")
        }
        return pixelCount * bytesPerPixel
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "rawViewer.rawBayerAnalyzer", code: 999, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
