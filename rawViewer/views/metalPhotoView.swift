/*
Author: wilbur
Version: 3.6
Date: 2026-06-17
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；修正 CoreImage 渲染到 Metal texture 的 Y 轴映射，避免详情图相对缩略图上下翻转；累积捏合缩放逐帧增量并精简重绘触发
*/

import AppKit
import CoreImage
import MetalKit


public final class metalPhotoView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    // drawable 纹理 usage 不含 .shaderWrite，CIContext 无法直接写入；先渲染到 offscreen 再 blit 到 drawable。
    private var offscreenTexture: MTLTexture?

    private var currentImage: CIImage?
    private var rotationDegrees: Int = 0
    public private(set) var errorMessage: String?
    public private(set) var isShowingError: Bool = false

    private var userZoom: Double = 1.0
    private let minZoom: Double = 0.1
    private let maxZoom: Double = 10.0
    private let zoomStep: Double = 1.2
    private var panOffset: CGPoint = .zero
    private var debugDrawLogCount = 0

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
        case .changed:
            // magnification 是相对上一帧的增量，直接累积乘到 userZoom，长按捏合可连续放大/缩小。
            userZoom = max(minZoom, min(maxZoom, userZoom * (1.0 + Double(gesture.magnification))))
            needsDisplay = true
            onZoomChanged?(userZoom)
        case .ended:
            onZoomChanged?(userZoom)
        default:
            break
        }
    }

    // MARK: - 状态只读属性

    public var hasImage: Bool { currentImage != nil }
    public var currentZoom: Double { userZoom }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestRedrawIfNeeded()
    }

    public override func layout() {
        super.layout()
        requestRedrawIfNeeded()
    }

    private func requestRedrawIfNeeded() {
        // 保留 async 触发（带守卫）：drawable 在 viewDidMoveToWindow/layout 时机可能未就绪，
        // 延后到下一 runloop 重绘更稳；去掉原先无守卫的同步裸触发，避免双触发。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentImage != nil || self.isShowingError else { return }
            self.needsDisplay = true
        }
    }

    // MARK: - 状态切换 API

    public func setImage(_ image: CIImage?, rotationDegrees: Int = 0) {
        currentImage = image
        self.rotationDegrees = normalizedRotationDegrees(rotationDegrees)
        errorMessage = nil
        isShowingError = false
        debugDrawLogCount = 0
        appDebugLogger.log("display metal setImage hasImage=\(image != nil) extent=\(image?.extent.debugDescription ?? "nil") rotation=\(self.rotationDegrees) windowReady=\(window != nil) bounds=\(bounds)")
        requestRedrawIfNeeded()
    }

    public func clearImage() {
        currentImage = nil
        rotationDegrees = 0
        errorMessage = nil
        isShowingError = false
        debugDrawLogCount = 0
        needsDisplay = true
    }

    public func showError(_ message: String) {
        currentImage = nil
        rotationDegrees = 0
        errorMessage = message
        isShowingError = true
        requestRedrawIfNeeded()
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

    private func renderTransform(
        for extent: CGRect,
        targetSize: CGSize,
        effectiveScale: Double,
        panOffset: CGPoint
    ) -> CGAffineTransform {
        let outputWidth = Double(extent.width) * effectiveScale
        let outputHeight = Double(extent.height) * effectiveScale
        let imageLeft = (Double(targetSize.width) - outputWidth) / 2 + panOffset.x
        let imageTop = (Double(targetSize.height) - outputHeight) / 2 + panOffset.y

        return CGAffineTransform(
            a: effectiveScale,
            b: 0,
            c: 0,
            d: -effectiveScale,
            tx: imageLeft - Double(extent.minX) * effectiveScale,
            ty: imageTop + Double(extent.maxY) * effectiveScale
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let drawable = currentDrawable else {
            logDrawDebug("missingDrawable dirty=\(dirtyRect) bounds=\(bounds) hasImage=\(currentImage != nil) windowReady=\(window != nil)")
            return
        }
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            logDrawDebug("missingCommandBuffer hasImage=\(currentImage != nil)")
            return
        }
        guard let ciContext else {
            logDrawDebug("missingCIContext hasImage=\(currentImage != nil)")
            return
        }

        let target = drawable.texture
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        logDrawDebug("draw start hasImage=\(currentImage != nil) target=\(target.width)x\(target.height) viewBounds=\(self.bounds)")

        guard let offscreen = ensureOffscreen(matching: target) else {
            logDrawDebug("missingOffscreenTexture target=\(target.width)x\(target.height)")
            return
        }

        let clearPass = MTLRenderPassDescriptor()
        if let attachment = clearPass.colorAttachments[0] {
            attachment.texture = offscreen
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
            if extent.width > 0, extent.height > 0,
               extent.width.isFinite, extent.height.isFinite {
                let fitScale = min(Double(target.width) / extent.width, Double(target.height) / extent.height)
                let effectiveScale = fitScale * userZoom
                let width = Double(extent.width) * effectiveScale
                let height = Double(extent.height) * effectiveScale
                let targetSize = CGSize(width: target.width, height: target.height)
                let transform = renderTransform(
                    for: extent,
                    targetSize: targetSize,
                    effectiveScale: effectiveScale,
                    panOffset: panOffset
                )
                logDrawDebug("render image extent=\(extent) fitScale=\(fitScale) effectiveScale=\(effectiveScale) output=\(width)x\(height) transform=\(transform)")
                ciContext.render(imageToRender.transformed(by: transform), to: offscreen, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            } else {
                logDrawDebug("invalidExtent extent=\(extent)")
            }
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: offscreen, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                to: target, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureOffscreen(matching target: MTLTexture) -> MTLTexture? {
        if let tex = offscreenTexture,
           tex.width == target.width,
           tex.height == target.height,
           tex.pixelFormat == target.pixelFormat {
            return tex
        }
        guard let mtlDevice = device else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.pixelFormat,
            width: target.width,
            height: target.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        let tex = mtlDevice.makeTexture(descriptor: desc)
        offscreenTexture = tex
        return tex
    }

    private func logDrawDebug(_ message: @autoclosure () -> String) {
        guard appDebugLogger.isEnabled, debugDrawLogCount < 12 else { return }
        debugDrawLogCount += 1
        appDebugLogger.log("display metal \(message())")
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
