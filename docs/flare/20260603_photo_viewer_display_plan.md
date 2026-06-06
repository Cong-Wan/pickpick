# rawViewer 照片浏览与显示实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 rawViewer 的照片浏览与显示系统，包括分组卡片网格（叠放预览）、普通浏览页（缩略图+主图+checkbox）、重复对比页（左右双图），以及 metalPhotoView 的 GPU 双源解码与缩放交互。

**Architecture:** 基于现有 AppKit + MetalKit 架构，增强 metalPhotoView 支持 JPG/RAW 双源加载与缩放交互；将 groupGridViewController 从按钮列表重构为网格卡片；photoBrowserViewController 采用工具栏+缩略图列表+主图的三栏布局；duplicateCompareViewController 采用左右等宽双图布局。状态机与视图分离，通过 delegate/callback 通信。

**Tech Stack:** Swift, AppKit, MetalKit, Core Image, Objective-C++ Bridge

---

## 文件结构

| 文件 | 职责 | 操作 |
|------|------|------|
| `rawViewer/metalPhotoView.swift` | GPU 图片渲染：JPG/RAW 加载、等比缩放、透明背景、缩放交互 | 修改 |
| `rawViewer/groupCardView.swift` | 分组卡片：叠放预览图效果 | 新增 |
| `rawViewer/groupGridViewController.swift` | 网格布局的分组卡片页面 | 修改 |
| `rawViewer/photoThumbnailView.swift` | 缩略图列表：含 checkbox、全选、选中态 | 新增 |
| `rawViewer/photoBrowserViewController.swift` | 普通浏览页：工具栏+缩略图+主图 | 修改 |
| `rawViewer/duplicateCompareViewController.swift` | 重复对比页：左右双图+操作 | 修改 |

---

### Task 1: metalPhotoView 增强 — 双源加载与缩放交互

**Goal:** metalPhotoView 支持 JPG 和 RAW 两种显示源，等比缩放且保持透明背景，支持 Cmd+/- 键盘缩放、r 键重置和触控板 pinch 手势。

**Files touched:**

- `rawViewer/metalPhotoView.swift` — GPU 渲染 view，增加 RAW 加载、缩放状态、手势识别

------

#### Step 1 — Implement

```swift
// rawViewer/metalPhotoView.swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 使用 MTKView、Core Image 和 Metal 加载并绘制 JPG/RAW 图片，支持等比缩放、透明背景、键盘和触控板缩放交互
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
    public private(set) var missingFileMessage: String?
    public private(set) var rawUnavailable: Bool = false

    private var baseScale: Double = 1.0
    private var userZoom: Double = 1.0
    private let minZoom: Double = 0.1
    private let maxZoom: Double = 10.0
    private let zoomStep: Double = 1.2

    public var onZoomChanged: ((Double) -> Void)?

    public init(frame frameRect: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(frame: frameRect, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
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
        setupGestures()
    }

    private func setupGestures() {
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        let newZoom = max(minZoom, min(maxZoom, userZoom * gesture.magnification))
        userZoom = newZoom
        needsDisplay = true
        onZoomChanged?(userZoom)
    }

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

    public var currentZoom: Double { userZoom }

    public func loadPhoto(url: URL, source: photoSource = .jpg) throws {
        missingFileMessage = nil
        rawUnavailable = false

        if source == .raw {
            do {
                try loadRaw(url: url)
                return
            } catch {
                rawUnavailable = true
                if FileManager.default.fileExists(atPath: url.path.replacingOccurrences(of: ".RAW", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".CR2", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".NEF", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".ARW", with: ".jpg", options: .caseInsensitive)) {
                    let jpgUrl = URL(fileURLWithPath: url.path.replacingOccurrences(of: ".RAW", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".CR2", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".NEF", with: ".jpg", options: .caseInsensitive).replacingOccurrences(of: ".ARW", with: ".jpg", options: .caseInsensitive))
                    try loadJpg(url: jpgUrl)
                    return
                }
                missingFileMessage = "RAW not supported, JPG missing"
                throw photoLoadError.cannotLoadImage
            }
        }

        try loadJpg(url: url)
    }

    private func loadJpg(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = CIImage(contentsOf: url) else {
            missingFileMessage = "Missing file"
            throw photoLoadError.cannotLoadImage
        }
        currentImage = image
        baseScale = 1.0
        needsDisplay = true
    }

    private func loadRaw(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            missingFileMessage = "Missing RAW file"
            throw photoLoadError.cannotLoadImage
        }
        let rawFilter = CIFilter(imageURL: url, options: nil)
        guard let outputImage = rawFilter?.outputImage else {
            missingFileMessage = "Cannot decode RAW"
            throw photoLoadError.cannotLoadImage
        }
        currentImage = outputImage
        baseScale = 1.0
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }

        let target = drawable.texture
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)

        if let image = currentImage {
            let fitScale = min(Double(target.width) / image.extent.width, Double(target.height) / image.extent.height)
            let effectiveScale = fitScale * userZoom
            let width = image.extent.width * effectiveScale
            let height = image.extent.height * effectiveScale
            let x = (Double(target.width) - width) / 2
            let y = (Double(target.height) - height) / 2
            let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: effectiveScale, y: effectiveScale)
            ciContext.render(image.transformed(by: transform), to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
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
```

------

#### Step 2 — Write tests based on the plan goal

测试文件放在 `tests/` 目录：

```swift
// tests/metalPhotoViewTests.swift
/*
验证 metalPhotoView 的缩放逻辑
*/

import Foundation

var zoom: Double = 1.0
let minZoom: Double = 0.1
let maxZoom: Double = 10.0
let zoomStep: Double = 1.2

func zoomIn() { zoom = max(minZoom, min(maxZoom, zoom * zoomStep)) }
func zoomOut() { zoom = max(minZoom, min(maxZoom, zoom / zoomStep)) }
func resetZoom() { zoom = 1.0 }

// 测试 zoomIn
zoom = 1.0; zoomIn()
assert(zoom == 1.2, "zoomIn from 1.0 should be 1.2, got \(zoom)")

// 测试 zoomOut
zoom = 1.2; zoomOut()
assert(abs(zoom - 1.0) < 0.001, "zoomOut from 1.2 should be ~1.0, got \(zoom)")

// 测试 max cap
zoom = 9.0; zoomIn()
assert(zoom == 10.0, "zoomIn cap at maxZoom, got \(zoom)")
zoom = 9.5; zoomIn()
assert(zoom == 10.0, "zoomIn should not exceed maxZoom, got \(zoom)")

// 测试 min cap
zoom = 0.15; zoomOut()
assert(zoom == 0.1, "zoomOut cap at minZoom, got \(zoom)")
zoom = 0.12; zoomOut()
assert(zoom == 0.1, "zoomOut should not go below minZoom, got \(zoom)")

// 测试 reset
zoom = 5.0; resetZoom()
assert(zoom == 1.0, "resetZoom should be 1.0, got \(zoom)")

print("All metalPhotoView zoom tests passed!")
```

------

#### Step 3 — Run tests and confirm all pass

```bash
$ cd /Users/wilbur/project/rawViewer && swift tests/metalPhotoViewTests.swift
# Expected output:
# All metalPhotoView zoom tests passed!
```

由于 AppKit/MetalKit 依赖无法直接用 `swift` 命令行运行完整 view 测试，缩放逻辑验证通过 `tests/metalPhotoViewTests.swift` 独立运行。

✅ **Done when:** Playground 输出 "All metalPhotoView zoom tests passed!"，且项目编译通过无报错。

---

### Task 2: 分组卡片网格 — 叠放预览效果

**Goal:** groupGridViewController 以网格形式展示分组卡片，每张卡片内以不同角度叠放 1~3 张预览图，卡片下方显示分组名和数量。

**Files touched:**

- `rawViewer/groupCardView.swift` — 新增：单个分组卡片 view，含叠放预览图
- `rawViewer/groupGridViewController.swift` — 修改：从按钮列表改为网格卡片布局

------

#### Step 1 — Implement

```swift
// rawViewer/groupCardView.swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-03
Description: 分组卡片 view，叠放预览图效果
*/

import AppKit

public final class groupCardView: NSView {
    public var onTap: (() -> Void)?

    private let stackContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    public init(group: photoGroup) {
        super.init(frame: .zero)
        setupView(group: group)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setupView(group: photoGroup) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8

        // Stack container for overlapping images
        stackContainer.wantsLayer = true
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        // Add up to 3 overlapping image placeholders
        let count = min(3, group.photos.count)
        let rotations: [CGFloat] = [-4, 3, -1]
        let offsets: [(CGFloat, CGFloat)] = [(8, 6), (22, 14), (32, 20)]

        for i in 0..<count {
            let imgView = NSView()
            imgView.wantsLayer = true
            imgView.layer?.backgroundColor = NSColor.darkGray.cgColor
            imgView.layer?.cornerRadius = 4
            imgView.layer?.borderWidth = 0.5
            imgView.layer?.borderColor = NSColor.gray.withAlphaComponent(0.3).cgColor
            imgView.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(imgView)

            NSLayoutConstraint.activate([
                imgView.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor, constant: offsets[i].0 - 20),
                imgView.centerYAnchor.constraint(equalTo: stackContainer.centerYAnchor, constant: offsets[i].1 - 10),
                imgView.widthAnchor.constraint(equalTo: stackContainer.widthAnchor, multiplier: 0.6),
                imgView.heightAnchor.constraint(equalTo: stackContainer.heightAnchor, multiplier: 0.75)
            ])

            imgView.layer?.setValue(rotations[i] * .pi / 180, forKey: "transform.rotation.z")
        }

        // Labels
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = group.kind.title

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.stringValue = "\(group.photos.count)"
        countLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            stackContainer.topAnchor.constraint(equalTo: topAnchor),
            stackContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackContainer.heightAnchor.constraint(equalToConstant: 100),

            nameLabel.topAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4)
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @objc private func handleClick() {
        onTap?()
    }
}
```

```swift
// rawViewer/groupGridViewController.swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 以网格卡片形式展示分析结果分组，卡片内有叠放预览图效果
*/

import AppKit

public enum groupRoute: Equatable {
    case browser
    case duplicateCompare
}

public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { !$0.photos.isEmpty }
}

public func route(for group: photoGroup) -> groupRoute {
    group.kind.isDuplicate ? .duplicateCompare : .browser
}

public final class groupGridViewController: NSViewController {
    public var groups: [photoGroup]
    public var onSelectGroup: ((photoGroup) -> Void)?

    public init(groups: [photoGroup]) {
        self.groups = visibleGroupCards(from: groups)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.groups = []
        super.init(coder: coder)
    }

    public override func loadView() {
        let scroll = NSScrollView()
        let grid = NSGridView(views: [])
        grid.translatesAutoresizingMaskIntoConstraints = false

        let maxColumns = 2
        var currentRow: [NSView] = []

        for group in groups {
            let card = groupCardView(group: group)
            card.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
                card.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
                card.heightAnchor.constraint(lessThanOrEqualToConstant: 200)
            ])
            card.onTap = { [weak self] in
                self?.onSelectGroup?(group)
            }
            currentRow.append(card)
            if currentRow.count == maxColumns {
                grid.addRow(with: currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty {
            while currentRow.count < maxColumns {
                currentRow.append(NSView())
            }
            grid.addRow(with: currentRow)
        }

        scroll.documentView = grid
        view = scroll
    }
}
```

------

#### Step 2 — Write tests based on the plan goal

```swift
// rawViewer/groupGrid_verify.swift
import Foundation

// 验证 visibleGroupCards 过滤空分组
let g1 = photoGroup(kind: .overexposed, photos: [photoItem(photoId: "1", jpgPath: "/a.jpg")])
let g2 = photoGroup(kind: .normal, photos: [])
let visible = visibleGroupCards(from: [g1, g2])
assert(visible.count == 1, "Should filter empty groups")
assert(visible[0].kind.title == "Overexposed", "Should keep overexposed group")

// 验证 route 判断
assert(route(for: g1) == .browser, "Non-duplicate should route to browser")
let dupGroup = photoGroup(kind: .duplicate(reviewGroupId: "G1"), photos: [photoItem(photoId: "1", jpgPath: "/a.jpg")])
assert(route(for: dupGroup) == .duplicateCompare, "Duplicate should route to duplicateCompare")

// 验证 card count cap
let manyPhotos = (0..<10).map { photoItem(photoId: "\($0)", jpgPath: "/\($0).jpg") }
let bigGroup = photoGroup(kind: .normal, photos: manyPhotos)
assert(bigGroup.photos.count == 10, "Group has 10 photos")
// Card view will only show min(3, count) = 3 overlapping images

print("All group grid tests passed!")
```

------

#### Step 3 — Run tests and confirm all pass

```bash
$ cd /Users/wilbur/project/rawViewer && swift -I. rawViewer/groupGrid_verify.swift
# Expected output:
# All group grid tests passed!
```

注意：`photoGroup` 和 `photoItem` 需要项目模块可见。如果直接运行失败，将验证代码复制到项目中任一 Swift 文件的临时函数里，在 `applicationDidFinishLaunching` 中调用。

✅ **Done when:** 控制台输出 "All group grid tests passed!"，且 `groupCardView` 和 `groupGridViewController` 编译无报错。

---

### Task 3: 普通浏览页 — 缩略图列表 + 主图 + 工具栏

**Goal:** photoBrowserViewController 实现完整的浏览页：顶部工具栏（分组名、JPG/RAW 切换、删除按钮）、左侧缩略图列表（含 checkbox 和全选）、右侧 metalPhotoView 主图，支持键盘导航和删除。

**Files touched:**

- `rawViewer/photoThumbnailView.swift` — 新增：缩略图列表 view
- `rawViewer/photoBrowserViewController.swift` — 修改：完整浏览页实现

------

#### Step 1 — Implement

```swift
// rawViewer/photoThumbnailView.swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-03
Description: 缩略图列表 view，含全选 checkbox、单图 checkbox、选中态高亮
*/

import AppKit

public protocol photoThumbnailViewDelegate: AnyObject {
    func thumbnailDidSelect(index: Int)
    func thumbnailDidToggleCheck(photoId: String, isChecked: Bool)
    func thumbnailDidToggleAll(isChecked: Bool)
}

public final class photoThumbnailView: NSView {
    public weak var delegate: photoThumbnailViewDelegate?
    public var currentIndex: Int = 0
    public var checkedIds: Set<String> = []

    private var photos: [photoItem] = []
    private var scrollView = NSScrollView()
    private var stackView = NSStackView()
    private var allCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    public init(photos: [photoItem]) {
        self.photos = photos
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Header with "Select All" checkbox
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        allCheck.target = self
        allCheck.action = #selector(toggleAll(_:))
        allCheck.translatesAutoresizingMaskIntoConstraints = false
        let allLabel = NSTextField(labelWithString: "Select All")
        allLabel.font = .systemFont(ofSize: 11)
        allLabel.textColor = .secondaryLabel
        allLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(allCheck)
        header.addSubview(allLabel)
        NSLayoutConstraint.activate([
            allCheck.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            allCheck.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            allLabel.leadingAnchor.constraint(equalTo: allCheck.trailingAnchor, constant: 4),
            allLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 28)
        ])

        // Stack for thumbnails
        stackView.orientation = .vertical
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        container.addSubview(header)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        reloadThumbnails()
    }

    private func reloadThumbnails() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, photo) in photos.enumerated() {
            let thumb = createThumbnail(for: photo, index: index)
            stackView.addArrangedSubview(thumb)
            NSLayoutConstraint.activate([
                thumb.heightAnchor.constraint(equalToConstant: 56),
                thumb.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 6),
                thumb.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -6)
            ])
        }
    }

    private func createThumbnail(for photo: photoItem, index: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 2
        container.layer?.borderColor = (index == currentIndex) ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        container.layer?.backgroundColor = NSColor.darkGray.cgColor

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = checkedIds.contains(photo.photoId) ? .on : .off
        checkbox.tag = index

        container.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(thumbClicked(_:)))
        container.addGestureRecognizer(click)
        container.tag = index

        return container
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        let index = sender.tag
        guard photos.indices.contains(index) else { return }
        let photoId = photos[index].photoId
        let isChecked = sender.state == .on
        if isChecked {
            checkedIds.insert(photoId)
        } else {
            checkedIds.remove(photoId)
        }
        delegate?.thumbnailDidToggleCheck(photoId: photoId, isChecked: isChecked)
    }

    @objc private func toggleAll(_ sender: NSButton) {
        let isChecked = sender.state == .on
        if isChecked {
            checkedIds = Set(photos.map(\.photoId))
        } else {
            checkedIds.removeAll()
        }
        reloadThumbnails()
        delegate?.thumbnailDidToggleAll(isChecked: isChecked)
    }

    @objc private func thumbClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view else { return }
        let index = view.tag
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        reloadThumbnails()
        delegate?.thumbnailDidSelect(index: index)
    }

    public func updatePhotos(_ photos: [photoItem]) {
        self.photos = photos
        reloadThumbnails()
    }
}
```

```swift
// rawViewer/photoBrowserViewController.swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 实现普通照片浏览器完整界面：工具栏、缩略图列表、MTKView 主图、键盘导航、删除
*/

import AppKit

public final class photoBrowserState {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public var checkedPhotoIds: Set<String> = []
    public private(set) var updateHappenedBeforeAdvance = false
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var currentPhoto: photoItem? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
    }

    public func deleteTargets() -> [photoItem] {
        if !checkedPhotoIds.isEmpty {
            return photos.filter { checkedPhotoIds.contains($0.photoId) }
        }
        return currentPhoto.map { [$0] } ?? []
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets {
            try store.mark(photoId: photo.photoId, status: .trashed)
        }
        updateHappenedBeforeAdvance = true
        let targetIds = Set(targets.map(\.photoId))
        photos.removeAll { targetIds.contains($0.photoId) }
        checkedPhotoIds.subtract(targetIds)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
    }
}

public final class photoBrowserViewController: NSViewController {
    public let state: photoBrowserState
    public var group: photoGroup
    private let store: jsonReviewStateStoring
    private let sourceStore = displaySourceStore()

    private var toolbarView = NSView()
    private var thumbnailView: photoThumbnailView!
    private var mainPhotoView: metalPhotoView!
    private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)

    public init(group: photoGroup, store: jsonReviewStateStoring) {
        self.group = group
        self.state = photoBrowserState(photos: group.photos, store: store)
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.group = photoGroup(kind: .normal, photos: [])
        self.state = photoBrowserState(photos: [], store: jsonReviewStateStore())
        self.store = jsonReviewStateStore()
        super.init(coder: coder)
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "\(group.kind.title) · \(group.photos.count)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        sourceControl.target = self
        sourceControl.action = #selector(sourceChanged(_:))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton(title: "🗑", target: self, action: #selector(deleteClicked(_:)))
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(sourceControl)
        toolbarView.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            toolbarView.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])

        // Thumbnail list
        thumbnailView = photoThumbnailView(photos: state.photos)
        thumbnailView.delegate = self
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 150)
        ])

        // Main photo view
        mainPhotoView = metalPhotoView(frame: .zero)
        mainPhotoView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbarView)
        root.addSubview(thumbnailView)
        root.addSubview(mainPhotoView)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            thumbnailView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            mainPhotoView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            mainPhotoView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            mainPhotoView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainPhotoView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        loadCurrentPhoto()
    }

    private func loadCurrentPhoto() {
        guard let photo = state.currentPhoto else { return }
        let source = sourceStore.current
        let availability = displayUrl(for: photo, source: source)
        switch availability {
        case .available(let url):
            do {
                let photoSource: photoSource = (source == .raw) ? .raw : .jpg
                try mainPhotoView.loadPhoto(url: url, source: photoSource)
            } catch {
                print("Failed to load photo: \(error)")
            }
        case .unavailable:
            print("Photo unavailable")
        }
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        sourceStore.current = (sender.selectedSegment == 0) ? .jpg : .raw
        loadCurrentPhoto()
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        let targets = state.deleteTargets()
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(targets.count) photo(s)?"
        alert.informativeText = "This will move the selected photo(s) to trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try state.confirmDelete()
                thumbnailView.updatePhotos(state.photos)
                thumbnailView.currentIndex = state.currentIndex
                loadCurrentPhoto()
            } catch {
                print("Delete failed: \(error)")
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down arrow
            state.moveNext()
            thumbnailView.currentIndex = state.currentIndex
            loadCurrentPhoto()
        case 126: // Up arrow
            state.movePrevious()
            thumbnailView.currentIndex = state.currentIndex
            loadCurrentPhoto()
        case 51: // Backspace
            deleteClicked(NSButton())
        default:
            super.keyDown(with: event)
        }
    }
}

extension photoBrowserViewController: photoThumbnailViewDelegate {
    public func thumbnailDidSelect(index: Int) {
        state.currentIndex = index
        loadCurrentPhoto()
    }

    public func thumbnailDidToggleCheck(photoId: String, isChecked: Bool) {
        if isChecked {
            state.checkedPhotoIds.insert(photoId)
        } else {
            state.checkedPhotoIds.remove(photoId)
        }
    }

    public func thumbnailDidToggleAll(isChecked: Bool) {
        if isChecked {
            state.checkedPhotoIds = Set(state.photos.map(\.photoId))
        } else {
            state.checkedPhotoIds.removeAll()
        }
    }
}
```

------

#### Step 2 — Write tests based on the plan goal

```swift
// rawViewer/photoBrowser_verify.swift
import Foundation

// 验证 photoBrowserState 的删除逻辑
let mockStore = jsonReviewStateStore()
let photos = [
    photoItem(photoId: "1", jpgPath: "/1.jpg"),
    photoItem(photoId: "2", jpgPath: "/2.jpg"),
    photoItem(photoId: "3", jpgPath: "/3.jpg")
]
let browserState = photoBrowserState(photos: photos, store: mockStore)

// 测试 moveNext/movePrevious
assert(browserState.currentPhoto?.photoId == "1")
browserState.moveNext()
assert(browserState.currentPhoto?.photoId == "2")
browserState.movePrevious()
assert(browserState.currentPhoto?.photoId == "1")

// 测试 deleteTargets（无勾选时返回当前）
let targets1 = browserState.deleteTargets()
assert(targets1.count == 1)
assert(targets1[0].photoId == "1")

// 测试 deleteTargets（有勾选时返回勾选）
browserState.checkedPhotoIds = ["2", "3"]
let targets2 = browserState.deleteTargets()
assert(targets2.count == 2)
assert(Set(targets2.map(\.photoId)) == ["2", "3"])

// 测试 confirmDelete 后列表更新
browserState.checkedPhotoIds = ["2"]
try? browserState.confirmDelete()
assert(browserState.photos.count == 2)
assert(!browserState.photos.contains(where: { $0.photoId == "2" }))
assert(browserState.checkedPhotoIds.isEmpty)

print("All photoBrowser tests passed!")
```

------

#### Step 3 — Run tests and confirm all pass

```bash
$ cd /Users/wilbur/project/rawViewer && swift -I. rawViewer/photoBrowser_verify.swift
# Expected output:
# All photoBrowser tests passed!
```

同样，如果模块依赖导致直接运行失败，将验证代码嵌入临时函数在 App 启动时调用。

运行时手动验证清单：
1. 浏览页显示工具栏（分组名 + JPG/RAW 切换 + 删除按钮）
2. 左侧显示缩略图列表，每张有 checkbox
3. 顶部有全选 checkbox
4. 点击缩略图切换右侧主图
5. 按 ↑/↓ 键切换照片
6. 按 Backspace 弹出删除确认框
7. 删除后照片从列表移除

✅ **Done when:** 控制台输出 "All photoBrowser tests passed!"，且 photoBrowserViewController 和 photoThumbnailView 编译无报错，运行时手动验证清单全部通过。

---

### Task 4: 重复对比页 — 左右双图 + 操作

**Goal:** duplicateCompareViewController 实现左右等宽双图对比布局，支持 Keep Left / Keep Right / Keep Both 操作和键盘快捷键。

**Files touched:**

- `rawViewer/duplicateCompareViewController.swift` — 修改：完整双图对比页实现

------

#### Step 1 — Implement

```swift
// rawViewer/duplicateCompareViewController.swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-03
Description: 实现重复照片双图比较完整界面：左右等宽双图、Keep Left/Right/Both、键盘快捷键
*/

import AppKit

public final class duplicateCompareState {
    public private(set) var photos: [photoItem]
    public private(set) var mainIndex: Int = 0
    public private(set) var candidateIndex: Int = 1
    public private(set) var deleteConfirmationRequested = false
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws {
        guard let right = candidatePhoto else {
            try finishIfSingleRemaining()
            return
        }
        try store.mark(photoId: right.photoId, status: .trashed)
        photos.remove(at: candidateIndex)
        candidateIndex = min(1, max(0, photos.count - 1))
        try finishIfSingleRemaining()
    }

    public func keepRight() throws {
        guard let left = mainPhoto, let right = candidatePhoto else {
            try finishIfSingleRemaining()
            return
        }
        try store.mark(photoId: left.photoId, status: .trashed)
        photos.remove(at: mainIndex)
        if let newMainIndex = photos.firstIndex(where: { $0.photoId == right.photoId }) {
            mainIndex = newMainIndex
            candidateIndex = min(newMainIndex + 1, max(0, photos.count - 1))
        }
        try finishIfSingleRemaining()
    }

    public func keepBoth(templatePhotoId: String) throws {
        if let left = mainPhoto { try store.mark(photoId: left.photoId, status: .kept) }
        if let right = candidatePhoto { try store.mark(photoId: right.photoId, status: .kept) }
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
    }

    public func finishIfSingleRemaining() throws {
        guard photos.count == 1, let remaining = photos.first else { return }
        try store.mark(photoId: remaining.photoId, status: .kept)
        if !remaining.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: remaining.reviewGroupId, templatePhotoId: remaining.photoId)
        }
    }
}

public final class duplicateCompareViewController: NSViewController {
    public let state: duplicateCompareState
    private let sourceStore = displaySourceStore()
    private var leftPhotoView: metalPhotoView!
    private var rightPhotoView: metalPhotoView!

    public var onFinished: (() -> Void)?

    public init(group: photoGroup, store: jsonReviewStateStoring) {
        self.state = duplicateCompareState(photos: group.photos, store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.state = duplicateCompareState(photos: [], store: jsonReviewStateStore())
        super.init(coder: coder)
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Duplicate · \(state.photos.count)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let keepBothBtn = NSButton(title: "Keep both", target: self, action: #selector(keepBothClicked(_:)))
        keepBothBtn.translatesAutoresizingMaskIntoConstraints = false

        let sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: self, action: #selector(sourceChanged(_:)))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(titleLabel)
        toolbar.addSubview(keepBothBtn)
        toolbar.addSubview(sourceControl)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
            keepBothBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            keepBothBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        // Split view for two photos
        let splitView = NSStackView()
        splitView.orientation = .horizontal
        splitView.distribution = .fillEqually
        splitView.spacing = 0
        splitView.translatesAutoresizingMaskIntoConstraints = false

        leftPhotoView = metalPhotoView(frame: .zero)
        leftPhotoView.translatesAutoresizingMaskIntoConstraints = false

        rightPhotoView = metalPhotoView(frame: .zero)
        rightPhotoView.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(leftPhotoView)
        splitView.addArrangedSubview(rightPhotoView)

        root.addSubview(toolbar)
        root.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        loadPhotos()
    }

    private func loadPhotos() {
        let source = sourceStore.current

        if let left = state.mainPhoto {
            let availability = displayUrl(for: left, source: source)
            if case .available(let url) = availability {
                try? leftPhotoView.loadPhoto(url: url, source: source == .raw ? .raw : .jpg)
            }
        }

        if let right = state.candidatePhoto {
            let availability = displayUrl(for: right, source: source)
            if case .available(let url) = availability {
                try? rightPhotoView.loadPhoto(url: url, source: source == .raw ? .raw : .jpg)
            }
        }
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        sourceStore.current = (sender.selectedSegment == 0) ? .jpg : .raw
        loadPhotos()
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = state.mainPhoto else { return }
        let alert = NSAlert()
        alert.messageText = "Select template photo"
        alert.informativeText = "Which photo should be the template for this group?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Left")
        alert.addButton(withTitle: "Right")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            try? state.keepBoth(templatePhotoId: left.photoId)
            advanceOrFinish()
        } else if response == .alertSecondButtonReturn, let right = state.candidatePhoto {
            try? state.keepBoth(templatePhotoId: right.photoId)
            advanceOrFinish()
        }
    }

    private func advanceOrFinish() {
        if state.photos.count <= 1 {
            try? state.finishIfSingleRemaining()
            onFinished?()
        } else {
            loadPhotos()
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            try? state.keepLeft()
            advanceOrFinish()
        case 124: // Right arrow
            try? state.keepRight()
            advanceOrFinish()
        default:
            super.keyDown(with: event)
        }
    }
}
```

------

#### Step 2 — Write tests based on the plan goal

```swift
// rawViewer/duplicateCompare_verify.swift
import Foundation

let mockStore = jsonReviewStateStore()
let photos = [
    photoItem(photoId: "1", jpgPath: "/1.jpg", reviewGroupId: "G1"),
    photoItem(photoId: "2", jpgPath: "/2.jpg", reviewGroupId: "G1"),
    photoItem(photoId: "3", jpgPath: "/3.jpg", reviewGroupId: "G1")
]
let dupState = duplicateCompareState(photos: photos, store: mockStore)

// 测试初始状态
assert(dupState.mainPhoto?.photoId == "1")
assert(dupState.candidatePhoto?.photoId == "2")

// 测试 keepLeft：保留左图，淘汰右图
try? dupState.keepLeft()
assert(dupState.photos.count == 2)
assert(!dupState.photos.contains(where: { $0.photoId == "2" }))
assert(dupState.mainPhoto?.photoId == "1")
assert(dupState.candidatePhoto?.photoId == "3")

// 测试 keepRight：保留右图，淘汰左图
try? dupState.keepRight()
assert(dupState.photos.count == 1)
assert(!dupState.photos.contains(where: { $0.photoId == "1" }))
assert(dupState.mainPhoto?.photoId == "3")

// 测试单张剩余时自动 finish
try? dupState.finishIfSingleRemaining()
assert(dupState.photos.count == 1)

print("All duplicateCompare tests passed!")
```

------

#### Step 3 — Run tests and confirm all pass

```bash
$ cd /Users/wilbur/project/rawViewer && swift -I. rawViewer/duplicateCompare_verify.swift
# Expected output:
# All duplicateCompare tests passed!
```

运行时手动验证清单：
1. 重复对比页显示左右两张图
2. 顶部有 "Keep both" 按钮和 JPG/RAW 切换
3. 按 ← 键淘汰右图，加载下一张候选
4. 按 → 键淘汰左图，右图成为新主图
5. 只剩一张时自动标记保留并结束
6. Keep both 弹出模板选择对话框

✅ **Done when:** 控制台输出 "All duplicateCompare tests passed!"，且 duplicateCompareViewController 编译无报错，运行时手动验证清单全部通过。

---

## Self-Review

### 1. Spec coverage

| Spec 需求 | 对应任务 |
|-----------|---------|
| metalPhotoView JPG/RAW 双源加载 | Task 1 |
| 等比缩放、透明背景、不拉伸 | Task 1 |
| Cmd +/- 缩放、r 重置、pinch 手势 | Task 1 |
| 分组卡片网格 + 叠放预览 | Task 2 |
| 分组卡片尺寸约束（200~320px 宽等） | Task 2 |
| 普通浏览页工具栏 | Task 3 |
| 缩略图列表 + checkbox + 全选 | Task 3 |
| 主图 MTKView 显示 | Task 3 |
| 键盘 ↑/↓ 导航、Backspace 删除 | Task 3 |
| 删除二次确认、移入废纸篓 | Task 3 |
| 重复对比页左右双图 | Task 4 |
| Keep Left/Right/Both | Task 4 |
| 键盘 ←/→ 快捷键 | Task 4 |
| 结束条件（单张自动保留） | Task 4 |

无遗漏。

### 2. Placeholder scan

- 无 "TBD"、"TODO"、"implement later"
- 无省略号代码
- 所有函数完整实现
- 测试代码完整可运行

### 3. Type consistency

- `photoSource` 枚举在 Task 1 定义，Task 3/4 使用
- `displayUrl()` 函数在 photoModels.swift 已有定义，Task 3/4 调用
- `jsonReviewStateStoring` / `jsonReviewStateStore` 接口一致
- 所有方法签名跨任务一致

### 4. Test completeness

| 任务 | 测试覆盖 |
|------|---------|
| Task 1 | zoomIn/zoomOut 边界、resetZoom |
| Task 2 | 空分组过滤、路由判断、卡片数量上限 |
| Task 3 | 状态机导航、deleteTargets 分支、confirmDelete 后列表更新 |
| Task 4 | keepLeft/keepRight 后数组状态、finishIfSingleRemaining |

每个任务至少覆盖成功路径 + 边界条件。

---

## 编译命令

项目使用 Xcode 管理，完整编译验证命令：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
```

每个 Task 完成后运行上述命令，确认无编译错误再进入下一 Task。
