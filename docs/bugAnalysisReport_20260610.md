# rawViewer Bug 深度分析报告

**报告日期：** 2026-06-10  
**分析范围：** Bug #1（normal 分组 checkbox 选中失效）、Bug #2（双指缩放逻辑错误）、Bug #3（JPG 转换偏暗）

---

## Bug #1：normal 分组中点击缩略图 checkbox 无法选中，且图片闪一下

### 现象
进入 normal 分组浏览照片时，点击左侧缩略图左上角 checkbox 无法完成选中/取消选中操作，同时缩略图会闪一下。

### 直接原因
`NSClickGestureRecognizer` 与 `NSButton（checkbox）` 发生了**点击事件竞争（Hit-Test Conflict）**。

在 `photoThumbnailView.swift` 的 `tableView(_:viewFor:row:)` 方法中，每个 cell 都被绑定了一个覆盖整个 cell 的 `NSClickGestureRecognizer`：

```swift
// rawViewer/views/photoThumbnailView.swift:144-147
let click = NSClickGestureRecognizer(target: self, action: #selector(thumbClicked(_:)))
cell.gestureRecognizers.removeAll()
cell.addGestureRecognizer(click)
```

当用户点击 checkbox 时，手势识别器优先拦截了点击事件，触发 `thumbClicked(_:)`：

```swift
// rawViewer/views/photoThumbnailView.swift:160-166
@objc private func thumbClicked(_ gesture: NSClickGestureRecognizer) {
    guard let cell = gesture.view as? photoThumbnailCellView else { return }
    let index = cell.thumbIndex
    guard photos.indices.contains(index) else { return }
    setCurrentIndex(index)        // ← 调用 reloadData
    delegate?.thumbnailDidSelect(index: index)
}
```

`setCurrentIndex(index)` 内部执行了 `tableView.reloadData(forRowIndexes:columnIndexes:)`，强制刷新了当前行 cell。这导致 checkbox 的 `NSButton` 还没来得及触发自身的 `.action`（即 `toggleCheck(_:)`），cell 就被重绘，checkbox 的状态被 `configure()` 方法根据 `checkedIds` 重新覆盖，**整个点击事件链被打断**。

### 间接原因
1. **cell 重绘过于频繁**：`setCurrentIndex()` 每次都会调用 `reloadData(forRowIndexes:)`，即使只是更新选中态边框也强制重建 cell 视图，导致手势识别器被 `removeAll()` 后重新添加，增加了事件竞争的概率窗口。
2. **checkbox 与 cell 点击区域重叠但未做事件隔离**：checkbox 作为 cell 的 subview，其父视图（cell）上的手势识别器没有设置 `delegate` 来排除特定子视图的点击。正确做法应为让手势识别器忽略 checkbox 的点击，或将 checkbox 的点击事件独立处理。
3. **NSClickGestureRecognizer 的默认行为**：在 AppKit 中，父视图上的 `NSClickGestureRecognizer` 默认会拦截其整个 bounds 内的点击事件，包括 subview 的点击，除非显式通过 `NSGestureRecognizerDelegate` 的 `gestureRecognizer(_:shouldReceive:)` 进行过滤。

### 关键证据

| 文件 | 行号 | 代码/说明 |
|---|---|---|
| `photoThumbnailView.swift` | 144-147 | 每次 `viewFor` 都给 cell 添加覆盖全 cell 的 `NSClickGestureRecognizer` |
| `photoThumbnailView.swift` | 160-166 | `thumbClicked` → `setCurrentIndex(index)` → `reloadData` |
| `photoThumbnailView.swift` | 71-78 | `setCurrentIndex` 内调用 `reloadData(forRowIndexes:)` |
| `photoThumbnailCellView.swift` | 72 | `configure()` 中 `checkbox.state = isChecked ? .on : .off`，会覆盖用户点击状态 |

### 修复方向
- **方案 A（推荐）**：在 `photoThumbnailCellView` 内部直接处理 checkbox 的点击事件，并通过 delegate/block 回调给外部，避免在 cell 级别添加全局点击手势。
- **方案 B**：保留 cell 点击手势，但给 `NSClickGestureRecognizer` 设置 delegate，在 `shouldReceive event` 中判断点击位置是否在 checkbox 的 frame 内，若是则返回 `false` 拒绝接收事件。
- **方案 C**：将 checkbox 放在 cell 的一个独立容器 view 中，使手势识别器不覆盖 checkbox 区域。

---

## Bug #2：双指放大缩小逻辑错误，放置即缩小

### 现象
在 Metal 照片预览区域使用 trackpad 双指手势时，即使当前是无缩放状态，只要双指间距较小地放在触控板上，图片就会立即缩小。

### 直接原因
`NSMagnificationGestureRecognizer.magnification` 的语义被**错误理解为绝对倍数**，而实际它是一个**增量值（delta / relative change）**。

在 `metalPhotoView.swift` 的 `handlePinch(_:)` 中：

```swift
// rawViewer/views/metalPhotoView.swift:83-89
@objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
    switch gesture.state {
    case .began:
        pinchStartZoom = userZoom
    case .changed, .ended:
        let newZoom = max(minZoom, min(maxZoom, pinchStartZoom * Double(gesture.magnification)))
        //                                                   ↑↑↑↑↑↑↑↑↑↑
        userZoom = newZoom
        needsDisplay = true
        onZoomChanged?(userZoom)
    default:
        break
    }
}
```

`gesture.magnification` 的取值规则：
- 手势刚开始（`.began`）时，值约为 `0.0`
- 双指外扩（放大）时，值为**正增量**，如 `0.3`（表示增加了 30%）
- 双指内收（缩小）时，值为**负增量**，如 `-0.2`（表示减少了 20%）

因此，当用户轻轻放下双指（`magnification ≈ 0`）时：
```
newZoom = pinchStartZoom(1.0) * 0.0 = 0.0
→ clamp 到 minZoom(0.1)
```
图片瞬间被缩到 0.1 倍，表现为"放置即缩小"。

### 间接原因
1. **缺少增量基准偏移**：代码在 `.began` 时记录了 `pinchStartZoom`，但没有记录初始 `magnification` 值作为偏移基准。正确的计算应为：
   ```swift
   newZoom = pinchStartZoom * (1.0 + gesture.magnification)
   ```
   这样当 `magnification = 0` 时，`newZoom = pinchStartZoom * 1.0`，不会发生突变。
2. **测试覆盖缺失**：该手势识别器仅通过肉眼测试，未编写单元测试验证不同 `magnification` 值下的输出行为。

### 关键证据

| 文件 | 行号 | 代码/说明 |
|---|---|---|
| `metalPhotoView.swift` | 83-89 | `handlePinch` 中错误计算 `newZoom = pinchStartZoom * gesture.magnification` |
| `metalPhotoView.swift` | 85 | `.began` 时只记录 `pinchStartZoom`，未记录初始 magnification 偏移 |
| Apple 头文件 | `NSMagnificationGestureRecognizer.h` | `magnification` 定义为 `CGFloat` 属性，无绝对倍数语义注释 |
| Apple 文档惯例 | — | `magnification` 初始值为 0，表示**自手势开始以来的变化量**（delta） |

### 修复方向
将 `.changed` 阶段的计算改为增量模式：

```swift
case .changed, .ended:
    let newZoom = max(minZoom, min(maxZoom, pinchStartZoom * (1.0 + Double(gesture.magnification))))
    userZoom = newZoom
    needsDisplay = true
    onZoomChanged?(userZoom)
```

---

## Bug #3：转换出的 JPG 文件相较于 RAW 预览偏暗

### 历史演变（基于 git 证据）

| 版本 | 提交 | 参数变化 | 问题描述 |
|---|---|---|---|
| v1.0 | `229589f` | 无任何 LibRaw 参数设置，全走默认值 | 照片**发灰**（颜色平淡、灰暗） |
| v1.2 | `948aaf3` | 新增 `use_camera_wb=1`, `output_color=1`, `output_bps=8`, RGB→BGR | 修复颜色空间/白平衡导致的**发灰** |
| v1.4 | `fc38335` | 接入 `jpgWriter`（ImageIO 替代 OpenCV） | 参数不变 |
| v1.5 | `8fada85` | 新增 `gamm[0..1]`, `use_camera_matrix=1`, `no_auto_bright=1`, `bright=1.0f`, `user_qual=3` | 声称"修复发灰"，但引入**偏暗** |

### 直接原因

**`no_auto_bright = 1` 在 v1.5 被硬编码引入，禁用了 LibRaw 的自动亮度拉伸（auto-bright）。**

在 v1.0-v1.4 期间，`no_auto_bright` 保持 LibRaw 默认值 `0`（即 auto-bright **开启**）。此时 LibRaw 会在 `dcraw_process()` 中自动拉伸直方图，使约 1% 像素达到最大亮度值，图像整体明亮。

v1.5 的 `8fada85` 提交将 `no_auto_bright` 设为 `1`，同时 `bright = 1.0f` 仅为线性乘数，**完全取消了自动亮度补偿**：

```cpp
// cpp/src/rawConverter.cpp:56-57（v1.5 引入）
rawProcessor.imgdata.params.no_auto_bright = 1;  // ← 关闭 auto-bright
rawProcessor.imgdata.params.bright = 1.0f;       // ← 线性乘数，无补偿效果
```

而 Swift 显示端 `photoDisplayService.swift:91` 使用系统 `CIFilter(imageURL:options:)` 解码 RAW 时，系统 RAW 解码器会自动应用色调映射和亮度调整。于是出现：

- **RAW 预览（CIFilter）**：有自动亮度调整 → 看起来正常
- **JPG 转换（LibRaw no_auto_bright=1）**：无自动亮度拉伸 → 偏暗

### 关于"发灰"问题的真实历史

之前 v1.0 的"发灰"**并非**由 `no_auto_bright=0` 导致，而是由于以下参数缺失：
- `use_camera_wb` 默认 `0`（不使用相机白平衡）
- `output_color` 默认 `0`（raw 颜色空间，非 sRGB）
- `output_bps` 默认 `16`（与 OpenCV 8-bit 写入不匹配）

这些参数在 **v1.2 (`948aaf3`)** 已被修复。此后（v1.2-v1.4）的照片不再发灰。

v1.5 额外加入 `no_auto_bright=1` 是对"发灰"问题的**过度修复**——它在颜色正确的基础上又砍掉了亮度拉伸，导致**从"发灰"变成了"偏暗"**。

### 关于"可通过配置文件配置参数"

**当前事实：这些参数并未暴露到 `config.yaml`。**

证据：
- `config.yaml` 的 `raw_conversion` 段仅含 `jpg_quality`
- `cpp/include/taskState.h` 中 `RawConversionConfig` 仅定义 `int jpgQuality`
- `cpp/src/configLoader.cpp` 仅读取 `jpg_quality`
- `gamm`、`no_auto_bright`、`bright`、`user_qual` 等参数**全部硬编码**在 `rawConverter.cpp` 中

### 关键证据

| 文件 | 行号 | 内容 |
|---|---|---|
| `cpp/src/rawConverter.cpp` (v1.0) | — | 无任何 LibRaw 参数设置 |
| `cpp/src/rawConverter.cpp` (v1.2) | 44-47 | 新增 `use_camera_wb=1`, `output_color=1`, `output_bps=8` |
| `cpp/src/rawConverter.cpp` (v1.5) | 47-57 | 新增 `gamm`, `use_camera_matrix`, `no_auto_bright=1`, `bright=1.0f` |
| `cpp/include/taskState.h` | — | `RawConversionConfig` 仅有 `jpgQuality` |
| `rawViewer/config.yaml` | — | `raw_conversion` 下仅有 `jpg_quality` |
| `cpp/src/configLoader.cpp` | — | 仅解析 `jpg_quality` |

### 修复方向
- **方案 A（推荐）**：在 `rawConverter.cpp` 中启用 auto-bright，但调整阈值使其更保守：
  ```cpp
  rawProcessor.imgdata.params.no_auto_bright = 0;       // 启用自动亮度
  rawProcessor.imgdata.params.auto_bright_thr = 0.01f;  // 1% 高光溢出（默认值）
  ```
  这样 LibRaw 输出的 JPG 亮度将与系统 RAW 解码器更接近。

- **方案 B**：如果确实需要禁用 auto-bright（以保持线性/科学级精度），则应主动提升 `bright` 系数，例如：
  ```cpp
  rawProcessor.imgdata.params.no_auto_bright = 1;
  rawProcessor.imgdata.params.bright = 1.5f;  // 需根据测试样本微调
  ```
  但这种方式不如 auto-bright 智能，容易过曝或欠曝。

- **方案 C（长期）**：统一两端的 RAW 处理管线。例如在 Swift 端也使用 LibRaw（通过 bridge）进行 RAW 解码，确保预览和转换输出使用完全相同的参数。

---

## 总结

| Bug | 直接原因 | 间接原因 | 核心文件 |
|---|---|---|---|
| #1 checkbox 失效 | `NSClickGestureRecognizer` 拦截 checkbox 点击，触发 reloadData 打断 NSButton 事件链 | cell 重绘频繁、未做事件隔离 | `photoThumbnailView.swift` |
| #2 双指缩放异常 | 将 `magnification` 增量值误作绝对倍数 | 缺少增量基准偏移、无单元测试 | `metalPhotoView.swift` |
| #3 JPG 偏暗 | `no_auto_bright=1` 硬编码引入，禁用 LibRaw 自动亮度拉伸 | v1.5 对"发灰"问题的过度修复；转换/显示两端管线不一致；参数未暴露到配置 | `rawConverter.cpp`, `photoDisplayService.swift` |
