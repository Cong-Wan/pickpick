/*
Author: wilbur
Version: 1.1
Date: 2026-06-13
Description: 显式 AppKit 入口。v1.1 使用 @main + @MainActor 包装启动流程，避免 Swift 6 下 AppKit delegate actor 隔离警告
*/

import AppKit

@main
struct pickpickApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = appDelegate()
        app.delegate = delegate
        app.run()
    }
}
