/*
Author: wilbur
Version: 1.1
Date: 2026-06-03
Description: 使用 AppKit application delegate 创建并持有 rawViewer 主窗口控制器；增加启动日志与 activate 调用
*/

import AppKit

final class appDelegate: NSObject, NSApplicationDelegate {
    private var mainController: mainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🔥 applicationDidFinishLaunching called")
        let controller = mainWindowController()
        mainController = controller
        guard controller.window != nil else {
            NSLog("🔥 CRITICAL: controller.window is nil!")
            return
        }
        NSLog("🔥 calling showWindow, window.isVisible=%@", controller.window!.isVisible ? "YES" : "NO")
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("🔥 showWindow returned, window.isVisible=%@", controller.window!.isVisible ? "YES" : "NO")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
