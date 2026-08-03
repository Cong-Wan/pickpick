# pickpick 应用 About 菜单实现计划

> Plan 文档。实现前需用户复审通过，并经 pi 审核修正。

## 背景

用户反馈：pickpick 打开后，点屏幕左上角菜单栏的应用名，看不到任何软件信息（如版本号等）。即缺少 macOS 标准的「关于」入口。

排查结论：

- 应用为纯代码 AppKit 启动：`main.swift` 用 `NSApplication.shared` + `appDelegate`，无 nib/storyboard。
- 代码中**完全没有构建主菜单**（全局 `grep mainMenu/NSMenu/addItem` 零匹配），`NSApp.mainMenu` 为 `nil`。
- 由于 `mainMenu` 为空，菜单栏虽然因 `.regular` 激活策略出现粗体应用名，但点开后没有标准的 About / Hide / Quit 等项，About 无处挂载、无内容可显示。
- Bundle 信息本身齐全（`CFBundleName=pickpick`、`CFBundleShortVersionString=1.2.1`、`AppIcon` 已配置），可被标准 About 面板直接读取。
- 但 `INFOPLIST_KEY_NSHumanReadableCopyright` 当前为空串，标准 About 面板的版权行会为空。

## 目标与非目标

**目标：**

- 菜单栏出现标准应用菜单（标题为应用名 pickpick）。
- 应用菜单包含：About pickpick、分隔符、Hide / Hide Others / Show All、分隔符、Quit pickpick（⌘Q）。
- 点击 About 弹出标准 macOS About 面板，显示：应用图标、名称、版本（1.2.1）、版权。
- 版本号从 bundle 自动读取，**不在代码中写死**（改 `MARKETING_VERSION` 后 About 自动同步）。
- 补充版权信息 `© 2026 wilbur`。

**非目标：**

- 不做自定义 About 窗口（标准面板已满足「显示版本等信息」的需求，符合简洁优先）。
- 不加 Preferences / Settings 菜单（当前无偏好设置功能，不臆造）。
- 不加 File / Edit / View / Window / Help 等其它主菜单（应用目前无对应功能，避免空菜单噪声）。
- 不改 `mainWindowController` 及其它任何业务代码。
- 不新建独立菜单文件（菜单代码量小，且属于 delegate 启动职责，内聚在 `appDelegate` 内）。

## 方案设计

### 技术选型

- 用 `NSMenu` 构建 `NSApp.mainMenu`，包含一个应用菜单（首项，标题为应用名）。
- About 项 action 走 `NSApplication.orderFrontStandardAboutPanel(_:)`：系统标准面板，自动从 bundle 读取图标 / 名称 / 版本 / 版权。
- 菜单项 action 的 target 设为 `nil`，走 responder chain 到 `NSApp`（`hide`/`hideOtherApplications`/`unhideAllApplications`/`terminate` 均为 `NSApplication` 的 action）。
- 应用名从 `Bundle.main` 读 `CFBundleName`，读取失败回退 `"pickpick"`，避免在代码里硬编码应用名（改名时菜单自动跟随）。

### 菜单结构

```
pickpick (应用菜单)
  ├─ About pickpick                       -> orderFrontStandardAboutPanel:
  ├─ ─────────────
  ├─ Hide pickpick            ⌘H          -> hide:
  ├─ Hide Others              ⌥⌘H         -> hideOtherApplications:
  ├─ Show All                             -> unhideAllApplications:
  ├─ ─────────────
  └─ Quit pickpick            ⌘Q          -> terminate:
```

### 代码设计

改动文件：`rawViewer/appDelegate.swift`（仅此文件）。

**1. 新增 `setupMainMenu()` 方法**

```swift
private func setupMainMenu() {
    let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "pickpick"

    let mainMenu = NSMenu()

    // 应用菜单（菜单栏首个菜单，标题为应用名）
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: appName)
    appMenuItem.submenu = appMenu

    appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())

    appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthersItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())

    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    NSApp.mainMenu = mainMenu
}
```

**2. 在启动流程中调用**

`applicationDidFinishLaunching` 最开始（创建窗口之前）调用 `setupMainMenu()`，确保窗口显示前菜单已就位：

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    appDebugLogger.log("applicationDidFinishLaunching")
    setupMainMenu()   // 新增：构建主菜单
    let controller = mainWindowController()
    // ...其余不变
}
```

### 关键设计点

- **action target 为 nil**：`#selector(NSApplication.orderFrontStandardAboutPanel(_:))` 等都是 `NSApplication` 方法。菜单项不设 `target`（默认 nil），事件经 responder chain 送达 `NSApp`，无需 `@objc` 桥接，无需在 `appDelegate` 内写空壳 action。
- **应用名读 bundle**：`CFBundleName` 即 `pickpick`，与 About 面板、Dock 名称一致；读取失败回退 `"pickpick"` 保证健壮。
- **版本号零维护**：标准 About 面板自动读 `CFBundleShortVersionString`（1.2.1）+ `CFBundleVersion`（1），显示形如 `Version 1.2.1 (1)`。改 `MARKETING_VERSION` 后重新构建即自动更新，代码无需改动。
- **MainActor 隔离**：项目 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`appDelegate` 标注 `@MainActor`，`applicationDidFinishLaunching` 由主线程调用，`setupMainMenu()` 作为同类方法继承隔离，`NSApp.mainMenu` 赋值无并发问题。
- **不破坏现有启动**：`setupMainMenu()` 在创建窗口前调用，与 `mainWindowController` / `--folder=` 调试参数逻辑无耦合。

### 版权信息

`project.pbxproj` 中 Debug / Release 两处 `INFOPLIST_KEY_NSHumanReadableCopyright` 由 `""` 改为 `"© 2026 wilbur"`，标准 About 面板版权行即显示该内容。

> 改动后需重新构建（`GENERATE_INFOPLIST_FILE=YES` 会据此重新生成 Info.plist，旧构建产物里的 Info.plist 不影响新构建）。

## 涉及文件

| 文件 | 改动 |
| --- | --- |
| `rawViewer/appDelegate.swift` | 新增 `setupMainMenu()` 私有方法 + 启动时调用；文件头版本 1.4 -> 1.5，Description 补充「新增主菜单与 About 入口」 |
| `rawViewer.xcodeproj/project.pbxproj` | Debug / Release 两处 `INFOPLIST_KEY_NSHumanReadableCopyright` 改为 `© 2026 wilbur` |

## 验证方式

- 不使用测试框架（项目约定）。改动后先 `xcodebuild clean`（或删除 `.build`、`build/derived`）再 Debug 构建，确保 Info.plist 重新生成、版权 key 写入。
- 手动验证（参照既有 flare 文档风格）：
  - 菜单栏出现 pickpick 应用菜单，点开含 About / Hide / Hide Others / Show All / Quit。
  - 点 About 弹出标准面板，显示 AppIcon + `pickpick` + `Version 1.2.1 (1)` + 版权行**非空**显示 `© 2026 wilbur`（本次改动最易因缓存失效的点）。
  - ⌘Q 退出应用；⌘H 隐藏应用；⌥⌘H 隐藏其它应用。
  - 原有启动流程（自动打开窗口、`--folder=` 调试参数）不受影响。

## 风险与注意事项

- **构建产物缓存**：版权字段改动后，`GENERATE_INFOPLIST_FILE=YES` 会重新生成 Info.plist；注意空版权串 `""` 会导致 `NSHumanReadableCopyright` key 不写入 Info.plist，About 面板版权行为空。改动后需 `xcodebuild clean`（或删除 `.build`、`build/derived`）后重新构建，确保版权行出现。
- **应用名一致性**：菜单项标题读 `CFBundleName`，About 面板标题也读 bundle，二者一致。`CFBundleName` 由 `PRODUCT_NAME`（=`$(TARGET_NAME)`）派生，若将来改应用名需改 target 名或显式设 `INFOPLIST_KEY_CFBundleName`（改 `MARKETING_VERSION` 只改版本，不影响名称）。
- **不引入新依赖**：仅用 AppKit 标准类 `NSMenu`/`NSMenuItem`/`Bundle`，无新增 framework。
- **精准修改**：仅触碰 `appDelegate.swift` 与 `project.pbxproj`，不改动 `mainWindowController`、`appCoordinator` 等业务代码。

## 版本号

按项目约定小版本递增并更新文件头 Description：

- `appDelegate.swift`：v1.4 -> v1.5
