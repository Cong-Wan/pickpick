/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 使用 AppKit application delegate 创建并持有 pickpick 主窗口控制器；清理启动强制解包，启动调试日志改为 --debug 控制
*/

import AppKit

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
