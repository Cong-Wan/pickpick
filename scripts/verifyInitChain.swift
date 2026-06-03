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
