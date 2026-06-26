/*
Author: wilbur
Version: 1.1
Date: 2026-06-25
Description: 提供受 --debug 参数控制的轻量日志工具，用于关键路径调试输出；v1.1 缓存 --debug 参数检测结果，避免热路径重复扫描命令行参数
*/

import Foundation

public enum appDebugLogger {
    private static let isDebugEnabled: Bool = CommandLine.arguments.contains("--debug")
    public static var isEnabled: Bool { isDebugEnabled }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[pickpick debug] %@", message())
    }
}
