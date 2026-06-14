/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: Metal 设备 / queue / pipeline 上下文；初始化失败改为 throws，避免设备或 shader 异常时 fatalError 退出。v1.2 将 shared 访问声明为非 UI actor 隔离，供后台分析任务安全调用
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
        case .metalNotSupported:
            return "Metal is not supported on this device"
        case .commandQueueUnavailable:
            return "Failed to create Metal command queue"
        case .libraryUnavailable:
            return "Failed to load default Metal library"
        case .functionUnavailable(let name):
            return "Metal function '\(name)' was not found"
        case .pipelineCreationFailed(let name, let underlying):
            return "Failed to create Metal pipeline '\(name)': \(underlying.localizedDescription)"
        }
    }
}

public final class metalAnalysisContext {
    private nonisolated static let cachedResult: Result<metalAnalysisContext, Error> = Result {
        try metalAnalysisContext()
    }

    public nonisolated static func shared() throws -> metalAnalysisContext {
        try cachedResult.get()
    }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public let bayerHistogramPipeline: MTLComputePipelineState
    public let bayerToGreenPlanePipeline: MTLComputePipelineState
    public let greenLaplacianPipeline: MTLComputePipelineState
    public let reducePipeline: MTLComputePipelineState

    public let rgbToGrayPipeline: MTLComputePipelineState
    public let jpgHistogramPipeline: MTLComputePipelineState
    public let jpgLaplacianPipeline: MTLComputePipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw metalAnalysisContextError.metalNotSupported
        }
        guard let queue = device.makeCommandQueue() else {
            throw metalAnalysisContextError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw metalAnalysisContextError.libraryUnavailable
        }
        self.device = device
        self.commandQueue = queue
        self.library = library

        self.bayerHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "bayerHistogramKernel")
        self.bayerToGreenPlanePipeline = try Self.makePipeline(device: device, library: library, name: "bayerToGreenPlaneKernel")
        self.greenLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "greenLaplacianKernel")
        self.reducePipeline = try Self.makePipeline(device: device, library: library, name: "reduceLaplacianKernel")
        self.rgbToGrayPipeline = try Self.makePipeline(device: device, library: library, name: "rgbToGrayKernel")
        self.jpgHistogramPipeline = try Self.makePipeline(device: device, library: library, name: "jpgHistogramKernel")
        self.jpgLaplacianPipeline = try Self.makePipeline(device: device, library: library, name: "jpgLaplacianKernel")
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
