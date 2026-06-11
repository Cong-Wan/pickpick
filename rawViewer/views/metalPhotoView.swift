/*
Author: wilbur
Version: 3.2
Date: 2026-06-11
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；新增展示层 90 度步进旋转
*/

import AppKit
import CoreImage
import MetalKit

public enum photoLoadError: Error, Equatable {
    case cannotLoadImage
    case missingDrawable
}

public enum photoSource {
    case jpg
    case raw
}

public final class metalPhotoView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?

    private var currentImage: CIImage?
    private var rotationDegrees: Int = 0
    public private(set) var errorMessage: String?
    public private(set) var isShowingError: Bool = false

    private var userZoom: Double = 1.0
    private let minZoom: Double = 0.1
    private let maxZoom: Double = 10.0
    private let zoomStep: Double = 1.2
    private var pinchStartZoom: Double = 1.0
    private var pinchStartMagnification: Double = 0.0
    private var panOffset: CGPoint = .zero

    public var onZoomChanged: ((Double) -> Void)?

    public init(frame frameRect: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(frame: frameRect, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        setupGestures()
    }

    required init(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(coder: coder)
        self.device = device
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        setupGestures()
    }

    private func setupGestures() {
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = userZoom
            pinchStartMagnification = Double(gesture.magnification)
        case .changed, .ended:
            let delta = Double(gesture.magnification) - pinchStartMagnification
            let newZoom = max(minZoom, min(maxZoom, pinchStartZoom * (1.0 + delta)))
            userZoom = newZoom
            needsDisplay = true
            onZoomChanged?(userZoom)
        default:
            pinchStartMagnification = 0.0
            break
        }
    }

    // MARK: - 状态只读属性

    public var hasImage: Bool { currentImage != nil }
    public var currentZoom: Double { userZoom }

    // MARK: - 状态切换 API

    public func setImage(_ image: CIImage?, rotationDegrees: Int = 0) {
        currentImage = image
        self.rotationDegrees = normalizedRotationDegrees(rotationDegrees)
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func clearImage() {
        currentImage = nil
        rotationDegrees = 0
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func showError(_ message: String) {
        currentImage = nil
        rotationDegrees = 0
        errorMessage = message
        isShowingError = true
        needsDisplay = true
    }

    // MARK: - 缩放

    public func zoomIn() {
        userZoom = max(minZoom, min(maxZoom, userZoom * zoomStep))
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    public func zoomOut() {
        userZoom = max(minZoom, min(maxZoom, userZoom / zoomStep))
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    public func resetZoom() {
        userZoom = 1.0
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

    // MARK: - 平移

    public func setPanOffset(_ offset: CGPoint) {
        panOffset = offset
        needsDisplay = true
    }

    public func resetPan() {
        panOffset = .zero
        needsDisplay = true
    }

    // MARK: - 渲染

    private func displayImage(from image: CIImage) -> CIImage {
        switch normalizedRotationDegrees(rotationDegrees) {
        case 90:
            return image.oriented(forExifOrientation: 6)
        case 180:
            return image.oriented(forExifOrientation: 3)
        case 270:
            return image.oriented(forExifOrientation: 8)
        default:
            return image
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }

        let target = drawable.texture
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)

        let clearPass = MTLRenderPassDescriptor()
        if let attachment = clearPass.colorAttachments[0] {
            attachment.texture = target
            attachment.loadAction = .clear
            attachment.storeAction = .store
            attachment.clearColor = clearColor
        }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) {
            encoder.endEncoding()
        }

        if let image = currentImage {
            let imageToRender = displayImage(from: image)
            let extent = imageToRender.extent
            guard extent.width > 0, extent.height > 0,
                  extent.width.isFinite, extent.height.isFinite else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            let fitScale = min(Double(target.width) / extent.width, Double(target.height) / extent.height)
            let effectiveScale = fitScale * userZoom
            let width = extent.width * effectiveScale
            let height = extent.height * effectiveScale
            let x = (Double(target.width) - width) / 2 + panOffset.x - extent.minX * effectiveScale
            let y = (Double(target.height) - height) / 2 + panOffset.y - extent.minY * effectiveScale
            let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: effectiveScale, y: effectiveScale)
            ciContext.render(imageToRender.transformed(by: transform), to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "r", "R": resetZoom()
        default: super.keyDown(with: event)
        }
    }
}
