# groupCardView 内存泄漏修复方案

## 问题

分组展示界面停留时，内存占用高达 **5.77G**，远超正常水平。

## 根因分析

`groupCardView` 在加载卡片上的 3 张叠放预览图时，调用了：

```swift
imageService.loadImage(for: photo, kind: .thumbnail(width: 160, height: 110))
```

但 `photoImageService.loadImage` 对 `.thumbnail` case 的实现是：

```swift
case .thumbnail(let width, let height):
    let result = await displayService.loadDisplayJpg(for: photo)  // ← 加载完整原图
```

这意味着每张"缩略图"实际上都是**完整 JPG 原图**（可能几十到几百 MB 解码后），卡片上同时加载 3 张，随着滚动不断触发，内存直接爆炸。

## 修复方案

**改动文件：`rawViewer/views/groupCardView.swift`**

把预览图加载逻辑从 `loadImage(kind: .thumbnail)` 改为真正的降采样缩略图 API `loadThumbnail(for:maxWidth:maxHeight:)`，同时去掉多余的 CIImage → NSImage 包装。

### 代码变更

```swift
// 替换前
let result = await imageService.loadImage(for: photo, kind: .thumbnail(width: 160, height: 110))
if Task.isCancelled { return }
await MainActor.run {
    guard let self = self, self.previewImageViews.contains(targetView) else { return }
    if case .image(let ciImage) = result {
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        targetView.image = nsImage
    }
}

// 替换后
let image = await imageService.loadThumbnail(for: photo, maxWidth: 160, maxHeight: 110)
if Task.isCancelled { return }
await MainActor.run {
    guard let self = self, self.previewImageViews.contains(targetView) else { return }
    targetView.image = image
}
```

### 为什么这样能修复

`imageService.loadThumbnail` 内部走的是 `photoThumbnailService`，它使用 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`，**只解码目标尺寸的数据**，不会把整个原图载入内存。

## 验证方式

1. 修复后重新编译运行
2. 停留在分组展示界面
3. 观察 Activity Monitor 中内存占用
4. 预期从 5.77G 大幅下降到正常水平（几十到几百 MB）
