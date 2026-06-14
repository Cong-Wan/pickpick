/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: 使用 AppKit application delegate 创建并持有 pickpick 主窗口控制器；清理启动强制解包，启动调试日志改为 --debug 控制。v1.3 明确 MainActor 隔离以匹配 AppKit delegate 生命周期
*/

import AppKit

@MainActor
final class appDelegate: NSObject, NSApplicationDelegate {
    private var mainController: mainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDebugLogger.log("applicationDidFinishLaunching")
        let controller = mainWindowController()
        mainController = controller
        guard let window = controller.window else {
            appDebugLogger.log("main window is nil")
            return
        }
        appDebugLogger.log("showWindow before visible=\(window.isVisible)")
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        appDebugLogger.log("showWindow after visible=\(window.isVisible)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
