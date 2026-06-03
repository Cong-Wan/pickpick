## 代码审核报告 — rawViewer Swift 代码 + 构建问题

### 总览
- 审核文件：14 个 Swift 文件 + 2 个 ObjC++ 文件 + Xcode 项目配置
- 发现问题：🔴 3 个 / 🟠 5 个 / 🟡 4 个 / 🔵 3 个
- 整体评价：**Xcode 构建失败的主因是 C++ 源文件未加入项目导致链接错误，非 Swift 代码编译错误。** Swift 代码整体结构清晰，模型/状态机/桥接分层合理，但存在若干运行时崩溃隐患（数组越界、线程安全问题）和架构断裂（状态机无 UI 绑定）。

---

### 🔴 Critical — 构建失败

### 🔴 C1. Xcode 项目缺少 `jpgWriter.mm` 和 `photoMetadataReader.mm`

**位置**: `rawViewer.xcodeproj/project.pbxproj`
**问题**: `cpp/src/jpgWriter.mm` 和 `cpp/src/photoMetadataReader.mm` 存在于文件系统中，但未被添加到 Xcode 项目的 Sources Build Phase 中。链接时产生 undefined symbols:
- `writeJpgWithImageIo(...)` — 被 `rawConverter.cpp:99` 引用
- `photoMetadataReader::readBestShootingTime(...)` — 被 `jsonManager.cpp` 引用

**修复方案**: 在 Xcode 中将这两个文件添加到 target `rawViewer` 的 Compile Sources 中。或直接编辑 pbxproj 添加对应的 `PBXBuildFile` 和 `PBXFileReference` 条目。

---

### 🔴 C2. 架构回退到 x86_64 导致链接 arm64-only 第三方库失败

**位置**: `project.pbxproj` — rawViewerTests target 缺少 `ARCHS = arm64`
**问题**: `rawViewer` target 设置了 `ARCHS = arm64`，但 `rawViewerTests` target 未设置。Xcode 构建时警告 `ONLY_ACTIVE_ARCH=YES requested with multiple ARCHS and no active architecture could be computed`，回退到构建所有架构（含 x86_64）。`3rdPart/` 下的 `libyaml-cpp.a`、`libraw.a`、`libopencv_*.a` 均为 arm64-only，x86_64 链接必然失败。

**验证**: `lipo -info 3rdPart/yaml/lib/libyaml-cpp.a` → `Non-fat file: ... is architecture: arm64`

**修复方案**:
- 在 rawViewerTests target 的 Build Settings 中添加 `ARCHS = arm64`
- 或者从命令行构建时显式指定：`xcodebuild ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
- 长期方案：所有 target 统一设置 `ARCHS = arm64`

---

### 🔴 C3. `duplicateCompareState.keepLeft()` 数组越界崩溃

**位置**: `duplicateCompareViewController.swift:34`
**问题**: `keepLeft()` 中删除 candidate 后：
```swift
photos.remove(at: candidateIndex)
candidateIndex = min(1, photos.count)  // BUG
```
当 `photos.count == 1` 时，`candidateIndex = min(1, 1) = 1`，但唯一有效索引是 `0`。后续访问 `candidatePhoto` 虽然安全（`photos.indices.contains(1)` 返回 false），但若调用方依赖 `candidateIndex` 进行其他索引运算则会越界。

**修复方案**:
```swift
// Before:
candidateIndex = min(1, photos.count)
// After:
candidateIndex = min(1, max(0, photos.count - 1))
```

---

### 🟠 High — 运行时崩溃/功能错误

### 🟠 H1. `keepRight()` 中 `candidateIndex` 同样可能越界

**位置**: `duplicateCompareViewController.swift:48`
**问题**:
```swift
candidateIndex = min(newMainIndex + 1, photos.count)
```
当 `newMainIndex + 1 == photos.count` 时，`candidateIndex` 等于 `photos.count`，超出有效范围 `[0, photos.count - 1]`。

**修复方案**:
```swift
candidateIndex = min(newMainIndex + 1, max(0, photos.count - 1))
```

---

### 🟠 H2. `photoThumbnailCache` 非线程安全

**位置**: `photoThumbnailCache.swift:8-14`
**问题**: `cache` 字典无任何同步机制。若从多个并发 Task 或后台队列调用 `thumbnail(for:)`，会导致字典并发读写崩溃（Swift Dictionary 非线程安全）。

**修复方案**:
```swift
public final class photoThumbnailCache {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    public func thumbnail(for path: String) -> NSImage? {
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let image = NSImage(contentsOfFile: path) else { return nil }

        lock.lock()
        cache[path] = image
        lock.unlock()
        return image
    }
}
```

---

### 🟠 H3. 状态机与 UI 无绑定

**位置**: `photoBrowserViewController.swift`, `duplicateCompareViewController.swift`
**问题**: `photoBrowserState` 和 `duplicateCompareState` 使用普通 `class` 存储状态，不是 `ObservableObject`，也没有 delegate/closure 通知机制。当 `currentIndex`、`checkedPhotoIds` 等状态改变时，UI 不会自动更新。

当前 `loadView()` 只创建了静态占位 label，所以此问题暂未暴露。但一旦接入真实 UI（Metal 图片视图、按钮等），操作状态变化不会触发任何重绘。

**修复方案**: 让状态类继承 `ObservableObject` 并使用 `@Published`：
```swift
import Combine

public final class photoBrowserState: ObservableObject {
    @Published public private(set) var currentIndex: Int = 0
    @Published public var checkedPhotoIds: Set<String> = []
    // ...
}
```
或使用 delegate 模式回调到 ViewController。

---

### 🟠 H4. `metalPhotoView` 未被任何界面使用，核心渲染组件孤立

**位置**: `metalPhotoView.swift`, `photoBrowserViewController.swift`, `duplicateCompareViewController.swift`
**问题**: `metalPhotoView` 实现了完整的 Metal GPU 渲染管线（CIImage → CIContext Metal backend → MTKView drawable），但两个浏览器界面只创建了占位文字 `NSTextField(labelWithString: "Photo Browser")`，没有将 `metalPhotoView` 加入 view hierarchy 或调用 `loadPhoto(url:)`。

这是 App 最核心的组件——用户需要看到照片才能做 keep/pass/trash 决策。当前状态是：分析→分组→JSON读取的后端管线完整，但前端图片浏览是空壳。

**修复方案**: 在 `photoBrowserViewController` 和 `duplicateCompareViewController` 的 `loadView()` 中创建 `metalPhotoView` 实例，加入 view hierarchy，并在 `currentIndex` / `mainIndex` / `candidateIndex` 变化时调用 `loadPhoto(url:)` 显示对应图片。

**附注 — Metal 解码路线**: 当前 `metalPhotoView` 使用 **Core Image → Metal** 路线（`CIContext(mtlDevice:)` + `ciContext.render(to: texture)`)，依赖系统 RAW 解码器处理 RAW 文件。C++ 端已有自定义 Metal compute shader（Laplacian/直方图/RAW 转换），但 Swift 侧未复用。对于 JPG 显示场景，Core Image 路线足够；对于 RAW 直接显示，可考虑桥接 C++ 端的 Metal RAW 转换结果（即读取 `.cache/` 中已转换的 JPG），无需在 Swift 侧重新做 GPU RAW 解码。

---

### 🟠 H5. `jsonReviewStateStore` 每次 mark 重写完整 JSON 文件

**位置**: `jsonReviewStateStore.swift:38-56`
**问题**: `mark()` 和 `setTemplate()` 每次调用都：读取 JSON → 反序列化 → 修改 → 序列化 → 原子写入。在重复照片比较场景中，用户快速连续点击 Keep Left/Right，每次操作约几十到几百毫秒的文件 I/O，会累积可感知的 UI 卡顿。

**修复方案**:
1. 内存中缓存 JSON 字典，标记 dirty，使用防抖（debounce）或退出屏幕时统一写入
2. 或提供 `batchUpdate(_:)` 方法支持批量操作
3. 至少将 `updateJson` 移至后台队列：
```swift
private let ioQueue = DispatchQueue(label: "rawViewer.jsonIO")

public func mark(photoId: String, status: reviewStatus) throws {
    try ioQueue.sync {
        try updateJson { ... }
        operations.append(...)
    }
}
```

---

### 🟡 Medium — 实现不健壮

### 🟡 M1. `loadAnalysisResult` 同步调用阻塞 MainActor

**位置**: `mainWindowController.swift:70-71`
**问题**: `try analyzer.loadAnalysisResult(folderUrl:)` 是同步 C++ 调用（读取 JSON 文件），在 `Task { @MainActor in }` 中执行，会短暂阻塞主线程。对于大型项目（数千张照片），JSON 文件可能达数 MB。

**修复方案**: 将加载操作移至后台：
```swift
let records = try await Task.detached {
    try self.analyzer.loadAnalysisResult(folderUrl: folderUrl)
}.value
```

---

### 🟡 M2. `isoNow()` 每次创建新 `ISO8601DateFormatter`

**位置**: `jsonReviewStateStore.swift:60-62`
**问题**: `ISO8601DateFormatter()` 初始化开销较大。在批量标记场景中被频繁调用。

**修复方案**:
```swift
private let isoFormatter: ISO8601DateFormatter = {
    ISO8601DateFormatter()
}()

private func isoNow() -> String {
    isoFormatter.string(from: Date())
}
```

---

### 🟡 M3. `photoAnalyzerBridge.startAnalysis` 不支持取消

**位置**: `photoAnalyzerBridge.swift:21-39`, `photoAnalyzerBridge.mm:113-140`
**问题**: `withCheckedThrowingContinuation` 等待 C++ 分析完成，但 C++ 侧 `AppRunner::run()` 无中断机制。用户若在分析中途关闭文件夹或退出 App，Task 会继续运行直到完成，期间持有 `self` 和分析资源。

**修复方案**: 
- 使用 `withTaskCancellationHandler` 在取消时设置标志位
- C++ 侧在 `progressCallback` 中检查标志位并提前返回

---

### 🟡 M4. `startViewController` 不支持拖拽文件夹

**位置**: `startViewController.swift`
**问题**: 定义了 `folderDropValidator` 且按钮文本提示 "drag it here"，但 `startViewController` 未注册 drag types 或实现 `NSDraggingDestination` 协议。拖拽功能完全缺失。

**修复方案**: 在 `loadView()` 中注册拖拽类型并实现 drop 处理：
```swift
view.registerForDraggedTypes([.fileURL])
// 实现 draggingEntered, performDragOperation 等
```

---

### 🔵 Low — 代码风格/可读性

### 🔵 L1. `ContentView.swift` 为死代码

**位置**: `ContentView.swift`
**问题**: Xcode 模板生成的 SwiftUI View，未被任何代码引用。由于项目已切换为 AppKit 入口（`appDelegate.swift`），此文件无用。

**修复方案**: 删除 `ContentView.swift`。

---

### 🔵 L2. `displayAvailability` 枚举设计可优化

**位置**: `photoModels.swift:145-148`
**问题**: `.available(URL)` 和 `.unavailable` 可以用 Optional 替代，减少一个枚举定义：
```swift
public func displayUrl(for photo: photoItem, source: displaySource) -> URL? {
    switch source {
    case .jpg: return URL(fileURLWithPath: photo.jpgPath)
    case .raw:
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else { return nil }
        return URL(fileURLWithPath: rawPath)
    }
}
```

---

### 🔵 L3. `rawViewerAppEntry` 枚举无实际用途

**位置**: `rawViewerApp.swift:10-12`
**问题**: `rawViewerAppEntry.usesAppKitDelegate` 未被任何代码读取。`@main` 已在 `appDelegate.swift` 中声明，此文件可删除。

**修复方案**: 删除 `rawViewerApp.swift` 或移入有意义的 App 配置常量。

---

### 优点记录

1. **模型设计干净**: `photoItem`、`photoGroup`、`photoGroupKind` 值类型设计，Equatable/Identifiable 一致性良好
2. **桥接层职责清晰**: `photoAnalyzerBridge` 将 C++ 模型转为 Swift 模型，`jsonReviewStateStore` 封装 JSON 持久化，职责单一
3. **状态机抽取**: `photoBrowserState` 和 `duplicateCompareState` 将业务逻辑与 UI 解耦，方向正确（只需补充 UI 绑定）
4. **Metal 视图基础扎实**: `metalPhotoView` 正确处理了 CIImage → Metal texture 的渲染管线，aspect-fit 变换数学正确
5. **错误处理完整**: ObjC++ 桥接层对 C++ 异常有完整的 try/catch → NSError 转换

---

### 修复优先级建议

| 优先级 | 问题 | 原因 |
|--------|------|------|
| **P0** | C1: 添加 `jpgWriter.mm` 和 `photoMetadataReader.mm` | 缺少则链接必败，零行代码修改即可修复 |
| **P0** | C2: 统一 `ARCHS = arm64` | 默认构建会回退 x86_64 链接失败 |
| **P1** | C3: `keepLeft()` 数组越界 | 删除到最后一张时必崩 |
| **P1** | H1: `keepRight()` 数组越界 | 同上 |
| **P1** | H2: `photoThumbnailCache` 线程安全 | 一旦接入异步缩略图加载必崩 |
| **P2** | H3: 状态机 UI 绑定 | 当前占位 UI 不影响，但阻塞后续开发 |
| **P2** | H4: metalPhotoView 未接入 | App 核心功能——看图——完全缺失 |
| **P2** | H5: JSON 批量写入 | 影响用户体验 |
| **P3** | M4: 拖拽功能 | 按钮文案已承诺此功能 |
| **P3** | L1/L3: 清理死代码 | 不影响功能但增加维护成本 |
