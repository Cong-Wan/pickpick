# 代码审核报告 — Task 1: 统一主页面安装入口 installContentViewController

### 总览
- 审核文件：1 个（`rawViewer/appCoordinator.swift`）
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 0 个
- 整体评价：实现精准、架构合理。统一入口集中管理窗口 frame 保护逻辑，所有主页面切换点（6处）一致覆盖，无遗漏。

---

### 问题清单

无问题。

---

### 优点记录

1. **统一入口消除重复** — 不再在各路由方法中散布 frame 保护逻辑，集中到 `installContentViewController(_:)` 一处维护。
2. **loadViewIfNeeded() 提前加载** — 确保 `controller.view` 在被赋值给 window 前已初始化，避免 nil view 导致崩溃。
3. **miniaturized 保护** — `!window.isMiniaturized` 防止在最小化状态下强制 setFrame。
4. **恢复后同步 view frame** — `setFrame` 后重新设置 `controller.view.frame` 并调用 `layoutSubtreeIfNeeded()`，确保子视图布局正确。
5. **日志受 --debug 控制** — 仅在全屏/最小化外的异常情况才输出日志，日常使用零开销。
6. **没有遗留直接调用** — `window.contentViewController = ...` 只存在于 `installContentViewController` 内部。

---

### 修复优先级建议

无需修复。代码质量符合预期，可以直接验收。
