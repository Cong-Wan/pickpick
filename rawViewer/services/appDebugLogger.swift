/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 提供受 --debug 参数控制的轻量日志工具，用于关键路径调试输出
*/

import Foundation

public enum appDebugLogger {
    public static var isEnabled: Bool {
        CommandLine.arguments.contains("--debug")
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[pickpick debug] %@", message())
    }
}
