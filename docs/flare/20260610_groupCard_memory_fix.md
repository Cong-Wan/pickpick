# groupCardView 内存泄漏修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复分组展示界面 `groupCardView` 预览图加载完整原图导致的内存暴涨问题，改为真正的降采样缩略图加载路径。

**Architecture:** 仅修改 `groupCardView` 中预览图加载的调用方式，将 `loadImage(kind: .thumbnail)` 替换为 `loadThumbnail(for:maxWidth:maxHeight:)`，利用已有的 `photoThumbnailService` 的 `CGImageSourceCreateThumbnailAtIndex` 降采样能力。

**Tech Stack:** Swift / AppKit / macOS

---

## Task 1: 修复 groupCardView 预览图加载路径

**Goal:** 让 `groupCardView` 的 3 张叠放预览图不再加载完整 JPG 原图，而是走 `photoThumbnailService` 的降采样缩略图路径，从而消除分组展示界面内存暴涨。

**Files touched:**

- `rawViewer/views/groupCardView.swift` — 将预览图加载从 `loadImage(kind: .thumbnail)` 改为 `loadThumbnail`

---

### Step 1 — Implement

定位 `groupCardView.swift` 中 `setupView` 方法内加载预览图的循环体。当前代码调用 `imageService.loadImage(for: kind: .thumbnail(width: 160, height: 110))`，这实际上会走 `displayService.loadDisplayJpg`，加载完整原图。

将其替换为 `imageService.loadThumbnail(for: maxWidth: maxHeight:)`，该方法底层使用 `CGImageSourceCreateThumbnailAtIndex` 做真正的降采样加载，不载入完整原图。同时去掉多余的 `CIImage → NSCIImageRep → NSImage` 包装，因为新方法直接返回 `NSImage`。

```swift
// rawViewer/views/groupCardView.swift
// 定位到 setupView 方法中 for i in 0..<count { ... } 循环
// 替换以下内容：

// ===== 旧代码（删除） =====
// let photo = previewPhotos[i]
// let targetView = imgView
// let task = Task { [weak self] in
//     let result = await imageService.loadImage(for: photo, kind: .thumbnail(width: 160, height: 110))
//     if Task.isCancelled { return }
//     await MainActor.run {
//         guard let self = self, self.previewImageViews.contains(targetView) else { return }
//         if case .image(let ciImage) = result {
//             let rep = NSCIImageRep(ciImage: ciImage)
//             let nsImage = NSImage(size: rep.size)
//             nsImage.addRepresentation(rep)
//             targetView.image = nsImage
//         }
//         // .unavailable 时保留 darkGray 占位背景（已在 setupView 设置）
//     }
// }
// loadTasks.append(task)

// ===== 新代码 =====
let photo = previewPhotos[i]
let targetView = imgView
let task = Task { [weak self] in
    let image = await imageService.loadThumbnail(for: photo, maxWidth: 160, maxHeight: 110)
    if Task.isCancelled { return }
    await MainActor.run {
        guard let self = self, self.previewImageViews.contains(targetView) else { return }
        targetView.image = image
        // image 为 nil 时保留 darkGray 占位背景（已在 setupView 设置）
    }
}
loadTasks.append(task)
```

---

### Step 2 — 编译验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
```

**Expected output:** Build Succeeded，无编译错误。

---

### Step 3 — 运行验证内存占用

1. 启动应用，导航至分组展示界面
2. 打开 Activity Monitor，观察应用内存占用
3. 滚动浏览多个分组，观察内存变化

**Expected behavior:**
- 分组展示界面停留时，内存占用应稳定在 **几百 MB** 级别（取决于分组数量和 `photoThumbnailService` 缓存上限 200 张缩略图）
- 滚动时内存不应持续攀升，不会出现 5G+ 的异常占用
- 预览图仍能正常显示（降采样缩略图，尺寸约 160×110）

---

✅ **Done when:** 编译通过，且运行时分组展示界面内存稳定在合理范围（< 1GB），预览图显示正常。

---

## Self-Review Checklist

| 检查项 | 状态 |
|---|---|
| Spec coverage: 根因已定位，修复目标明确 | ✅ |
| Placeholder scan: 无 TBD/TODO/省略号 | ✅ |
| Type consistency: `loadThumbnail` 签名匹配 `photoImageService` 中定义 | ✅ |
| Test completeness: 编译通过 + 运行时内存验证 | ✅ |
