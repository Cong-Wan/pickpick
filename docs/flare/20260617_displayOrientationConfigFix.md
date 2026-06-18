# 详情图方向与配置打包修复实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复 Normal 详情页 Metal 渲染上下翻转，确保分析参数实际使用 app bundle 中的 `rawViewer/config.yaml`，并在配置变化时避免继续复用旧分析缓存。

**架构：** 显示层只修正 `metalPhotoView` 中 CoreImage 到 Metal texture 的坐标映射，不改变业务旋转字段语义。配置层把 `rawViewer/config.yaml` 显式复制进 app bundle，并把加载顺序收敛为 `Bundle.main/config.yaml > defaults`，同时同步 defaults，避免静默回退旧参数。缓存层在加载 `analysis.json` 时比较当前配置与 `configSnapshot`，不一致则抛错让现有流程重新分析，避免已有目录继续使用旧参数结果。

**技术栈：** Swift、AppKit、CoreImage、MetalKit、Xcode project.pbxproj、xcodebuild、临时 Swift/Python 验证脚本。

---

## 前置约定

用户已明确：不需要更详细打印输出。本计划不新增常态打印；只保留现有 `appDebugLogger` / `logDrawDebug` 关键渲染日志，仍由既有 `--debug` 参数控制。

禁止事项：

- 不使用测试框架。
- 不新增测试 target。
- 不编排 Git 操作。
- 不修改 Duplicate 旋转持久化语义。

---

## 文件结构

将修改以下文件：

- `rawViewer.xcodeproj/project.pbxproj` — 显式把 `rawViewer/config.yaml` 加入 app Resources，保证构建产物中存在 `Contents/Resources/config.yaml`。
- `rawViewer/config.yaml` — 更新顶部注释，说明该配置由 app bundle 统一提供，不再由照片文件夹覆盖。
- `rawViewer/services/configLoader.swift` — 配置加载顺序改为 `Bundle.main/config.yaml > analysisConfig.defaults`。
- `rawViewer/services/analysisConfig.swift` — defaults 同步到当前 `rawViewer/config.yaml`，作为 bundle 配置缺失时的安全 fallback。
- `rawViewer/services/analysisStore.swift` — 读取缓存时支持校验 `configSnapshot`，配置不一致则拒绝旧缓存。
- `rawViewer/services/photoAnalysisService.swift` — 加载缓存前读取当前配置并传给 store 校验，复用 `appCoordinator` 现有 catch 后重新分析流程。
- `rawViewer/views/metalPhotoView.swift` — 新增专用 render transform helper，修正 Y 轴方向映射，保持业务旋转、缩放、平移语义。

不创建项目内测试文件；验证脚本只写入 `/tmp`。

---

## 通用验证约定

所有 `xcodebuild` 命令都固定使用同一个 DerivedData 目录，避免验证到 Xcode 自动生成目录中的旧 app：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
```

每次构建使用：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
```

每次验证 bundle app 使用：

```bash
$ test -d "$APP" && echo "APP_EXISTS"
# 预期：输出 APP_EXISTS。
```

---

## Task 1: 将 config.yaml 显式打进 app bundle

**目标：** Debug 构建后的 `pickpick.app/Contents/Resources/config.yaml` 存在，且内容与源码 `rawViewer/config.yaml` 完全一致。

**涉及的文件：**

- `rawViewer.xcodeproj/project.pbxproj` — 添加 `config.yaml` 的显式 PBX file reference / build file，并放入 Resources build phase。
- `rawViewer/config.yaml` — 更新配置来源注释。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer.xcodeproj/project.pbxproj`。

在 `objects = {` 后、`/* Begin PBXFileReference section */` 前新增完整 section：

```text
/* Begin PBXBuildFile section */
		D8CF00032FC92FEA00F93003 /* config.yaml in Resources */ = {isa = PBXBuildFile; fileRef = D8CF00022FC92FEA00F93002 /* config.yaml */; };
/* End PBXBuildFile section */

```

将 `PBXFileReference section` 从：

```text
/* Begin PBXFileReference section */
		D8DB71302FC92FEA00F93F82 /* pickpick.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = pickpick.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```

替换为：

```text
/* Begin PBXFileReference section */
		D8CF00022FC92FEA00F93002 /* config.yaml */ = {isa = PBXFileReference; lastKnownFileType = text.yaml; path = rawViewer/config.yaml; sourceTree = SOURCE_ROOT; };
		D8DB71302FC92FEA00F93F82 /* pickpick.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = pickpick.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
```

将 `PBXResourcesBuildPhase` 从：

```text
/* Begin PBXResourcesBuildPhase section */
		D8DB712E2FC92FEA00F93F82 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```

替换为：

```text
/* Begin PBXResourcesBuildPhase section */
		D8DB712E2FC92FEA00F93F82 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				D8CF00032FC92FEA00F93003 /* config.yaml in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */
```

说明：保留 synchronized group 的 `membershipExceptions`，避免自动同步和显式 Resources 同时复制同一个 `config.yaml` 产生重复资源命令。本任务用显式 Resources build phase 作为唯一复制路径。

- [ ] 修改 `rawViewer/config.yaml` 顶部注释。

将：

```yaml
# 本文件会被打包进 app bundle，文件夹内 config.yaml 优先级高于本文件。
```

替换为：

```yaml
# 本文件会被打包进 app bundle，分析参数统一来自 app bundle；照片文件夹内 config.yaml 不再覆盖本文件。
```

------

#### Step 2 — 运行验证

- [ ] 运行构建：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
# 预期：BUILD SUCCEEDED；后续验证均使用 $APP 指向本次固定 DerivedData 构建产物
```

- [ ] 验证 bundle 中存在 config，并与源码一致：

```bash
$ test -d "$APP" && echo "APP_EXISTS"
$ test -f "$APP/Contents/Resources/config.yaml" && echo "BUNDLE_CONFIG_EXISTS"
$ shasum -a 256 rawViewer/config.yaml "$APP/Contents/Resources/config.yaml"
# 预期：输出 APP_EXISTS 和 BUNDLE_CONFIG_EXISTS；两行 shasum 的 hash 完全一致。
```

- [ ] 如构建失败、bundle config 不存在或 hash 不一致，修复 `project.pbxproj` / `rawViewer/config.yaml`，然后重新运行本任务全部验证命令，直到通过。

------

✅ **完成的标志：** 构建通过，运行无异常，`pickpick.app/Contents/Resources/config.yaml` 存在，且与 `rawViewer/config.yaml` hash 一致。**在满足此条件之前不要开始 Task 2。**

------

## Task 2: 统一配置加载顺序并同步 defaults

**目标：** 分析配置只从 app bundle config 或 defaults 获取；defaults 与 `rawViewer/config.yaml` 当前值一致。

**涉及的文件：**

- `rawViewer/services/configLoader.swift` — 移除照片文件夹 `config.yaml` 优先逻辑。
- `rawViewer/services/analysisConfig.swift` — 同步默认曝光阈值与并发值。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer/services/configLoader.swift` 文件头。

将：

```swift
/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: 从 folderUrl/config.yaml → Bundle.main/config.yaml → 硬编码默认值三级降级加载 config；校验 ratio、blur threshold 和 Metal 并发边界。v1.4 明确配置加载器可在后台分析任务中使用
*/
```

替换为：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-17
Description: 配置加载顺序统一为 Bundle.main/config.yaml → 硬编码默认值；不再读取照片文件夹内 config.yaml，避免不同目录覆盖 app 全局分析参数
*/
```

- [ ] 修改 `configLoader.load(for:)`。

将：

```swift
    /// 加载顺序: folderUrl/config.yaml > Bundle.main/config.yaml > defaults
    public func load(for folderUrl: URL) throws -> analysisConfig {
        let folderConfig = folderUrl.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: folderConfig.path) {
            return try load(from: folderConfig)
        }
        if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
            return try load(from: bundleConfig)
        }
        return analysisConfig.defaults
    }
```

替换为：

```swift
    /// 加载顺序: Bundle.main/config.yaml > defaults
    public func load(for _: URL) throws -> analysisConfig {
        if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
            return try load(from: bundleConfig)
        }
        return analysisConfig.defaults
    }
```

- [ ] 修改 `rawViewer/services/analysisConfig.swift` 文件头。

将：

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值。v1.2 标注配置值可在后台分析任务中传递
*/
```

替换为：

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-17
Description: 分析参数配置结构 (exposure / blur / concurrency) + 默认值；同步默认参数到 rawViewer/config.yaml，避免 bundle 配置缺失时回退旧严格阈值
*/
```

- [ ] 修改 `analysisConfig.defaults`。

将：

```swift
nonisolated public extension analysisConfig {
    static let defaults = analysisConfig(
        exposure: exposureConfig(
            overexposePixelThreshold: 0.96,
            underexposePixelThreshold: 0.04,
            overexposeRatioLimit: 0.05,
            underexposeRatioLimit: 0.05
        ),
        blur: blurConfig(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0
        ),
        metalConcurrency: 2
    )
}
```

替换为：

```swift
nonisolated public extension analysisConfig {
    static let defaults = analysisConfig(
        exposure: exposureConfig(
            overexposePixelThreshold: 0.975,
            underexposePixelThreshold: 0.025,
            overexposeRatioLimit: 0.05,
            underexposeRatioLimit: 0.05
        ),
        blur: blurConfig(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0
        ),
        metalConcurrency: 6
    )
}
```

------

#### Step 2 — 运行验证

- [ ] 运行配置模型临时验证脚本（不新增项目测试文件，不使用测试框架）：

```bash
$ cat > /tmp/main.swift <<'SWIFT'
import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("CONFIG_VERIFICATION_FAILED: \(message)\n", stderr)
        exit(1)
    }
}

let loader = configLoader()
let sourceConfig = try loader.load(from: URL(fileURLWithPath: "rawViewer/config.yaml"))
let defaults = analysisConfig.defaults

require(sourceConfig == defaults, "analysisConfig.defaults must match rawViewer/config.yaml")
require(defaults.exposure.overexposePixelThreshold == 0.975, "default overexposePixelThreshold should be 0.975")
require(defaults.exposure.underexposePixelThreshold == 0.025, "default underexposePixelThreshold should be 0.025")
require(defaults.exposure.overexposeRatioLimit == 0.05, "default overexposeRatioLimit should be 0.05")
require(defaults.exposure.underexposeRatioLimit == 0.05, "default underexposeRatioLimit should be 0.05")
require(defaults.metalConcurrency == 6, "default metalConcurrency should be 6")

let fallback = try loader.load(for: URL(fileURLWithPath: "/tmp/folder-config-must-not-be-read"))
require(fallback == defaults, "load(for:) outside app bundle should fall back to defaults")

print("CONFIG_VERIFICATION_PASSED")
SWIFT
$ swiftc rawViewer/services/analysisConfig.swift rawViewer/services/configLoader.swift /tmp/main.swift -o /tmp/verifyConfig && /tmp/verifyConfig
# 预期：输出 CONFIG_VERIFICATION_PASSED。
# 说明：多文件 swiftc 编译中，包含顶层可执行语句的临时文件必须命名为 main.swift。
```

- [ ] 运行静态确认命令：

```bash
$ rg -n "folderConfig|appendingPathComponent\(\"config.yaml\"\)|Bundle.main.url\(forResource: \"config\"|overexposePixelThreshold: 0.975|underexposePixelThreshold: 0.025|metalConcurrency: 6" rawViewer/services/configLoader.swift rawViewer/services/analysisConfig.swift
# 预期：能看到 Bundle.main.config 加载、defaults 新值；不应看到 folderConfig，也不应看到 load(for:) 内拼接 folderUrl/config.yaml。
```

- [ ] 运行构建：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
# 预期：BUILD SUCCEEDED
```

- [ ] 如验证不通过，修复 `configLoader.swift` / `analysisConfig.swift`，然后重新运行本任务全部验证命令，直到通过。

------

✅ **完成的标志：** 构建通过，运行无异常，配置临时验证输出 `CONFIG_VERIFICATION_PASSED`，静态确认显示不再读取照片文件夹 config。**在满足此条件之前不要开始 Task 3。**

------

## Task 3: 配置变化时拒绝旧分析缓存

**目标：** 已有 `analysis.json` 的 `configSnapshot` 与当前 bundle/defaults 配置不一致时，缓存加载失败并触发现有重新分析流程，避免已有目录继续使用旧参数结果。

**涉及的文件：**

- `rawViewer/services/analysisStore.swift` — 增加带 `expectedConfig` 的缓存读取入口，比较 `configSnapshot`。
- `rawViewer/services/photoAnalysisService.swift` — `loadRecords(folderUrl:)` 读取当前配置，并调用 store 的配置校验读取入口。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer/services/analysisStore.swift` 文件头。

将：

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json。v1.2 增加串行 load-mutate-save 更新入口，避免快速 review 操作互相覆盖
*/
```

替换为：

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-17
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json；读取缓存时可校验 configSnapshot，配置变化时拒绝旧缓存以触发重新分析
*/
```

- [ ] 在 `summaryData` 后新增缓存错误类型。

将：

```swift
nonisolated struct summaryData: Codable, Sendable {
    var totalPhotos: Int = 0
    var blurry: Int = 0
    var overexposed: Int = 0
    var underexposed: Int = 0
    var normal: Int = 0
}

nonisolated public final class analysisStore: @unchecked Sendable {
```

替换为：

```swift
nonisolated struct summaryData: Codable, Sendable {
    var totalPhotos: Int = 0
    var blurry: Int = 0
    var overexposed: Int = 0
    var underexposed: Int = 0
    var normal: Int = 0
}

public enum analysisStoreError: Error, LocalizedError, Equatable {
    case staleConfigSnapshot

    public var errorDescription: String? {
        switch self {
        case .staleConfigSnapshot:
            return "analysis cache configSnapshot differs from current config"
        }
    }
}

nonisolated public final class analysisStore: @unchecked Sendable {
```

- [ ] 增加带配置校验的 public load 入口。

将：

```swift
    public func load(for folderUrl: URL) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl)
        }
    }

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
```

替换为：

```swift
    public func load(for folderUrl: URL) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl)
        }
    }

    public func load(for folderUrl: URL, expectedConfig: analysisConfig) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl, expectedConfig: expectedConfig)
        }
    }

    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
```

- [ ] 修改私有读取实现，比较 `configSnapshot`。

将：

```swift
    private func loadUnlocked(for folderUrl: URL) throws -> [photoItem] {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(analysisFile.self, from: data)
        return root.photos
    }
```

替换为：

```swift
    private func loadUnlocked(for folderUrl: URL, expectedConfig: analysisConfig? = nil) throws -> [photoItem] {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(analysisFile.self, from: data)
        if let expectedConfig, root.configSnapshot != expectedConfig {
            throw analysisStoreError.staleConfigSnapshot
        }
        return root.photos
    }
```

- [ ] 修改 `rawViewer/services/photoAnalysisService.swift` 文件头。

将：

```swift
/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: 主编排, 替代原 photoAnalyzerBridge。v1.4 保持失败分析不计入 normal summary，与分组语义一致
*/
```

替换为：

```swift
/*
Author: wilbur
Version: 1.5
Date: 2026-06-17
Description: 主编排, 替代原 photoAnalyzerBridge；加载缓存时校验当前分析配置，configSnapshot 不一致则让上层重新分析
*/
```

- [ ] 修改 `photoAnalysisService.loadRecords(folderUrl:)`。

将：

```swift
    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        try store.load(for: folderUrl)
    }
```

替换为：

```swift
    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        let config = try cfgLoader.load(for: folderUrl)
        return try store.load(for: folderUrl, expectedConfig: config)
    }
```

说明：`appCoordinator.startAnalysis(folderUrl:)` 已经在缓存加载失败时记录 debug 日志并继续调用 `analyzer.analyze(...)`，所以本任务不修改 `appCoordinator`。

------

#### Step 2 — 运行验证

- [ ] 运行缓存配置校验临时脚本（不新增项目测试文件，不使用测试框架）：

```bash
$ cat > /tmp/main.swift <<'SWIFT'
import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("CACHE_CONFIG_VERIFICATION_FAILED: \(message)\n", stderr)
        exit(1)
    }
}

let store = analysisStore()
let folderUrl = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("rawViewerCacheConfigVerification-\(UUID().uuidString)", isDirectory: true)
let currentConfig = analysisConfig.defaults
let oldConfig = analysisConfig(
    exposure: exposureConfig(
        overexposePixelThreshold: 0.96,
        underexposePixelThreshold: 0.04,
        overexposeRatioLimit: 0.05,
        underexposeRatioLimit: 0.05
    ),
    blur: blurConfig(
        laplacianThresholdRaw: 5000.0,
        laplacianThresholdJpg: 10.0
    ),
    metalConcurrency: 2
)

try store.save(folderUrl: folderUrl, records: [], config: oldConfig)
let records = try store.load(for: folderUrl, expectedConfig: oldConfig)
require(records.isEmpty, "same config should load cached records")

do {
    _ = try store.load(for: folderUrl, expectedConfig: currentConfig)
    require(false, "different config should throw staleConfigSnapshot")
} catch analysisStoreError.staleConfigSnapshot {
    print("CACHE_CONFIG_STALE_DETECTED")
}

try? FileManager.default.removeItem(at: store.resultsUrl(for: folderUrl).deletingLastPathComponent())
print("CACHE_CONFIG_VERIFICATION_PASSED")
SWIFT
$ swiftc rawViewer/models/photoModels.swift rawViewer/services/analysisConfig.swift rawViewer/services/analysisStore.swift /tmp/main.swift -o /tmp/verifyCacheConfig && /tmp/verifyCacheConfig
# 预期：输出 CACHE_CONFIG_STALE_DETECTED 和 CACHE_CONFIG_VERIFICATION_PASSED。
```

- [ ] 运行静态确认命令：

```bash
$ rg -n "staleConfigSnapshot|expectedConfig|cfgLoader.load\(for: folderUrl\)|store.load\(for: folderUrl, expectedConfig: config\)" rawViewer/services/analysisStore.swift rawViewer/services/photoAnalysisService.swift
# 预期：能看到 staleConfigSnapshot、expectedConfig 校验，以及 photoAnalysisService.loadRecords 先读取当前 config 再校验缓存。
```

- [ ] 运行构建：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
# 预期：BUILD SUCCEEDED
```

- [ ] 如验证不通过，修复 `analysisStore.swift` / `photoAnalysisService.swift`，然后重新运行本任务全部验证命令，直到通过。

------

✅ **完成的标志：** 构建通过，运行无异常，缓存配置临时验证输出 `CACHE_CONFIG_VERIFICATION_PASSED`，静态确认显示缓存读取会比较 `configSnapshot`。**在满足此条件之前不要开始 Task 4。**

------

## Task 4: 修复 Metal 详情页 Y 轴翻转

**目标：** `P1000860.JPG` 在详情页渲染时，源图顶部仍显示在详情图顶部；现有 90 / 180 / 270 业务旋转继续由 `rotationDegrees` 控制。

**涉及的文件：**

- `rawViewer/views/metalPhotoView.swift` — 修正 render transform，并保留 debug 日志受 `--debug` 控制。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer/views/metalPhotoView.swift` 文件头。

将：

```swift
/*
Author: wilbur
Version: 3.4
Date: 2026-06-17
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；进入窗口或布局变化后强制重绘已有图片避免 drawable 未就绪导致空白。v3.4 改用中转纹理（offscreen，usage 含 .shaderWrite）渲染 CIImage 再 blit 到 drawable，修复 CIContext 直接渲染 drawable 纹理因缺 .shaderWrite 被拒导致画面丢弃
*/
```

替换为：

```swift
/*
Author: wilbur
Version: 3.5
Date: 2026-06-17
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；修正 CoreImage 渲染到 Metal texture 的 Y 轴映射，避免详情图相对缩略图上下翻转
*/
```

- [ ] 在 `displayImage(from:)` 方法后、`draw(_:)` 方法前新增 helper。

将：

```swift
    private func displayImage(from image: CIImage) -> CIImage {
        switch normalizedRotationDegrees(rotationDegrees) {
        case 90:
            return image.oriented(forExifOrientation: 6)
        case 180:
            return image.oriented(forExifOrientation: 3)
        case 270:
            return image.oriented(forExifOrientation: 8)
        default:
            return image
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
```

替换为：

```swift
    private func displayImage(from image: CIImage) -> CIImage {
        switch normalizedRotationDegrees(rotationDegrees) {
        case 90:
            return image.oriented(forExifOrientation: 6)
        case 180:
            return image.oriented(forExifOrientation: 3)
        case 270:
            return image.oriented(forExifOrientation: 8)
        default:
            return image
        }
    }

    private func renderTransform(
        for extent: CGRect,
        targetSize: CGSize,
        effectiveScale: Double,
        panOffset: CGPoint
    ) -> CGAffineTransform {
        let outputWidth = Double(extent.width) * effectiveScale
        let outputHeight = Double(extent.height) * effectiveScale
        let imageLeft = (Double(targetSize.width) - outputWidth) / 2 + panOffset.x
        let imageTop = (Double(targetSize.height) - outputHeight) / 2 + panOffset.y

        return CGAffineTransform(
            a: effectiveScale,
            b: 0,
            c: 0,
            d: -effectiveScale,
            tx: imageLeft - Double(extent.minX) * effectiveScale,
            ty: imageTop + Double(extent.maxY) * effectiveScale
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
```

- [ ] 替换 `draw(_:)` 中的 transform 计算块。

将：

```swift
                let width = extent.width * effectiveScale
                let height = extent.height * effectiveScale
                let x = (Double(target.width) - width) / 2 + panOffset.x - extent.minX * effectiveScale
                let y = (Double(target.height) - height) / 2 + panOffset.y - extent.minY * effectiveScale
                let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: effectiveScale, y: effectiveScale)
                logDrawDebug("render image extent=\(extent) fitScale=\(fitScale) effectiveScale=\(effectiveScale) output=\(width)x\(height) origin=\(x),\(y)")
                ciContext.render(imageToRender.transformed(by: transform), to: offscreen, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
```

替换为：

```swift
                let width = Double(extent.width) * effectiveScale
                let height = Double(extent.height) * effectiveScale
                let targetSize = CGSize(width: target.width, height: target.height)
                let transform = renderTransform(
                    for: extent,
                    targetSize: targetSize,
                    effectiveScale: effectiveScale,
                    panOffset: panOffset
                )
                logDrawDebug("render image extent=\(extent) fitScale=\(fitScale) effectiveScale=\(effectiveScale) output=\(width)x\(height) transform=\(transform)")
                ciContext.render(imageToRender.transformed(by: transform), to: offscreen, commandBuffer: commandBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
```

说明：`logDrawDebug` 已经通过 `appDebugLogger.isEnabled` 受 `--debug` 控制，本任务不新增常态输出。

------

#### Step 2 — 运行验证

- [ ] 运行构建：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
# 预期：BUILD SUCCEEDED
```

- [ ] 运行静态确认命令：

```bash
$ rg -n "Version: 3.5|func renderTransform|d: -effectiveScale|imageTop \+ Double\(extent.maxY\)|CGAffineTransform\(translationX" rawViewer/views/metalPhotoView.swift
# 预期：能看到 Version: 3.5、renderTransform、d: -effectiveScale、ty 使用 extent.maxY；不应看到旧的 CGAffineTransform(translationX:).scaledBy 渲染路径。
```

- [ ] 运行像素级临时验证脚本（不新增项目测试文件，不使用测试框架）。该脚本复用本任务中的 transform 公式，对 `test_bak4/P1000860.JPG` 渲染后比较角落像素：

```bash
$ cat > /tmp/verifyP1000860Render.swift <<'SWIFT'
import Foundation
import CoreImage
import Metal
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("RENDER_ORIENTATION_VERIFICATION_FAILED: \(message)\n", stderr)
        exit(1)
    }
}

func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
}

let path = "/Users/wilbur/Downloads/test_bak4/P1000860.JPG"
let url = URL(fileURLWithPath: path)
require(FileManager.default.fileExists(atPath: path), "missing sample image at \(path)")

guard let sourceImage = CIImage(contentsOf: url) else {
    fputs("RENDER_ORIENTATION_VERIFICATION_FAILED: cannot load source image\n", stderr)
    exit(1)
}

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let commandBuffer = queue.makeCommandBuffer() else {
    fputs("RENDER_ORIENTATION_VERIFICATION_FAILED: cannot create Metal device\n", stderr)
    exit(1)
}

let targetWidth = 600
let targetHeight = 400
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: targetWidth,
    height: targetHeight,
    mipmapped: false
)
desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
desc.storageMode = .shared

guard let texture = device.makeTexture(descriptor: desc) else {
    fputs("RENDER_ORIENTATION_VERIFICATION_FAILED: cannot create texture\n", stderr)
    exit(1)
}

let ciContext = CIContext(mtlDevice: device)
let extent = sourceImage.extent
let effectiveScale = min(Double(targetWidth) / Double(extent.width), Double(targetHeight) / Double(extent.height))
let outputWidth = Double(extent.width) * effectiveScale
let outputHeight = Double(extent.height) * effectiveScale
let imageLeft = (Double(targetWidth) - outputWidth) / 2
let imageTop = (Double(targetHeight) - outputHeight) / 2
let transform = CGAffineTransform(
    a: effectiveScale,
    b: 0,
    c: 0,
    d: -effectiveScale,
    tx: imageLeft - Double(extent.minX) * effectiveScale,
    ty: imageTop + Double(extent.maxY) * effectiveScale
)

ciContext.render(
    sourceImage.transformed(by: transform),
    to: texture,
    commandBuffer: commandBuffer,
    bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
    colorSpace: CGColorSpaceCreateDeviceRGB()
)
commandBuffer.commit()
commandBuffer.waitUntilCompleted()
require(commandBuffer.status != .error, "command buffer failed: \(commandBuffer.error?.localizedDescription ?? "unknown")")

var bytes = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
texture.getBytes(
    &bytes,
    bytesPerRow: targetWidth * 4,
    from: MTLRegionMake2D(0, 0, targetWidth, targetHeight),
    mipmapLevel: 0
)

func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * targetWidth + x) * 4
    return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i + 0]))
}

let renderedTopLeft = pixel(0, 0)
let renderedBottomLeft = pixel(0, targetHeight - 1)
let expectedTopLeft = (234, 243, 250)
let expectedBottomLeft = (186, 187, 182)

require(distance(renderedTopLeft, expectedTopLeft) < 35, "top-left should remain source top-left, got \(renderedTopLeft)")
require(distance(renderedBottomLeft, expectedBottomLeft) < 35, "bottom-left should remain source bottom-left, got \(renderedBottomLeft)")

print("RENDER_ORIENTATION_VERIFICATION_PASSED topLeft=\(renderedTopLeft) bottomLeft=\(renderedBottomLeft)")
SWIFT
$ swift /tmp/verifyP1000860Render.swift
# 预期：输出 RENDER_ORIENTATION_VERIFICATION_PASSED，且 topLeft 接近 (234, 243, 250)，bottomLeft 接近 (186, 187, 182)。
```

- [ ] 如构建、静态确认或像素验证不通过，修复 `metalPhotoView.swift`，然后重新运行本任务全部验证命令，直到通过。

------

✅ **完成的标志：** 构建通过，运行无异常，静态确认不再有旧正向 Y transform，像素验证输出 `RENDER_ORIENTATION_VERIFICATION_PASSED`。**在满足此条件之前不要开始 Task 5。**

------

## Task 5: 端到端验证配置生效与 P1000860 显示方向

**目标：** 新构建的 app 使用 bundle config 生成新的 `configSnapshot`，且 `P1000860` 在 Normal 详情页与缩略图方向一致，旋转与放大拖拽交互无回归。

**涉及的文件：**

- 本任务不继续修改代码；只验证 Task 1-4 的结果。

------

#### Step 1 — 实现

- [ ] 本任务不修改代码。
- [ ] 不新增项目内测试文件，不新增测试 target，不使用测试框架，不编排 Git 操作。
- [ ] 保留 Task 1-4 的实现结果。

------

#### Step 2 — 运行验证

- [ ] 最终构建：

```bash
$ DERIVED_DATA="/tmp/rawViewerDerivedData"
$ APP="$DERIVED_DATA/Build/Products/Debug/pickpick.app"
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath "$DERIVED_DATA" build
# 预期：BUILD SUCCEEDED
```

- [ ] 再次确认 bundle config：

```bash
$ test -d "$APP" && echo "APP_EXISTS"
$ test -f "$APP/Contents/Resources/config.yaml" && echo "BUNDLE_CONFIG_EXISTS"
$ shasum -a 256 rawViewer/config.yaml "$APP/Contents/Resources/config.yaml"
# 预期：输出 APP_EXISTS 和 BUNDLE_CONFIG_EXISTS；两个 hash 一致。
```

- [ ] 备份并移走 `test_bak4` 旧缓存，强制本轮端到端验证从当前 bundle config 重新分析。不要删除备份：

```bash
$ CACHE_DIR="$HOME/Library/Application Support/rawViewer/CD306E087974A458"
$ if [ -f "$CACHE_DIR/analysis.json" ]; then cp "$CACHE_DIR/analysis.json" "/tmp/test_bak4_analysis_before_config_fix.json" && rm "$CACHE_DIR/analysis.json"; fi
$ test ! -f "$CACHE_DIR/analysis.json" && echo "TEST_BAK4_CACHE_CLEARED"
# 预期：输出 TEST_BAK4_CACHE_CLEARED。
```

说明：Task 3 已用临时脚本验证旧 `configSnapshot` 会被拒绝；本步骤移走样例缓存是为了让最终 UI 验证结果确定来自当前构建和当前配置。

- [ ] 手动运行 app 并重新分析 `test_bak4`：

```bash
$ open "$APP"
# 预期：App 启动无异常。手动选择 /Users/wilbur/Downloads/test_bak4，等待分析完成并进入 Groups 页面。
```

- [ ] 检查新生成的 `configSnapshot`：

```bash
$ python3 - <<'PY'
import json, os, sys
p = os.path.expanduser('~/Library/Application Support/rawViewer/CD306E087974A458/analysis.json')
if not os.path.exists(p):
    print('CONFIG_SNAPSHOT_VERIFICATION_FAILED: analysis.json not found', file=sys.stderr)
    sys.exit(1)
d = json.load(open(p))
config = d.get('configSnapshot') or {}
exposure = config.get('exposure') or {}
expected = {
    'overexposePixelThreshold': 0.975,
    'underexposePixelThreshold': 0.025,
    'overexposeRatioLimit': 0.05,
    'underexposeRatioLimit': 0.05,
}
for key, value in expected.items():
    if exposure.get(key) != value:
        print(f'CONFIG_SNAPSHOT_VERIFICATION_FAILED: {key}={exposure.get(key)!r}, expected {value!r}', file=sys.stderr)
        sys.exit(1)
if config.get('metalConcurrency') != 6:
    print(f"CONFIG_SNAPSHOT_VERIFICATION_FAILED: metalConcurrency={config.get('metalConcurrency')!r}, expected 6", file=sys.stderr)
    sys.exit(1)
for photo in d.get('photos', []):
    if photo.get('photoId') == 'P1000860':
        print('P1000860 rotationDegrees=', photo.get('rotationDegrees'))
        break
else:
    print('CONFIG_SNAPSHOT_VERIFICATION_FAILED: P1000860 not found', file=sys.stderr)
    sys.exit(1)
print('CONFIG_SNAPSHOT_VERIFICATION_PASSED')
PY
# 预期：输出 CONFIG_SNAPSHOT_VERIFICATION_PASSED，且 P1000860 rotationDegrees=0。
```

- [ ] 手动验证 `P1000860` 详情图方向：

```text
1. 在 App 中打开 /Users/wilbur/Downloads/test_bak4。
2. 进入 Normal 分组。
3. 在左侧缩略图中找到并打开 P1000860。
4. 对比左侧缩略图与右侧详情图方向。
5. 预期：缩略图和详情图方向一致，不再上下翻转。
```

- [ ] 手动验证业务旋转回归：

```text
1. 在 P1000860 详情页点击右旋一次。
2. 预期：详情图顺时针旋转 90°。
3. 再点击右旋一次。
4. 预期：详情图旋转到 180°，不是额外上下翻转。
5. 返回 Groups 再进入 Normal 和 P1000860。
6. 预期：旋转角度按 rotationDegrees 持久化展示。
```

- [ ] 手动验证放大后的拖拽方向回归：

```text
1. 在 P1000860 详情页点击放大，直到图像明显大于详情区域。
2. 鼠标/触控板按住详情图向右拖。
3. 预期：图像跟随向右移动。
4. 按住详情图向上拖。
5. 预期：图像跟随向上移动，不出现上下方向反向。
6. 点击重置缩放。
7. 预期：图像回到居中适配状态。
```

- [ ] 如最终构建、bundle config、configSnapshot 或手动显示/拖拽验证不通过，回到对应 Task 修复实现，然后重新运行 Task 5 全部验证命令，直到通过。

------

✅ **完成的标志：** 最终构建通过，bundle config 存在且 hash 一致，重新分析后的 `configSnapshot` 与 `rawViewer/config.yaml` 一致，`P1000860` 缩略图与详情图方向一致，业务旋转和放大拖拽仍可用。

------

## 自我复审

**1. 规范覆盖：**

- Recipe 中“P1000860 详情页方向异常”由 Task 4 修复，并由 Task 4 像素验证与 Task 5 手动验证覆盖。
- Recipe 中“config.yaml 没被用”由 Task 1 资源复制、Task 2 加载顺序/defaults、Task 5 configSnapshot 验证覆盖。
- Recipe 中“旧缓存不会自动改写”由 Task 3 的 `configSnapshot` 校验覆盖；Task 5 只为端到端 UI 验证移走样例缓存，确保结果来自当前构建。
- Duplicate 旋转语义明确为非目标，没有遗漏实现任务。

**2. 占位符扫描：**

计划中没有 TBD、TODO、稍后实现、与某任务类似、由工程师自行补齐等占位表达。涉及代码的步骤均给出明确替换块或完整临时验证脚本。

**3. 类型一致性：**

- `configLoader.load(for:)` 保持外部调用标签 `for` 不变，只移除内部参数名，不影响 `photoAnalysisService.analyze(folderUrl:)` 现有调用。
- `analysisConfig.defaults` 字段名与 `exposureConfig` / `analysisConfig` 定义一致。
- `analysisStore.load(for:expectedConfig:)` 接收 `analysisConfig`，与 `photoAnalysisService.loadRecords(folderUrl:)` 中 `cfgLoader.load(for:)` 的返回类型一致。
- `metalPhotoView.renderTransform(for:targetSize:effectiveScale:panOffset:)` 只在同文件 `draw(_:)` 调用，参数类型与 `CGRect`、`CGSize`、`Double`、`CGPoint` 一致。

**4. 验证完整性：**

- 每个任务都有构建或模型级运行命令。
- Task 1 验证 bundle resource 与 hash。
- Task 2 验证 defaults 与源码 config 一致，并静态确认不再读取 folder config。
- Task 3 验证缓存 `configSnapshot` 不一致会拒绝旧缓存，并构建通过。
- Task 4 验证构建、静态 transform 关键点和 P1000860 像素方向。
- Task 5 验证最终 app bundle、重新分析后的 configSnapshot、P1000860 手动显示方向、业务旋转回归和放大拖拽方向。

---

## 执行交接

计划已完成并保存到 `docs/flare/20260617_displayOrientationConfigFix.md`。两种执行选项：

**1. 子代理驱动（推荐）** —— 我为每个任务分派一个全新的子代理，在任务之间进行复审，快速迭代

**2. 内联执行** —— 使用 executing-plans 在本会话中执行任务，带复审检查点的批处理

选择哪种方式？
