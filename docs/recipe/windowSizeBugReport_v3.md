# 窗口尺寸回退 BUG 修正报告 v3

## 结论

v2 方案只保护 `showGroups()`，范围过窄。用户补充的两个场景证明问题不是单一返回路径，而是 `appCoordinator` 中所有直接替换 `window.contentViewController` 的主页面切换点都会触发窗口尺寸被 AppKit 重新适配。

因此正确修复应在 `appCoordinator` 中建立统一入口：所有主页面切换必须通过 `installContentViewController(_:)`。

## 直接证据

`appCoordinator.swift` 中存在 6 处直接设置主窗口内容 controller 的代码：

- `startAnalysis()`：`window?.contentViewController = progressController`
- `showStart()`：`window?.contentViewController = controller`
- `showGroups()`：`window?.contentViewController = controller`
- `showBrowser()`：`window?.contentViewController = browser`
- `showDuplicate()`：`window?.contentViewController = duplicate`
- `showError()`：`window?.contentViewController = controller`

用户补充的两个失败路径对应如下：

### 路径 1：选择文件夹界面调整窗口后，进入分组展示页缩回

```plain
showStart()
→ 用户调整窗口
→ startAnalysis(folderUrl:)
→ window.contentViewController = progressController
→ showGroups()
→ window.contentViewController = groupGridViewController
```

该路径至少触发两次直接替换 `contentViewController`。

### 路径 2：分组展示页调整窗口后，进入任意分组缩回

```plain
showGroups()
→ 用户调整窗口
→ navigateToGroup(_ group:)
→ showBrowser(group:) 或 showDuplicate(group:)
→ window.contentViewController = browser / duplicate
```

该路径命中 `showBrowser()` 或 `showDuplicate()` 中的直接替换。

## 正确修复方案

只修改 `appCoordinator.swift`。

新增统一方法：

```swift
private func installContentViewController(_ controller: NSViewController) {
    guard let window else { return }

    let currentFrame = window.frame
    let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size

    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(origin: .zero, size: currentContentSize)

    window.contentViewController = controller

    guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }

    if !NSEqualRects(window.frame, currentFrame) {
        appDebugLogger.log("restore window frame from=\(NSStringFromRect(window.frame)) to=\(NSStringFromRect(currentFrame)) screenState=\(screenState)")
        window.setFrame(currentFrame, display: true)
        let restoredContentSize = window.contentView?.bounds.size ?? currentContentSize
        controller.view.frame = NSRect(origin: .zero, size: restoredContentSize)
        controller.view.layoutSubtreeIfNeeded()
    }
}
```

替换所有直接调用：

```swift
window?.contentViewController = controller
window?.contentViewController = progressController
window?.contentViewController = browser
window?.contentViewController = duplicate
window.contentViewController = controller
```

统一改为：

```swift
installContentViewController(controller)
installContentViewController(progressController)
installContentViewController(browser)
installContentViewController(duplicate)
```

## 为什么 v2 不够

v2 只处理：

```plain
普通/重复分组 → Back → showGroups()
```

但没有处理：

```plain
startAnalysis() → progressController
showGroups() → showBrowser()
showGroups() → showDuplicate()
showGroups() → showStart()
showError()
```

所以它只能修一个方向，无法修所有页面切换。

## 影响推演

### 正向影响

- 起始页调整窗口后进入分析/分组，尺寸保持。
- 分组页调整窗口后进入普通分组，尺寸保持。
- 分组页调整窗口后进入重复分组，尺寸保持。
- 普通分组返回分组页，尺寸保持。
- 重复分组返回分组页，尺寸保持。
- 分组页返回起始页，尺寸保持。
- 错误页展示时，尺寸保持。

### 风险控制

- 不修改各页面布局代码。
- 不修改窗口初始尺寸。
- 不修改 `minSize`。
- 不在 full screen 状态强行恢复 frame。
- 不在 minimized 状态强行恢复 frame。
- debug 日志受 `--debug` 控制。

## 验证清单

1. 起始页调整窗口，选择文件夹，进入分组页，窗口不缩回。
2. 分组页调整窗口，进入普通分组，窗口不缩回。
3. 普通分组调整窗口，返回分组页，窗口不缩回。
4. 分组页调整窗口，进入 Duplicate，窗口不缩回。
5. Duplicate 调整窗口，返回分组页，窗口不缩回。
6. 分组页调整窗口，返回起始页，窗口不缩回。
7. 全屏模式下切换页面，不退出全屏、不跳窗。
