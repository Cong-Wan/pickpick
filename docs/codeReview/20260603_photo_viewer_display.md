## 代码审核报告 — rawViewer 照片浏览与显示系统

### 总览
- 审核文件：6 个
- 发现问题：🔴 0 个 / 🟠 1 个 / 🟡 2 个 / 🔵 2 个
- 整体评价：实现符合计划规格，状态机与视图分离清晰；主要问题集中在 macOS 第一响应器链和 NSScrollView documentView 布局，均已修复。

---

### 问题清单

#### 🟠 [已修复] 第一响应器链未设置，键盘事件无法接收

**位置**: `photoBrowserViewController.swift`、`duplicateCompareViewController.swift`
**问题**: `photoBrowserViewController` 和 `duplicateCompareViewController` 都重写了 `keyDown`，但 macOS 中 key events 只会发送给当前第一响应器。如果不显式设置，键盘快捷键（↑/↓/←/→/Backspace/+/−/r）完全不会生效。
**修复方案**:
```swift
public override var acceptsFirstResponder: Bool { true }

public override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(view)
}
```
同时 `photoBrowserViewController.keyDown` 的 `default` 分支需要显式转发 zoom 键给 `mainPhotoView`（事件不会自动传递到 subview）：
```swift
default:
    switch event.charactersIgnoringModifiers {
    case "=", "+": mainPhotoView.zoomIn()
    case "-": mainPhotoView.zoomOut()
    case "r", "R": mainPhotoView.resetZoom()
    default: super.keyDown(with: event)
    }
```

---

#### 🟡 [已修复] NSScrollView documentView frame 不更新

**位置**: `photoThumbnailView.swift`, `reloadThumbnails()`
**问题**: `scrollView.documentView = stackView` 后，`NSStackView` 使用 Auto Layout 但不会自动更新其在 `NSScrollView` 中的 bounds。当缩略图数量变化时，document size 不会同步，用户可能无法滚动。
**修复方案**:
在 `reloadThumbnails()` 末尾添加：
```swift
stackView.frame.size = stackView.fittingSize
```

---

#### 🟡 [已修复] `deleteClicked` 的语义不清

**位置**: `photoBrowserViewController.swift`, `keyDown` 与 `deleteClicked`
**问题**: 从 `keyDown` 调用删除时创建了一个无意义的空 `NSButton`：`deleteClicked(NSButton())`。这既不必要也不表意。
**修复方案**:
将方法签名改为无参：
```swift
@objc private func deleteClicked() { ... }
```
调用方和 selector 同步更新为 `#selector(deleteClicked)`。

---

#### 🔵 叠放预览图是纯占位符

**位置**: `groupCardView.swift`, `setupView()`
**问题**: 卡片中的 "叠放预览图" 目前是纯色 `NSView`（`backgroundColor = .darkGray`），没有加载真实照片。这是计划中明确说明的 placeholder，不影响功能，但后续迭代需要替换为真实的 `NSImageView` + `CIImage` 缩略图加载。
**严重等级**: Low（预期行为）

---

#### 🔵 `metalPhotoView.onZoomChanged` 未订阅

**位置**: `metalPhotoView.swift`
**问题**: `onZoomChanged` 回调被声明，但没有任何 UI 组件（如 toolbar 上的 zoom 比例标签）订阅它。用户无法看到当前 zoom 比例。
**严重等级**: Low（可选改进）
**修复方案（可选）**:
在 `photoBrowserViewController` 的 toolbar 中添加一个 `NSTextField`，订阅 `mainPhotoView.onZoomChanged` 显示当前比例。

---

### 优点记录

1. **状态机与视图分离**：`photoBrowserState` 和 `duplicateCompareState` 独立于 AppKit 视图，便于测试。所有核心逻辑（删除、导航、索引管理）都在状态机中完成。
2. **pinch 手势修正**：记录了 `pinchStartZoom`，避免了 `NSMagnificationGestureRecognizer` 累积 magnification 导致的缩放跳动。
3. **NSStackView arrangedSubview 正确移除**：`photoThumbnailView.reloadThumbnails()` 中先 `removeArrangedSubview` 再 `removeFromSuperview`，避免了内存泄漏和布局残留。
4. **AppKit layer rotation 修正**：使用 `CATransform3DMakeRotation` 替代了无效的 KVC `transform.rotation.z`。
5. **向后兼容的 `loadPhoto` 签名**：`loadPhoto(url:source:)` 的默认参数 `.jpg` 保证了外部调用者可以平滑迁移。

---

### 修复优先级建议

1. **第一响应器链**（High）— 不修复则所有键盘交互完全失效。
2. **NSScrollView documentView frame**（Medium）— 不修复则缩略图列表在照片数量变化时无法正确滚动。
3. **zoom 比例显示**（Low）— 建议在下一次 UI 迭代中加入，提升用户体验。
