/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 使用 AppKit application delegate 创建并持有 rawViewer 主窗口控制器
*/

import AppKit

@main
final class appDelegate: NSObject, NSApplicationDelegate {
    private var mainController: mainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = mainWindowController()
        mainController = controller
        controller.showWindow(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
