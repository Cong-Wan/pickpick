# Metal View Controller 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建 photoMetalViewController 包装 metalPhotoView，增加 NSPanGestureRecognizer 拖动支持、状态管理（empty/loaded/zoomed/panned）和 reset() 清空能力

**Architecture:** photoMetalViewController 作为 NSViewController 内嵌 metalPhotoView，在其外层容器添加 pan 手势。metalPhotoView 新增 panOffset 属性并在 draw() 中使用。设置 isPaused=true + enableSetNeedsDisplay=true 停止持续渲染。

**Tech Stack:** Swift, AppKit, MetalKit, CoreImage

**Depends on:** 无（可与 Plan 1 并行执行）

---

### Task 1: Add panOffset to metalPhotoView

**Goal:** 在 metalPhotoView 中新增 panOffset 属性，draw() 方法将 panOffset 加入变换矩阵；设置 isPaused=true + enableSetNeedsDisplay=true

**Files touched:**

- `rawViewer/metalPhotoView.swift` — 新增 panOffset 属性，修改 draw() 变换

------

#### Step 1 — Implement

在 `metalPhotoView` 类中新增 `panOffset` 属性和 `setPanOffset` 方法，并修改 `draw()` 中的变换计算。

**新增属性**（在 `userZoom` 声明之后）：

```swift
    private var panOffset: CGPoint = .zero
```

**新增公开方法**（在 `resetZoom()` 之后）：

```swift
    public func setPanOffset(_ offset: CGPoint) {
        panOffset = offset
        needsDisplay = true
    }

    public func resetPan() {
        panOffset = .zero
        needsDisplay = true
    }
```

**修改 draw() 中变换矩阵**（替换现有的 `x`/`y` 计算）：

将：
```swift
            let x = (Double(target.width) - width) / 2
            let y = (Double(target.height) - height) / 2
```

改为：
```swift
            let x = (Double(target.width) - width) / 2 + panOffset.x
            let y = (Double(target.height) - height) / 2 + panOffset.y
```

**在两个 init 方法中设置暂停渲染**（在 `setupGestures()` 调用之后添加）：

```swift
        isPaused = true
        enableSetNeedsDisplay = true
```

------

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过，现有调用方无需任何改动。**Do not start the next task until this condition is met.**

------

### Task 2: Create photoMetalViewController

**Goal:** 新建 photoMetalViewController，内嵌 metalPhotoView，添加 NSPanGestureRecognizer 管理拖动，提供 load(image:) / reset() / zoomIn/Out/resetZoom 接口

**Files touched:**

- `rawViewer/photoMetalViewController.swift` — Metal 视图控制器（新建）

------

#### Step 1 — Implement

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: Metal 视图控制器，包装 metalPhotoView 并管理缩放/平移/加载/空态四态状态机；NSPanGestureRecognizer 提供拖动支持
*/

import AppKit
import CoreImage

public final class photoMetalViewController: NSViewController {
    private let metalView = metalPhotoView()
    private var panOffset: CGPoint = .zero

    public private(set) var hasImage: Bool = false

    public var currentZoom: Double { metalView.currentZoom }

    public var onZoomChanged: ((Double) -> Void)? {
        get { metalView.onZoomChanged }
        set { metalView.onZoomChanged = newValue }
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        metalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        container.addGestureRecognizer(pan)

        view = container
    }

    // MARK: - 状态 API

    public func load(image: CIImage?) {
        if let image {
            metalView.setImage(image)
            hasImage = true
        } else {
            metalView.clearImage()
            hasImage = false
        }
    }

    public func reset() {
        metalView.clearImage()
        metalView.resetZoom()
        metalView.resetPan()
        panOffset = .zero
        hasImage = false
    }

    public func showError(_ message: String) {
        metalView.showError(message)
        hasImage = false
    }

    // MARK: - 缩放

    public func zoomIn() { metalView.zoomIn() }
    public func zoomOut() { metalView.zoomOut() }
    public func resetZoom() {
        metalView.resetZoom()
        panOffset = .zero
        metalView.setPanOffset(.zero)
    }

    // MARK: - Pan

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: view)
            panOffset.x += translation.x
            // AppKit 坐标系 Y 向上为正，Metal 坐标系也 Y 向上为正，但手势 translation Y 向下为正
            panOffset.y -= translation.y
            gesture.setTranslation(.zero, in: view)
            metalView.setPanOffset(panOffset)
        default:
            break
        }
    }

    // MARK: - Key events

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

#### Step 2 — Verify compilation

将文件添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。photoMetalViewController 尚未被任何现有代码使用，仅作为新建文件存在。
