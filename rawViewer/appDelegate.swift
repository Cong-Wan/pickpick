/*
Author: wilbur
Version: 1.4
Date: 2026-06-17
Description: 使用 AppKit application delegate 创建并持有 pickpick 主窗口控制器；清理启动强制解包，启动调试日志改为 --debug 控制。v1.3 明确 MainActor 隔离以匹配 AppKit delegate 生命周期。v1.4 增加 --folder=/path 调试参数用于自动加载文件夹
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

        // DEBUG ONLY: support --folder=/path arg to auto-load a folder
        let args = CommandLine.arguments
        if let folderArg = args.first(where: { $0.hasPrefix("--folder=") }) {
            let path = String(folderArg.dropFirst("--folder=".count))
            let url = URL(fileURLWithPath: path)
            appDebugLogger.log("DEBUG: auto-loading folder \(url.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.startAnalysis(folderUrl: url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
