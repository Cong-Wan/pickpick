## 代码审核报告 — rawViewer App Implementation Plan

### 总览
- 审核文件：核心 Swift / Objective-C++ / Xcode 配置文件 18+ 个
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 4 个 / 🔵 2 个
- 整体评价：当前实现已经能通过自动化验证，C++ bridge、JSON review 状态、分组、偏好、状态机与 AppKit 入口已串起来。主要不足是 UI 层仍是最小可运行实现，部分计划中的完整交互与视觉细节需要后续补强。

---

### 问题清单

### 🟡 Medium — 普通浏览器未真正执行文件移动到系统废纸篓

**位置**: `rawViewer/photoBrowserViewController.swift` / `photoBrowserState.confirmDelete()`

**问题**: 当前删除流程会先写 review 状态并从可见列表移除照片，但没有调用 `FileManager.trashItem(at:resultingItemURL:)` 移动 JPG/RAW 文件到系统 Trash。计划要求“move files to system trash”。如果用户实际删除照片，目前只会更新 JSON 与 UI 状态，磁盘文件仍在原位。

**修复方案**:

```swift
public protocol fileTrashing {
    func trash(url: URL) throws
}

public final class systemFileTrasher: fileTrashing {
    public func trash(url: URL) throws {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    }
}
```

在 `confirmDelete()` 中 JSON 更新成功后，对 `jpgPath` 和非空 `rawPath` 执行 trash，再更新 UI 列表。

---

### 🟡 Medium — Duplicate compare 状态机未执行物理删除和动画

**位置**: `rawViewer/duplicateCompareViewController.swift` / `duplicateCompareState.keepLeft()`、`keepRight()`

**问题**: 状态机能正确标记 kept / trashed / template，但没有真实删除被淘汰文件，也没有实现“right image animates left”的 UI 行为。自动化测试覆盖了业务决策，但计划中的实际双图比较体验仍未完整落地。

**修复方案**:
- 复用普通浏览器的 file trashing 抽象；
- `keepRight()` 在状态切换前触发 view 层动画；
- 状态机只负责决策，controller 负责动画和文件动作。

---

### 🟡 Medium — AppKit UI 多数是最小占位实现

**位置**: `startViewController.swift`、`groupGridViewController.swift`、`photoBrowserViewController.swift`、`duplicateCompareViewController.swift`

**问题**: 当前 UI 可编译、可路由、可测试，但并未完整实现计划要求的视觉细节：
- dashed drop zone 只是普通 button；
- group grid 是竖向按钮列表，不是卡片网格；
- browser 没有真实 toolbar、thumbnail list、checkbox、RAW/JPG segmented control；
- duplicate compare 没有双 `metalPhotoView` 主视图和 Keep both dialog。

**修复方案**: 保留现有可测试状态机，把每个 controller 的 `loadView()` 从占位 UI 替换为真实 AppKit 组件。不要改状态机测试，只增加 UI wiring 测试或 snapshot/manual checklist。

---

### 🟡 Medium — `mainWindowController.startAnalysis` 默认假设配置文件是所选目录下的 `config.yaml`

**位置**: `rawViewer/mainWindowController.swift` / `startAnalysis(folderUrl:)`

**问题**: 当前无缓存 JSON 时会调用：

```swift
analyzer.startAnalysis(folderUrl: folderUrl, configUrl: folderUrl.appendingPathComponent("config.yaml"))
```

如果用户目录没有 `config.yaml`，分析会报错。计划中 bridge 支持 `configPath`，但 start screen 没有让用户选择 config，也没有使用默认 bundled config。

**修复方案**:
- 在 App bundle 内放一个默认 config；或
- start screen 同时支持选择 config；或
- C++ analyzer 提供默认配置 fallback。

首版建议使用 bundle default config：

```swift
guard let configUrl = Bundle.main.url(forResource: "config", withExtension: "yaml") else {
    showError(message: "Missing default config.yaml")
    return
}
```

---

### 🔵 Low — `metalPhotoView.draw(_:)` 对零尺寸图片没有显式保护

**位置**: `rawViewer/metalPhotoView.swift` / `draw(_:)`

**问题**: 如果 `CIImage.extent.width` 或 `height` 为 0，scale 计算会出现除零。真实图片通常不会触发，但损坏图片或特殊 Core Image 输入可能触发异常绘制结果。

**修复方案**:

```swift
guard image.extent.width > 0, image.extent.height > 0 else { return }
```

---

### 🔵 Low — Objective-C++ bridge 没有防御 nil callback

**位置**: `rawViewer/photoAnalyzerBridge.mm` / `startAnalysisAtFolderPath`

**问题**: Header 中 block 参数标为 nonnull，Swift 调用也会保证，但 Objective-C 调用方仍可能传 nil，当前 lambda 捕获后调用会崩溃。

**修复方案**:

```objc
if (progress) {
    progress(bridgeProgress);
}
if (completion) {
    completion(result, nil);
}
```

---

### 已在审核中修复的问题

1. `mainWindowController.startAnalysis` 原先只尝试加载缓存 JSON，无缓存时不会真正启动 analyzer。已修复为：有缓存直接加载，无缓存调用 bridge 运行 analyzer，再加载结果。
2. `showGroup` 原先使用无 folderUrl 的 `jsonReviewStateStore()`，真实浏览/重复比较不会落盘到当前 folder 的 `analysis.json`。已修复为绑定 `currentFolderUrl`。
3. App sandbox 原先是 user-selected read-only，不满足 JSON 写入和 trash 操作。已改为 read-write。
4. `jsonReviewStateStore` 原先先记录 operation 再写 JSON，写入失败时 UI 可能误判成功。已改为 JSON 更新成功后再记录 operation。

---

### 优点记录

- C++ analyzer bridge 直接调用 `AppRunner::run` 和 `JsonManager`，没有绕行 CLI，符合架构要求。
- 关键业务逻辑拆成 Swift 状态机，可单测覆盖导航、删除目标、重复比较决策。
- C++ progress / review JSON / Swift grouping / bridge / AppKit routing 都有对应 XCTest。
- 修复后完整 XCTest 38 个测试通过，Debug app build 通过。

---

### 修复优先级建议

1. **补文件 trash 操作**：否则“删除”只改 JSON，不符合用户预期。
2. **补真实 browser / duplicate compare UI**：当前状态机可用，但首版视觉与交互仍不完整。
3. **解决 config.yaml 来源**：否则真实用户选择普通照片目录时可能因没有 config 而分析失败。
