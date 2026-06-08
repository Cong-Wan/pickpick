# Bug：重复分组仅 2 张照片时点击 Keep both 仍弹出模板选择窗

**日期**: 2026-06-08  
**涉及模块**: `duplicateCompareViewController.swift`, `duplicateCompareViewModel.swift`  
**现象**: 当一个重复分组内恰好只有 2 张照片时，用户在比较界面点击 "Keep both" 后，系统仍会弹出一个 NSAlert 要求选择 "Left" 或 "Right" 作为模板照片。此弹窗在该场景下完全冗余。

---

## 一、根因分析

### 1.1 触发点

文件：`rawViewer/duplicateCompareViewController.swift`  
方法：`keepBothClicked(_:)`

```swift
@objc private func keepBothClicked(_ sender: NSButton) {
    guard let left = viewModel.mainPhoto else { return }
    let alert = NSAlert()
    alert.messageText = "Select template photo"
    alert.informativeText = "Which photo should be the template for this group?"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Left")
    alert.addButton(withTitle: "Right")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        _ = try? viewModel.keepBoth(templatePhotoId: left.photoId)
        handleActionResult(.finished)
    } else if response == .alertSecondButtonReturn, let right = viewModel.candidatePhoto {
        _ = try? viewModel.keepBoth(templatePhotoId: right.photoId)
        handleActionResult(.finished)
    }
}
```

**问题**：该方法在点击按钮后**无条件**构造并显示 `NSAlert`，完全没有判断当前分组内的照片数量。无论分组里有 2 张还是 10 张照片，弹窗都会出现。

### 1.2 为什么 2 张时不应该弹窗

`duplicateCompareViewModel.swift` 中 `keepBoth` 的核心逻辑：

```swift
public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
    // 1. 将当前比较的两张都标记为 kept，并清空 reviewGroupId
    if let left = mainPhoto {
        try store.mark(photoId: left.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: left.photoId)
    }
    if let right = candidatePhoto {
        try store.mark(photoId: right.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: right.photoId)
    }

    let keptIds = Set([mainPhoto, candidatePhoto].compactMap { $0?.photoId })
    photos.removeAll { keptIds.contains($0.photoId) }

    switch photos.count {
    case 0:
        return .finished
    case 1:
        if let last = photos.first {
            try markFinalKept(last)
        }
        return .finished
    default:
        // >= 2 张剩余，才需要设置模板并继续比较
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
}
```

当分组**恰好 2 张**时：
- `mainPhoto` 和 `candidatePhoto` 就是这两张的全部。
- `keepBoth` 将它们移除后，`photos.count == 0`。
- 直接返回 `.finished`，**根本不会使用 `templatePhotoId` 参数**。
- 两张照片的 `reviewGroupId` 均已被 `clearReviewGroupId` 清空，不会再有后续照片继承该模板。

因此，在 2 张场景下弹窗让用户选择模板，既无数据层面的意义，也无交互层面的意义，属于纯粹的冗余步骤。

### 1.3 阈值判定

用户确认：当分组有 **3 张**时，点击 Keep both 后剩余 1 张，这 1 张会自动被 `markFinalKept` 处理并返回 `.finished`，**不需要**弹窗。当分组有 **>= 4 张**时，keep both 后还剩 >= 2 张，**需要**弹窗选择模板以继续后续比较。

所以弹窗的合理触发条件是：**移除当前两张后，组内仍有 >= 2 张剩余照片**，即 `viewModel.photos.count > 3`（因为 main+candidate 占 2 张，剩余 >= 2 张意味着总数 >= 4）。

不过为了代码语义清晰，更直观的判断是：在执行 `keepBoth` 之前，如果当前 `photos` 数组中**除了正在比较的两张外没有其他照片**，则跳过弹窗。

---

## 二、关联缺陷：VC 层硬编码 `.finished`

在 `keepBothClicked` 中：

```swift
_ = try? viewModel.keepBoth(templatePhotoId: left.photoId)
handleActionResult(.finished)   // ❌ 硬编码，无视 ViewModel 返回值
```

`viewModel.keepBoth` 在分组 >= 4 张时返回 `.continueComparing`，但 VC 层却强行调用 `handleActionResult(.finished)`，导致界面直接关闭而不是加载下一组比较照片。

**此问题与 2 张弹窗问题独立，但同在 `keepBothClicked` 方法中，建议一并修复。**

---

## 三、修复方案

### 3.1 修复 2 张时不弹窗

修改 `duplicateCompareViewController.swift` 的 `keepBothClicked`：

```swift
@objc private func keepBothClicked(_ sender: NSButton) {
    guard let left = viewModel.mainPhoto else { return }

    // 若当前仅剩这两张照片，无需选择模板，直接保留并结束
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
```

**关键变更**：
1. 在弹窗之前增加 `viewModel.photos.count <= 2` 的早期返回路径。
2. 早期返回时传入 `left.photoId`（任意一个即可，ViewModel 不会实际使用它）。
3. 使用 `viewModel.keepBoth` 的真实返回值驱动 `handleActionResult`，替代硬编码的 `.finished`。

### 3.2 为什么用 `photos.count <= 2` 而非其他条件

- `photos.count == 2` 是最直接的场景：只有正在比较的两张，无剩余。
- 使用 `<= 2` 作为防御性编程：如果因某种边界情况只剩 1 张（理论上不应进入 Compare 界面，但防御一下无害），同样不需要弹窗。

### 3.3 验证标准

1. 创建一个恰好 2 张照片的重复分组，进入 Compare 界面，点击 "Keep both"。
2. **预期**：不弹出模板选择窗，直接返回卡片界面，两张照片均进入 normal（或对应曝光）分组。
3. 创建一个 4 张照片的重复分组，进入 Compare 界面，点击 "Keep both"。
4. **预期**：弹出模板选择窗，选择后界面继续显示剩余两张照片的比较视图。

---

## 四、关联代码索引

| 文件 | 方法/区域 | 说明 |
|-----|----------|------|
| `rawViewer/duplicateCompareViewController.swift` | `keepBothClicked(_:)` | Bug 发生点：无条件弹窗 + 硬编码 `.finished` |
| `rawViewer/duplicateCompareViewModel.swift` | `keepBoth(templatePhotoId:)` | 2 张时返回 `.finished`，不消费模板 ID |
| `rawViewer/duplicateCompareViewModel.swift` | `photos` 数组 | `count` 用于判定是否还有剩余照片 |
