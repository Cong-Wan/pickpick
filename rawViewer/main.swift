/*
Author: wilbur
Version: 1.0
Date: 2026-06-03
Description: 显式 AppKit 入口，创建 NSApplication 并设置 delegate
*/

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = appDelegate()
app.delegate = delegate
app.run()