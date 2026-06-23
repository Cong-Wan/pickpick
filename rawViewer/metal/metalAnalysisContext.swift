/*
Author: wilbur
Version: 1.3
Date: 2026-06-22
Description: Metal 设备 / queue / pipeline 上下文。v1.3 新增每格 Laplacian 规约 + 网格直方图 pipeline，并保留旧全局 reducePipeline 以保证分步构建通过
*/

import Foundation
import Metal

public enum metalAnalysisContextError: Error, LocalizedError {
    case metalNotSupported
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(name: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .metalNotSupported: return "Metal is not supported on this device"
        case .commandQueueUnavailable: return "Failed to create Metal command queue"
        case .libraryUnavailable: return "Failed to load default Metal library"
        case .functionUnavailable(let name): return "Metal function '\(name)' was not found"
        case .pipelineCreationFailed(let name, let underlying): return "Failed to create Metal pipeline '\(name)': \(underlying.localizedDescription)"
        }
    }
}

public final class metalAnalysisContext {
    private nonisolated static let cachedResult: Result<metalAnalysisContext, Error> = Result { try metalAnalysisContext() }
    public nonisolated static func shared() throws -> metalAnalysisContext { try cachedResult.get() }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public let bayerHistogramPipeline: MTLComputePipelineState
    public let bayerToGreenPlanePipeline: MTLComputePipelineState
    public let greenLaplacianPipeline: MTLComputePipelineState
    public let reducePipeline: MTLComputePipelineState
    public let reduceLaplacianPerTilePipeline: MTLComputePipelineState
    public let rawGridHistogramPipeline: MTLComputePipelineState
    public let rgbToGrayPipeline: MTLComputePipelineState
    public let jpgHistogramPipeline: MTLComputePipelineState
    public let jpgLaplacianPipeline: MTLComputePipelineState
    public let jpgGridHistogramPipeline: MTLComputePipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw metalAnalysisContextError.metalNotSupported }
        guard let queue = device.makeCommandQueue() else { throw metalAnalysisContextError.commandQueueUnavailable }
        guard let library = device.makeDefaultLibrary() else { throw metalAnalysisContextError.libraryUnavailable }
        self.device = device
        self.commandQueue = queue
        self.library = library

        self.bayerHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "bayerHistogramKernel")
        self.bayerToGreenPlanePipeline = try Self.makePipeline(device: device, library: library, name: "bayerToGreenPlaneKernel")
        self.greenLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "greenLaplacianKernel")
        self.reducePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
        self.reduceLaplacianPerTilePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianPerTileKernel")
        self.rawGridHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "rawGridHistogramKernel")
        self.rgbToGrayPipeline = try Self.makePipeline(device: device, library: library, name: "rgbToGrayKernel")
        self.jpgHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgHistogramKernel")
        self.jpgLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "jpgLaplacianKernel")
        self.jpgGridHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgGridHistogramKernel")
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw metalAnalysisContextError.functionUnavailable(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw metalAnalysisContextError.pipelineCreationFailed(name: name, underlying: error)
        }
    }
}
