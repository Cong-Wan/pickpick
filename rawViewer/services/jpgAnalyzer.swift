/*
Author: wilbur
Version: 1.6
Date: 2026-06-22
Description: JPG 兜底分析：CoreImage 渲染到 RGBA texture，Metal 全局/网格直方图 + 每格 Laplacian + 共享评分引擎。v1.6 改用全局+网格特征 + 主因分类
*/

import Foundation
import Metal
import CoreImage

nonisolated public protocol jpgAnalyzing: AnyObject, Sendable {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

struct jpgHistConfig {
    var totalPixels: UInt32
    var overThreshold: UInt32
    var underThreshold: UInt32
}

struct jpgLaplacianConfig {
    var width: UInt32
    var height: UInt32
}

struct jpgGridHistConfigGpu {
    var planeWidth: UInt32
    var planeHeight: UInt32
    var gridRows: UInt32
    var gridCols: UInt32
    var binCount: UInt32
    var darkThreshold: Float
    var deepDarkThreshold: Float
    var highlightThreshold: Float
}

nonisolated public final class jpgAnalyzer: jpgAnalyzing, @unchecked Sendable {
    private let contextProvider: @Sendable () throws -> metalAnalysisContext
    private let maxJpgPixels: Int

    public init(
        contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() },
        maxJpgPixels: Int = 100_000_000
    ) {
        self.contextProvider = contextProvider
        self.maxJpgPixels = maxJpgPixels
    }

    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        let context = try contextProvider()
        let ciContext = CIContext(mtlDevice: context.device)

        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: jpgPath)) else {
            throw makeError("Failed to load CIImage from \(jpgPath)")
        }
        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)
        guard width > 0, height > 0 else { throw makeError("CIImage has zero dimensions") }
        let totalPixels = width * height
        guard totalPixels <= maxJpgPixels else { throw makeError("JPG too large: \(width)x\(height)") }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        texDesc.usage = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: texDesc) else { throw makeError("Failed to create RGBA texture") }

        guard let grayBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<UInt8>.size, options: .storageModeShared) else { throw makeError("alloc grayBuffer") }
        guard let lapBuffer = context.device.makeBuffer(length: totalPixels * MemoryLayout<Float>.size, options: .storageModeShared) else { throw makeError("alloc lapBuffer") }
        guard let histBuffer = context.device.makeBuffer(length: 256 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc histBuffer") }
        memset(histBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.size)
        guard let exposureBuffer = context.device.makeBuffer(length: 2 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc exposureBuffer") }
        memset(exposureBuffer.contents(), 0, 2 * MemoryLayout<UInt32>.size)

        let gridRows = UInt32(config.grid.rows)
        let gridCols = UInt32(config.grid.columns)
        let gridBinCount: UInt32 = 64
        let tileCount = Int(gridRows * gridCols)
        guard let gridHistBuffer = context.device.makeBuffer(length: tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc gridHistBuffer") }
        memset(gridHistBuffer.contents(), 0, tileCount * Int(gridBinCount) * MemoryLayout<UInt32>.size)
        guard let gridCountBuffer = context.device.makeBuffer(length: tileCount * 4 * MemoryLayout<UInt32>.size, options: .storageModeShared) else { throw makeError("alloc gridCountBuffer") }
        memset(gridCountBuffer.contents(), 0, tileCount * 4 * MemoryLayout<UInt32>.size)
        guard let perTileStatsBuffer = context.device.makeBuffer(length: tileCount * MemoryLayout<perTileStatsGpu>.size, options: .storageModeShared) else { throw makeError("alloc perTileStatsBuffer") }

        guard let cmd = context.commandQueue.makeCommandBuffer() else { throw makeError("makeCommandBuffer") }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ciImage, to: texture, commandBuffer: cmd, bounds: ciImage.extent, colorSpace: colorSpace)

        let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
        let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)

        // Dispatch 1: rgbToGray
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.rgbToGrayPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            var totalPx = UInt32(totalPixels)
            encoder.setBytes(&totalPx, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 2: jpgHistogram (全局)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(histBuffer, offset: 0, index: 1)
            encoder.setBuffer(exposureBuffer, offset: 0, index: 2)
            var histConfig = jpgHistConfig(totalPixels: UInt32(totalPixels), overThreshold: absOver, underThreshold: absUnder)
            encoder.setBytes(&histConfig, length: MemoryLayout<jpgHistConfig>.size, index: 3)
            let groupSize = 256
            let groupCount = (totalPixels + groupSize - 1) / groupSize
            encoder.dispatchThreadgroups(MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 3: jpgLaplacian
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgLaplacianPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(lapBuffer, offset: 0, index: 1)
            var lapConfig = jpgLaplacianConfig(width: UInt32(width), height: UInt32(height))
            encoder.setBytes(&lapConfig, length: MemoryLayout<jpgLaplacianConfig>.size, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 4: reduceLaplacianPerTile
        var gridReduceConfig = gridReduceConfigGpu(width: UInt32(width), height: UInt32(height), gridRows: gridRows, gridCols: gridCols)
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.reduceLaplacianPerTilePipeline)
            encoder.setBuffer(lapBuffer, offset: 0, index: 0)
            encoder.setBuffer(perTileStatsBuffer, offset: 0, index: 1)
            encoder.setBytes(&gridReduceConfig, length: MemoryLayout<gridReduceConfigGpu>.size, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: tileCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        }

        // Dispatch 5: jpgGridHistogram
        var jpgGridConfig = jpgGridHistConfigGpu(
            planeWidth: UInt32(width), planeHeight: UInt32(height),
            gridRows: gridRows, gridCols: gridCols, binCount: gridBinCount,
            darkThreshold: Float(config.exposure.underexposePixelThreshold) * 255.0,
            deepDarkThreshold: Float(config.scoring.deepDarkPixelThreshold) * 255.0,
            highlightThreshold: Float(config.exposure.overexposePixelThreshold) * 255.0
        )
        do {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw makeError("makeComputeCommandEncoder failed") }
            encoder.setComputePipelineState(context.jpgGridHistogramPipeline)
            encoder.setBuffer(grayBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridHistBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridCountBuffer, offset: 0, index: 2)
            encoder.setBytes(&jpgGridConfig, length: MemoryLayout<jpgGridHistConfigGpu>.size, index: 3)
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            throw makeError("command buffer error: \(cmd.error?.localizedDescription ?? "unknown")")
        }

        // CPU 后处理
        let histPtr = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        let histArray = Array(UnsafeBufferPointer(start: histPtr, count: 256))
        let range = 255.0
        let globalFeatures = buildGlobalExposureFeatures(
            histogram: histArray, binCount: 256,
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
            let tf = buildTileFeatures(
                histogram: gridHistArray, histogramOffset: t * Int(gridBinCount), binCount: Int(gridBinCount),
                pixelCount: pixelCount, darkCount: Double(gridCountPtr[t * 4 + 1]),
                deepDarkCount: Double(gridCountPtr[t * 4 + 2]), highlightCount: Double(gridCountPtr[t * 4 + 3]),
                laplacianSum: Double(statsPtr[t].sum), laplacianSumSq: Double(statsPtr[t].sumSq), range: range,
                usableMinBrightness: config.scoring.usableTileMinBrightnessJpg,
                usableMinContrast: config.scoring.usableTileMinContrastJpg
            )
            tiles.append(tf)
        }

        let blur = buildBlurFeatures(
            tiles: tiles, gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns,
            sharpTileLaplacianThreshold: config.scoring.sharpTileLaplacianThresholdJpg,
            lowContrastTileThreshold: config.scoring.lowContrastTileThresholdJpg
        )

        let features = analysisFeatures(
            globalExposure: globalFeatures, tiles: tiles, blur: blur,
            gridRows: Int(gridRows), gridCols: Int(gridCols),
            centerRows: config.grid.centerRows, centerCols: config.grid.centerColumns
        )
        let scores = scoringEngine.score(features: features, config: config, valueSpace: .jpgGamma)
        let primary = scoringEngine.classify(scores: scores, config: config)
        let fields = mapPrimaryToFields(primary)

        let p01Code = Double(globalFeatures.p01Norm) * range
        let p999Code = Double(globalFeatures.p99Norm) * range
        let sceneSpreadEv = p01Code > 0 ? log2(p999Code / p01Code) : 0
        let codeRangeEv = p01Code > 0 ? log2(range / p01Code) : 0
        let dr = dynamicRangeData(sceneSpreadEv: sceneSpreadEv, codeRangeEv: codeRangeEv, blackLevel: 0, whiteLevel: 255)

        let debugInfo = analysisDebugInfo(features: features, scores: scores, primary: primary)
        return rawAnalysisResult(
            isBlurry: fields.isBlurry,
            exposureStatus: fields.exposureStatus,
            dynamicRange: dr,
            blackLevel: 0,
            whiteLevel: 255,
            analysisSource: "jpg",
            debugInfo: debugInfo
        )
    }

    private func makeError(_ msg: String) -> NSError {
        NSError(domain: "rawViewer.jpgAnalyzer", code: 999, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
