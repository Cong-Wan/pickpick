## 代码审核报告 — Fix mainWindowController zero-arg initializer bug

### 总览
- 审核文件：2 个
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 1 个
- 整体评价：改动极小且精准，新增的 `convenience init()` 正确替换了继承自 `NSWindowController` 的无参初始化器，彻底消除了初始化器解析歧义。

---

### 问题清单

#### 🔵 [Low] `override init(window:)` 和 `init?(coder:)` 无法注入 analyzer

**位置**: `rawViewer/mainWindowController.swift` — `override init(window:)` 和 `required init?(coder:)`
**问题**: 两个 designated initializer 都硬编码 `self.analyzer = photoAnalyzerBridge()`。如果未来需要从外部注入 analyzer（例如单元测试），这些路径无法传入自定义实例。当前 `convenience init(analyzer:)` 提供了注入能力，但 designated init 路径被排除在外。
**修复方案**: 当前任务范围内无需修改，属于 pre-existing 设计。若未来需要测试注入，可考虑：
```swift
public override init(window: NSWindow?, analyzer: photoAnalyzerBridge = photoAnalyzerBridge()) {
    self.analyzer = analyzer
    super.init(window: window)
}
```
但会打破 designated initializer 的签名一致性，需谨慎评估。

---

### 优点记录

1. **初始化器设计精准**：新增的 `convenience init()` 替换继承版本而非 `override`，符合 Swift 规则（子类可重新声明与继承的 convenience init 同签名的实现），语义正确。
2. **调用链无冗余对象创建**：`convenience init()` → `self.init(analyzer:)` 时，默认参数不会被再次评估，不会创建多余的 `photoAnalyzerBridge` 实例。
3. **向后兼容**：`mainWindowController(analyzer:)` 的显式调用方式不受影响，现有代码无需修改。
4. **防呆能力强**：以后任何代码写 `mainWindowController()` 都会走正确的初始化链，不会再踩同样的坑。

---

### 修复优先级建议

本次改动无 Critical/High/Medium 问题，唯一的 🔵 Low 问题是 pre-existing 设计观察，当前无需处理。
