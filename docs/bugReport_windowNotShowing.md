'''
Author: wilbur
Version: 1.0
Date: 2026-06-03
Description: rawViewer 编译成功但窗口不显示的 bug 调研报告及修复方案归档
'''

# Bug 调研报告：编译成功但窗口不显示

## 1. 现象

- 编译成功，无编译错误
- 应用启动后终端输出：
  ```
  🔥 applicationDidFinishLaunching called
  🔥 CRITICAL: controller.window is nil!
  ```
- Dock 栏无应用窗口，界面完全不可见
- 伴随系统级 `linkd.autoShortcut` 连接错误日志

## 2. 无关日志排除

```
Unable to get synchronousRemoteObjectProxy, error: ... connection to service named com.apple.linkd.autoShortcut
```

这是 **macOS Intents / Siri Shortcuts 系统服务** 在启动阶段的连接失败，属于系统后台行为。与 AppKit 窗口创建、显示逻辑无关，可忽略。

## 3. 根因分析

### 3.1 问题定位：`mainWindowController()` 未走自定义 `convenience init`

`mainWindowController` 原初始化器定义：

| 初始化器 | 类型 | 行为 |
|---------|------|------|
| `convenience init(analyzer:)` | 自定义 convenience | 创建 `NSWindow`，调用 `self.init(window:)`，再调用 `showStart()` |
| `override init(window:)` | designated | 仅调用 `super.init(window:)`，不创建窗口 |
| `required init?(coder:)` | designated | 用于 nib / storyboard |

`appDelegate` 中调用：

```swift
let controller = mainWindowController()   // 零参数
```

### 3.2 Swift 初始化器解析陷阱

`NSWindowController` 本身带有一个无参数的 `convenience init()`。

由于 `mainWindowController` **覆盖了全部两个 designated initializer**（`init(window:)` 和 `init?(coder:)`），根据 Swift 规则，它会**自动继承**父类的所有 convenience initializers，包括 `init()`。

当编译器解析 `mainWindowController()` 时：

```
mainWindowController()
    → 继承的 NSWindowController.init()     (零参数，精确匹配)
        → 内部调用 self.init(window: nil)
            → 走到 override init(window:)    (你写的 designated init)
                → super.init(window: nil)    (window = nil)
```

**结果：你写的 `convenience init(analyzer:)` 中创建窗口、调用 `showStart()` 的逻辑完全未被执行。**

### 3.3 日志印证

- 实际日志：**缺少** `mainWindowController init done, window=...` 这行输出
- 证明 `convenience init(analyzer:)` 确实未被调用

## 4. 复现验证

编译运行最小复现代码（模拟相同的类结构和调用方式）：

```
designated init(window:) called, window=false
TestWC() -> window is nil: true          ← 复现成功！

convenience init called, window=true
TestWC(custom:) -> window is nil: false   ← 显式传参才正常
```

## 5. 修复方案

### 方案 1（推荐）：覆盖 `init()`，显式委托给 `convenience init`

在 `mainWindowController` 中新增：

```swift
public override init() {
    self.init(analyzer: photoAnalyzerBridge())
}
```

- 优点：改动最小，`appDelegate` 无需修改
- 缺点：在 designated init 中委托 convenience init，语义略不直观

### 方案 2：`appDelegate` 中显式传参调用

修改 `appDelegate.swift`：

```swift
let controller = mainWindowController(analyzer: photoAnalyzerBridge())
```

- 优点：语义清晰，零歧义
- 缺点：调用方必须显式传参，违背"零参数即可工作"的预期

### 方案 3：将 `convenience init` 改为 designated init

去掉 `convenience` 关键字，直接让 `init(analyzer:)` 成为 designated initializer，内部调用 `super.init(window:)`。

- 优点：彻底消除初始化器歧义
- 缺点：需重新梳理整个初始化链，可能涉及 `required init?(coder:)` 的联动修改

## 6. 结论

Bug 根因是 **Swift 初始化器继承规则 + 解析优先级** 导致的意外匹配，与编译配置、沙盒权限、`linkd.autoShortcut` 均无关。`mainWindowController()` 实际走了继承自 `NSWindowController` 的无参 `init()`，最终委托到 `override init(window:)` 并传入 `nil`，导致窗口从未被创建。
