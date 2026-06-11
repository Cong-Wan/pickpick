## 代码审核报告 — Restore Normal 与照片旋转持久化

### 总览
- 审核文件：9 个
  - `rawViewer/models/photoModels.swift`
  - `rawViewer/models/jsonReviewStateStore.swift`
  - `rawViewer/views/photoMetalViewController.swift`
  - `rawViewer/views/metalPhotoView.swift`
  - `rawViewer/browser/photoBrowserViewModel.swift`
  - `rawViewer/browser/photoBrowserViewController.swift`
  - `rawViewer/appCoordinator.swift`
  - `rawViewer/duplicate/duplicateCompareViewModel.swift`
  - `rawViewer/duplicate/duplicateCompareViewController.swift`
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 2 个
- 整体评价：实现路径符合计划：状态落在 `photoItem.rotationDegrees`，通过 `jsonReviewStateStore` 持久化，展示层只做 CIImage 渲染变换，没有改动原始文件。未发现会阻断功能的正确性问题。

---

### 问题清单

### 🔵 Low — 左侧 StackView 没有显式指定分布策略

**位置**: `rawViewer/browser/photoBrowserViewController.swift:133-146`

**问题**: `leftPanel` 采用 `NSStackView` 垂直布局按钮与缩略图列表，但没有显式设置 `distribution`。当前代码可编译，通常也能工作；不过 AppKit 默认分布策略不如显式 `.fill` 直观，后续如果 `photoThumbnailView` 的 intrinsic size 或 hugging priority 变化，缩略图区域可能不如预期填满剩余高度。

**修复方案**:

```swift
let leftPanel = NSStackView()
leftPanel.orientation = .vertical
leftPanel.distribution = .fill
leftPanel.spacing = 6
leftPanel.translatesAutoresizingMaskIntoConstraints = false
```

这属于稳健性改善，不影响当前构建结果。

---

### 🔵 Low — `photoItem` 自定义 Codable 为规避同名遮蔽使用 typealias，可读性一般

**位置**: `rawViewer/models/photoModels.swift:127-150`

**问题**: 因项目类型名采用小驼峰，`reviewStatus` 类型与 `photoItem.reviewStatus` 属性同名，自定义解码时需要 `itemReviewStatus` typealias 消歧。实现是正确的，但读者需要额外理解这是 Swift 名称解析遮蔽问题。

**修复方案**:

保持当前实现即可；如果未来允许类型名使用 Swift 常规 UpperCamelCase，可将类型改为 `ReviewStatus`，并移除 typealias：

```swift
self.reviewStatus = try container.decode(ReviewStatus.self, forKey: .reviewStatus)
```

当前项目规范要求小驼峰，因此本项只是可读性记录，不建议在本次任务中改动。

---

### 优点记录

- `rotationDegrees` 在模型初始化、解码、编码和 store 写回时都做了归一化，避免非法角度进入持久化状态。
- Store 层新增 `missingPhotoIds` 错误，失败信息可读，控制器失败路径也写入 `appFileLogger`。
- Metal 展示层使用 `CIImage.oriented(forExifOrientation:)`，不修改 JPG/RAW 原文件，符合计划约束。
- 普通页与 duplicate 页都在切换 JPG/RAW fallback 时传递旋转角度，覆盖了主要显示路径。

---

### 修复优先级建议

1. 可选：为 `leftPanel` 显式设置 `.fill`，降低未来布局变化风险。
2. 可选：保留 `itemReviewStatus` 注释或未来统一类型命名后移除该 workaround。

当前没有必须修复的问题。
