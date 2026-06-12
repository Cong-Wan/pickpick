# 重复对比页缩放快捷键修复 Recipe

## 背景

用户发现：在重复照片分组的左右对比页面中，无法使用快捷键放大图片。

已确认期望行为：在重复对比页按缩放快捷键时，左右两张照片同时缩放。

## 当前判断

普通浏览页 `photoBrowserViewController.keyDown` 已处理：

- `+` / `=`：放大主图
- `-`：缩小主图
- `R`：重置缩放

重复对比页 `duplicateCompareViewController.keyDown` 目前只处理：

- `←`：保留左侧
- `→`：保留右侧

因此缩放快捷键落到 `super.keyDown(with:)`，没有被转发给左右两个 `photoMetalViewController`。

## 已确认方案

采用最小修复：只在 `duplicateCompareViewController` 内补齐缩放快捷键分发。

为避免 `keyDown` 内出现过长重复代码，在本页增加私有 helper：

- `zoomBothIn()`
- `zoomBothOut()`
- `resetBothZoom()`

这些 helper 分别调用左右两个 `photoMetalViewController` 的已有缩放 API。

## 不采用的方案

### 事件转发给子控制器

不采用。AppKit 第一响应器链在当前页面中不稳定，依赖事件自动传递给子 view/controller 仍可能导致快捷键失效。

### 抽全局快捷键路由层

不采用。目前只有普通浏览页和重复对比页需要这些快捷键。为一个小 bug 引入跨页面抽象会过度设计；等第三个页面出现相同行为时再抽更合适。

## 修改范围

### 包含

- 修改 `rawViewer/duplicate/duplicateCompareViewController.swift`
- 在 `keyDown(with:)` 的 default 分支中处理 `+` / `=` / `-` / `R`
- 增加本页私有缩放 helper

### 不包含

- 不修改 `photoMetalViewController`
- 不修改 `metalPhotoView`
- 不修改普通浏览页快捷键逻辑
- 不新增全局快捷键系统
- 不改变 `←` / `→` 的保留照片行为

## 目标行为

在重复对比页：

| 操作 | 快捷键 | 行为 |
| --- | --- | --- |
| 放大 | `+` / `=` | 左右两张同时放大 |
| 缩小 | `-` | 左右两张同时缩小 |
| 重置缩放 | `R` / `r` | 左右两张同时重置缩放和平移 |
| 保留左侧 | `←` | 保持现有行为 |
| 保留右侧 | `→` | 保持现有行为 |

## 实现设计

在 `duplicateCompareViewController` 中添加：

```swift
private func zoomBothIn() {
    leftPhotoController.zoomIn()
    rightPhotoController.zoomIn()
}

private func zoomBothOut() {
    leftPhotoController.zoomOut()
    rightPhotoController.zoomOut()
}

private func resetBothZoom() {
    leftPhotoController.resetZoom()
    rightPhotoController.resetZoom()
}
```

调整 `keyDown(with:)`：

```swift
public override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123:
        // 保留左侧：现有逻辑不变
    case 124:
        // 保留右侧：现有逻辑不变
    default:
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomBothIn()
        case "-": zoomBothOut()
        case "r", "R": resetBothZoom()
        default: super.keyDown(with: event)
        }
    }
}
```

## 验证计划

1. 构建验证：运行现有 Xcode 命令行构建，确保 Swift 编译通过。
2. 手动验证：进入 Duplicate 对比页。
3. 按 `+` 或 `=`，确认左右两张照片同时放大。
4. 按 `-`，确认左右两张照片同时缩小。
5. 按 `R`，确认左右两张照片同时重置缩放和平移。
6. 按 `←` / `→`，确认保留左/右的现有行为不受影响。

## 成功标准

- 重复对比页支持 `+` / `=` / `-` / `R` 缩放快捷键。
- 左右两张照片同步缩放。
- 普通浏览页快捷键行为不变。
- 重复对比页左右方向键行为不变。
- 项目构建通过。

## 规范自检

- 占位符扫描：无 TODO、无未完成章节。
- 一致性检查：目标行为、实现设计和验证计划一致，均指向左右同步缩放。
- 范围检查：只修复重复对比页快捷键，不引入全局快捷键系统。
- 歧义检查：已明确 `R` / `r` 均重置左右两张照片的缩放和平移。
