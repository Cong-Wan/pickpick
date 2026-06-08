# Keep Both Alert Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当重复分组仅含 2 张照片时，点击 "Keep both" 不再弹出冗余的模板选择窗；同时修复 VC 层硬编码 `.finished` 的问题，使 >=4 张分组能正确继续比较。

**Architecture:** 在 `duplicateCompareViewController.swift` 的 `keepBothClicked` 方法中增加前置条件判断：若 `viewModel.photos.count <= 2` 则直接调用 `viewModel.keepBoth` 并使用其返回值驱动 `handleActionResult`；否则维持现有弹窗逻辑，同样改用真实返回值替代硬编码 `.finished`。

**Tech Stack:** Swift, AppKit (NSAlert, NSViewController)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `rawViewer/duplicateCompareViewController.swift` | 重复照片双图比较界面的视图控制器；本次仅修改 `keepBothClicked` 方法的弹窗与结果处理逻辑 |

---

## Task 1: Fix keepBothClicked alert and result-handling logic

**Goal:** `keepBothClicked` 在分组仅剩 2 张（或更少）时跳过模板选择弹窗直接结束比较；在所有路径下均使用 `viewModel.keepBoth` 的真实返回值驱动界面状态，而非硬编码 `.finished`。

**Files touched:**

- `rawViewer/duplicateCompareViewController.swift` — 修改 `keepBothClicked` 方法，增加 `photos.count <= 2` 前置分支并统一使用返回值

------

#### Step 1 — Implement

将 `rawViewer/duplicateCompareViewController.swift` 完整替换为以下内容（仅文件头与 `keepBothClicked` 方法有变更，其余保持不变）：

```swift
/*
Author: wilbur
Version: 3.1
Date: 2026-06-08
Description: 重复照片双图比较界面，使用 photoMetalViewController 替代直接 metalPhotoView；loadPhotos 时先 reset() 两个 controller；修复 keepBothClicked：2 张时不弹窗，使用 ViewModel 返回值驱动结果
*/

import AppKit
import CoreImage

public final class duplicateCompareViewController: NSViewController {
    public let viewModel: duplicateCompareViewModel
    public let imageService: photoImageService
    public var onBack: (() -> Void)?
    public var onFinished: (() -> Void)?

    private let sourceStore = displaySourceStore()
    private var leftPhotoController: photoMetalViewController!
    private var rightPhotoController: photoMetalViewController!
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?

    public init(viewModel: duplicateCompareViewModel, imageService: photoImageService) {
        self.viewModel = viewModel
        self.imageService = imageService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.viewModel = duplicateCompareViewModel(photos: [], store: jsonReviewStateStore())
        self.imageService = photoImageService()
        super.init(coder: coder)
    }

    deinit {
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let backButton = NSButton(title: "← Back", target: self, action: #selector(backClicked))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Duplicate · \(viewModel.photos.count)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let keepBothBtn = NSButton(title: "Keep both", target: self, action: #selector(keepBothClicked(_:)))
        keepBothBtn.translatesAutoresizingMaskIntoConstraints = false

        let sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: self, action: #selector(sourceChanged(_:)))
        sourceControl.selectedSegment = sourceStore.current == .jpg ? 0 : 1
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(keepBothBtn)
        toolbar.addSubview(sourceControl)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sourceControl.trailingAnchor.constraint(equalTo: keepBothBtn.leadingAnchor, constant: -8),
            keepBothBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            keepBothBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        // Split view for two photo controllers
        let splitView = NSStackView()
        splitView.orientation = .horizontal
        splitView.distribution = .fillEqually
        splitView.spacing = 0
        splitView.translatesAutoresizingMaskIntoConstraints = false

        leftPhotoController = photoMetalViewController()
        rightPhotoController = photoMetalViewController()
        addChild(leftPhotoController)
        addChild(rightPhotoController)

        leftPhotoController.view.translatesAutoresizingMaskIntoConstraints = false
        rightPhotoController.view.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(leftPhotoController.view)
        splitView.addArrangedSubview(rightPhotoController.view)

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
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
        leftPhotoController.reset()
        rightPhotoController.reset()

        if let left = viewModel.mainPhoto {
            let photoId = left.photoId
            leftLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: left)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.mainPhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: true)
                }
            }
        }

        if let right = viewModel.candidatePhoto {
            let photoId = right.photoId
            rightLoadTask = Task { [weak self] in
                guard let self else { return }
                let pair = await self.imageService.preloadDisplayPair(for: right)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.viewModel.candidatePhoto?.photoId == photoId else { return }
                    self.show(pair: pair, source: self.sourceStore.current, isLeft: false)
                }
            }
        }
    }

    private func show(pair: photoDisplayPair, source: displaySource, isLeft: Bool) {
        let selected: photoImageResult
        switch source {
        case .jpg: selected = pair.jpg
        case .raw: selected = pair.raw
        }
        let controller: photoMetalViewController = isLeft ? leftPhotoController : rightPhotoController
        if case .image(let image) = selected {
            controller.load(image: image)
            return
        }
        if case .image(let jpgImage) = pair.jpg {
            controller.load(image: jpgImage)
            return
        }
        controller.showError("No image available")
    }

    @objc private func backClicked() {
        onBack?()
    }

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        sourceStore.current = (sender.selectedSegment == 0) ? .jpg : .raw
        loadPhotos()
    }

    @objc private func keepBothClicked(_ sender: NSButton) {
        guard let left = viewModel.mainPhoto else { return }

        // 若当前仅剩这两张照片（或更少），无需选择模板，直接保留并结束
        if viewModel.photos.count <= 2 {
            let result = try? viewModel.keepBoth(templatePhotoId: left.photoId)
            handleActionResult(result ?? .finished)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Select template photo"
        alert.informativeText = "Which photo should be the template for this group?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Left")
        alert.addButton(withTitle: "Right")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let result = try? viewModel.keepBoth(templatePhotoId: left.photoId)
            handleActionResult(result ?? .finished)
        } else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
            let result = try? viewModel.keepBoth(templatePhotoId: right.photoId)
            handleActionResult(result ?? .finished)
        }
    }

    private func handleActionResult(_ result: duplicateCompareActionResult) {
        switch result {
        case .finished:
            onFinished?()
        case .continueComparing:
            loadPhotos()
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            if let result = try? viewModel.keepLeft() {
                handleActionResult(result)
            }
        case 124: // Right arrow
            if let result = try? viewModel.keepRight() {
                handleActionResult(result)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
```

------

#### Step 2 — Verify manually

编译并运行应用，按以下场景验证：

**场景 A：2 张照片的分组（核心修复目标）**
1. 准备一个仅含 2 张照片的重复分组。
2. 进入该分组的 Compare 界面。
3. 点击 "Keep both"。
4. **预期**：不弹出任何 NSAlert 弹窗，界面直接关闭并返回分组卡片列表；两张照片均进入 normal（或对应曝光/blur）分组，原重复分组消失。

**场景 B：3 张照片的分组**
1. 准备一个含 3 张照片的重复分组。
2. 进入 Compare 界面，点击 "Keep both"。
3. **预期**：不弹出模板选择窗，界面直接关闭返回卡片列表；3 张照片全部被标记为 kept，原重复分组消失（ViewModel 中剩余 1 张会自动 `markFinalKept`）。

**场景 C：4 张照片的分组（关联缺陷修复验证）**
1. 准备一个含 4 张照片的重复分组。
2. 进入 Compare 界面，点击 "Keep both"。
3. **预期**：弹出模板选择窗，选择 "Left" 或 "Right" 后，界面**不关闭**，而是继续显示剩余两张照片的比较视图。
4. 在剩余两张的比较视图中，再次点击 "Keep both"。
5. **预期**：此时仅剩 2 张，不弹窗，直接结束比较，界面关闭。

**场景 D：Cancel 行为**
1. 在 4 张分组的 Compare 界面点击 "Keep both"。
2. 弹窗出现后点击 "Cancel"。
3. **预期**：弹窗关闭，Compare 界面保持原状，未发生任何状态变更。

------

✅ **Done when:** 场景 A、B、C、D 全部符合预期行为，且项目编译无错误、无新增警告。

---

## Self-Review

- **Spec coverage**: Bug 报告中的两个根因（无条件弹窗 + 硬编码 `.finished`）均在本计划的 Task 1 中覆盖。
- **Placeholder scan**: 无 TBD、TODO、省略号或伪代码。
- **Type consistency**: 方法签名 `keepBoth(templatePhotoId:)` 与 `handleActionResult(_:)` 均与现有代码保持一致；返回值类型 `duplicateCompareActionResult` 未变更。
- **Test completeness**: 用户明确要求不写测试代码，以手动验证场景 A/B/C/D 替代。
