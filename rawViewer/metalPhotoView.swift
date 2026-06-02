/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 使用 MTKView、Core Image 和 Metal 加载并绘制 JPG/RAW 图片，提供缺失图片状态
*/

import AppKit
import CoreImage
import MetalKit

public enum photoLoadError: Error, Equatable {
    case cannotLoadImage
    case missingDrawable
}

public final class metalPhotoView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private var currentImage: CIImage?
    public private(set) var missingFileMessage: String?

    public init(frame frameRect: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(frame: frameRect, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
    }

    required init(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(coder: coder)
        self.device = device
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
    }

    public func loadPhoto(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), let image = CIImage(contentsOf: url) else {
            missingFileMessage = "Missing file"
            throw photoLoadError.cannotLoadImage
        }
        missingFileMessage = nil
        currentImage = image
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = currentImage,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }

        let target = drawable.texture
        let scale = min(Double(target.width) / image.extent.width, Double(target.height) / image.extent.height)
        let width = image.extent.width * scale
        let height = image.extent.height * scale
        let x = (Double(target.width) - width) / 2
        let y = (Double(target.height) - height) / 2
        let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
        ciContext.render(image.transformed(by: transform), to: target, commandBuffer: commandBuffer, bounds: CGRect(x: 0, y: 0, width: target.width, height: target.height), colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
