# Fix mainWindowController zero-arg initializer bug

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `mainWindowController()` 零参数初始化时 window 为 nil 的 bug，确保应用启动后窗口正常显示。

**Architecture:** 在 `mainWindowController` 中新增 `convenience init()`，显式委托给 `self.init(analyzer:)`，替换继承自 `NSWindowController` 的无参 convenience init，从而消除初始化器解析歧义。

**Tech Stack:** Swift, AppKit, Xcode

---

## File Structure

| File | Responsibility |
|------|---------------|
| `rawViewer/mainWindowController.swift` | 主窗口控制器。本次修改：新增 `convenience init()` 覆盖继承版本。 |
| `scripts/verifyInitChain.swift` | 独立验证脚本。模拟相同的初始化器结构，编译运行后断言修复前后行为差异。 |

---

### Task 1: Add zero-arg convenience initializer

**Goal:** `mainWindowController()` 调用后 `window` 不为 nil，应用启动时窗口正常创建并显示。

**Files touched:**

- `rawViewer/mainWindowController.swift` — 新增 `convenience init()`，委托给 `self.init(analyzer:)`
- `scripts/verifyInitChain.swift` — 独立 Swift 脚本，验证零参数初始化链行为正确

------

#### Step 1 — Implement

在 `rawViewer/mainWindowController.swift` 中，于 `convenience init(analyzer:)` 之前插入 `convenience init()`，并更新文件头版本号。

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-03
Description: 修复零参数初始化器继承歧义导致的 window 为 nil 问题
*/

import AppKit

public enum windowScreenState: Equatable {
    case start
    case progress
    case groups
    case browser
    case duplicateCompare
    case error(String)
}

public final class mainWindowController: NSWindowController {
    public private(set) var screenState: windowScreenState = .start
    public private(set) var records: [photoItem] = []
    public private(set) var selectedGroup: photoGroup?
    public private(set) var currentFolderUrl: URL?
    public var analyzer: photoAnalyzerBridge

    public convenience init() {
        self.init(analyzer: photoAnalyzerBridge())
    }

    public convenience init(analyzer: photoAnalyzerBridge = photoAnalyzerBridge()) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "rawViewer"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        self.init(window: window)
        self.analyzer = analyzer
        NSLog("🔥 mainWindowController init done, window=%@", window)
        showStart()
    }

    public override init(window: NSWindow?) {
        self.analyzer = photoAnalyzerBridge()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.analyzer = photoAnalyzerBridge()
        super.init(coder: coder)
    }

    public func showStart() {
        screenState = .start
        selectedGroup = nil
        let controller = startViewController()
        controller.onFolderSelected = { [weak self] url in
            self?.startAnalysis(folderUrl: url)
        }
        window?.contentViewController = controller
        window?.makeKeyAndOrderFront(nil)
        NSLog("🔥 showStart done, window.isVisible=%@", window?.isVisible ?? false ? "YES" : "NO")
    }

    public func startAnalysis(folderUrl: URL) {
        currentFolderUrl = folderUrl
        screenState = .progress
        let progressController = progressViewController()
        window?.contentViewController = progressController
        Task { @MainActor in
            do {
                if FileManager.default.fileExists(atPath: folderUrl.appendingPathComponent(".cache/analysis.json").path) {
                    showGroups(records: try analyzer.loadAnalysisResult(folderUrl: folderUrl))
                    return
                }
                _ = try await analyzer.startAnalysis(folderUrl: folderUrl, configUrl: folderUrl.appendingPathComponent("config.yaml")) { progress in
                    progressController.update(progress: progress)
                }
                showGroups(records: try analyzer.loadAnalysisResult(folderUrl: folderUrl))
            } catch {
                showError(message: error.localizedDescription)
            }
        }
    }

    public func showGroups(records: [photoItem]) {
        self.records = records
        screenState = .groups
        let controller = groupGridViewController(groups: makeVisiblePhotoGroups(from: records))
        controller.onSelectGroup = { [weak self] group in
            self?.showGroup(group: group)
        }
        window?.contentViewController = controller
    }

    public func showGroup(group: photoGroup) {
        selectedGroup = group
        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
        if group.kind.isDuplicate {
            screenState = .duplicateCompare
            window?.contentViewController = duplicateCompareViewController(group: group, store: store)
        } else {
            screenState = .browser
            window?.contentViewController = photoBrowserViewController(group: group, store: store)
        }
    }

    public func showError(message: String) {
        screenState = .error(message)
        setContent(title: message)
    }

    private func setContent(title: String) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .center
        label.font = .systemFont(ofSize: 24, weight: .medium)

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        window?.contentViewController = NSViewController()
        window?.contentViewController?.view = view
    }
}
```

------

#### Step 2 — Write tests based on the plan goal

创建 `scripts/verifyInitChain.swift`，模拟相同的初始化器继承结构，验证修复前后行为：

```swift
import AppKit

// 模拟修复前的类结构：零参数 init 继承自父类，最终走到 override init(window: nil)
class BrokenWC: NSWindowController {
    var tag: String

    convenience init(tag: String = "default") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        self.init(window: window)
        self.tag = tag
    }

    override init(window: NSWindow?) {
        self.tag = "designated"
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.tag = "coder"
        super.init(coder: coder)
    }
}

// 模拟修复后的类结构：新增 convenience init() 替换继承版本，委托给带参数的 convenience init
class FixedWC: NSWindowController {
    var tag: String

    convenience init() {
        self.init(tag: "fixed")
    }

    convenience init(tag: String = "default") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        self.init(window: window)
        self.tag = tag
    }

    override init(window: NSWindow?) {
        self.tag = "designated"
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.tag = "coder"
        super.init(coder: coder)
    }
}

// 测试 1：BrokenWC() 零参数调用应返回 window == nil（复现 bug）
let broken = BrokenWC()
guard broken.window == nil else {
    print("FAIL: BrokenWC() window should be nil")
    exit(1)
}
print("✓ BrokenWC() -> window is nil (bug reproduced)")

// 测试 2：BrokenWC(tag: "explicit") 显式传参应返回 window != nil
let brokenExplicit = BrokenWC(tag: "explicit")
guard brokenExplicit.window != nil else {
    print("FAIL: BrokenWC(tag:) window should NOT be nil")
    exit(1)
}
print("✓ BrokenWC(tag:) -> window is NOT nil")

// 测试 3：FixedWC() 零参数调用应返回 window != nil（修复生效）
let fixed = FixedWC()
guard fixed.window != nil else {
    print("FAIL: FixedWC() window should NOT be nil")
    exit(1)
}
print("✓ FixedWC() -> window is NOT nil (fix verified)")

// 测试 4：FixedWC(tag: "explicit") 显式传参应返回 window != nil
let fixedExplicit = FixedWC(tag: "explicit")
guard fixedExplicit.window != nil else {
    print("FAIL: FixedWC(tag:) window should NOT be nil")
    exit(1)
}
print("✓ FixedWC(tag:) -> window is NOT nil")

print("\nAll tests passed.")
```

------

#### Step 3 — Run tests and confirm all pass

```bash
$ mkdir -p scripts && swiftc scripts/verifyInitChain.swift -framework AppKit -o /tmp/verifyInitChain && /tmp/verifyInitChain
# Expected output:
#   ✓ BrokenWC() -> window is nil (bug reproduced)
#   ✓ BrokenWC(tag:) -> window is NOT nil
#   ✓ FixedWC() -> window is NOT nil (fix verified)
#   ✓ FixedWC(tag:) -> window is NOT nil
#
#   All tests passed.
```

如果任何测试失败，修复 **实现**（检查 `scripts/verifyInitChain.swift` 中的类结构是否准确映射了 `mainWindowController` 的初始化器链），不要弱化测试。重复直到全部通过。

✅ **Done when:** `/tmp/verifyInitChain` 运行输出 `All tests passed.`。在此条件满足前，不要开始下一个任务。

------

## Self-Review

**1. Spec coverage:**
- 新增 `convenience init()` 替换继承版本 → Task 1 Step 1 实现
- 验证零参数初始化后 window 不为 nil → Task 1 Step 2 & 3 测试覆盖

**2. Placeholder scan:**
- 无 "TBD"、"TODO"、"implement later"
- 无省略号或 `// ...`
- 测试代码完整，可直接复制编译运行

**3. Type consistency:**
- `photoAnalyzerBridge()` 与现有代码一致
- `NSWindow`, `NSRect`, `NSSize` 等 AppKit 类型正确

**4. Test completeness:**
- 主成功路径：FixedWC() → window != nil ✓
- 边缘情况：显式传参仍然正常工作 ✓
- 失败/对比情况：BrokenWC() → window == nil（bug 复现）✓
- Done 条件明确：脚本输出 `All tests passed.` ✓

---

## Execution Handoff

**Plan complete and saved to `docs/flare/20250603_fixWindowInitializer.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
