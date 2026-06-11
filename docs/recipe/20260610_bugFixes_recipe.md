# Bug 修复设计文档

**日期：** 2026-06-10  
**主题：** 修复 checkbox 选中失效、双指缩放异常、JPG 偏暗  
**方案：** A（最小改动修复）

---

## 背景

详见 `docs/bugAnalysisReport_20260610.md`，三个 bug 的根因已定位：

1. **checkbox 点击失效**：`NSClickGestureRecognizer` 覆盖整个 cell，拦截了 checkbox 的点击事件
2. **双指缩放异常**：将 `NSMagnificationGestureRecognizer.magnification`（增量值）误作绝对倍数
3. **JPG 偏暗**：v1.5 硬编码引入 `no_auto_bright=1`，禁用 LibRaw 自动亮度拉伸

---

## 目标

- 正常分组中点击缩略图 checkbox 可正常选中/取消选中
- 双指缩放以当前缩放状态为基准，增量式调整，放置不突变
- 转换出的 JPG 与 RAW 预览亮度接近

---

## 方案

### Bug 1：checkbox 点击失效

**文件：** `rawViewer/views/photoThumbnailView.swift`  
**改动：**

1. `photoThumbnailView` 实现 `NSGestureRecognizerDelegate`
2. 在 `gestureRecognizer(_:shouldReceive:)` 中，若点击位置落在 `cell.checkbox.frame` 内，返回 `false`
3. cell 上的 `NSClickGestureRecognizer` 设置 `delegate = self`

**注意：** macOS `NSEvent` 无 `location(in:)` 方法，应使用 `gestureRecognizer.location(in:)`：

```swift
public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive event: NSEvent) -> Bool {
    guard let cell = gestureRecognizer.view as? photoThumbnailCellView else { return true }
    let location = gestureRecognizer.location(in: cell)
    return !cell.checkbox.frame.contains(location)
}
```

### Bug 2：双指缩放异常

**文件：** `rawViewer/views/metalPhotoView.swift`  
**改动：**

1. 新增 `pinchStartMagnification: Double = 0.0`
2. `.began` 时记录 `pinchStartZoom` 和 `pinchStartMagnification`
3. `.changed/.ended` 时计算 `delta = magnification - pinchStartMagnification`，缩放公式改为 `pinchStartZoom * (1.0 + delta)`

```swift
case .began:
    pinchStartZoom = userZoom
    pinchStartMagnification = Double(gesture.magnification)
case .changed, .ended:
    let delta = Double(gesture.magnification) - pinchStartMagnification
    let newZoom = max(minZoom, min(maxZoom, pinchStartZoom * (1.0 + delta)))
    userZoom = newZoom
```

### Bug 3：JPG 偏暗

**文件：** `cpp/src/rawConverter.cpp`  
**改动：**

`no_auto_bright` 从 `1` 恢复为默认值 `0`：

```cpp
rawProcessor.imgdata.params.no_auto_bright = 0;
```

其余参数（`gamm`, `use_camera_matrix`, `bright=1.0f`, `user_qual`）保持不变。

---

## 非目标

- 不将 LibRaw 参数暴露到 `config.yaml`（配置化价值有限，当前 config 内嵌在 bundle）
- 不重构缩略图列表的交互架构（仅修复事件竞争）
- 不引入新的测试框架或测试用例

---

## 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| checkbox delegate 与其他手势冲突 | 低 | 仅过滤 checkbox frame 内的点击，范围极小 |
| 缩放 delta 计算仍有边缘 case | 低 | 公式标准且经 clamp 保护 |
| auto_bright 恢复后个别照片过曝 | 低 | LibRaw 默认阈值 1% 高光溢出，行为与大多数 RAW 工具一致 |

---

## 验收标准

1. 进入 normal 分组，点击缩略图 checkbox 可正常选中/取消，不闪图
2. 双指放在触控板上不触发缩放，外扩放大、内收缩小，以当前状态为基准
3. 同一张照片的 JPG 与 RAW 预览亮度接近（肉眼无明显差异）

---

## 文件清单

| 文件 | 版本变更 | 改动行数 |
|---|---|---|
| `rawViewer/views/photoThumbnailView.swift` | 2.0 → 2.1 | ~10 |
| `rawViewer/views/metalPhotoView.swift` | 3.0 → 3.1 | ~4 |
| `cpp/src/rawConverter.cpp` | 1.5 → 1.6 | ~1 |
