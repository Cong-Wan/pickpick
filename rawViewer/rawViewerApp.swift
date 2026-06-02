/*
Author: wilbur
Version: 1.1
Date: 2026-06-02
Description: 移除 SwiftUI @main 入口，App 入口改由 AppKit appDelegate 提供
*/

import Foundation

enum rawViewerAppEntry {
    static let usesAppKitDelegate = true
}
