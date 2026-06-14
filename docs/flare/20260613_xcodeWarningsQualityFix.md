# Xcode Warnings Quality Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the current Xcode warnings and runtime concurrency diagnostics while improving analysis failure semantics, JSON state consistency, and image loading cancellation behavior without adding any test framework or validation script.

**Architecture:** Keep AppKit/UI code on MainActor and explicitly keep analysis, file, Metal, image loading, and storage services usable from background work. Replace blocking GCD orchestration in `photoAnalysisService` with async limited-concurrency task groups, then tighten data semantics and manual validation coverage.

**Tech Stack:** Swift/AppKit, Metal/MetalKit/CoreImage/ImageIO, Objective-C++ LibRaw bridge, Xcode project configuration, manual validation only.

---

## Scope Check

This plan intentionally covers several related fixes because the warnings share one root cause: actor isolation and legacy GCD concurrency in the analysis pipeline. It does not add tests, test targets, or validation scripts because the approved recipe explicitly forbids them. Each task therefore uses implementation followed by build/manual verification.

## File Structure

Files to modify:

- `rawViewer.xcodeproj/project.pbxproj` — remove duplicate C++ runtime linker flag only.
- `rawViewer/main.swift` — replace top-level AppKit startup code with an explicit `@main` / `@MainActor` entry point.
- `rawViewer/appDelegate.swift` — mark delegate as MainActor if needed by compiler.
- `rawViewer/metal/metalAnalysisContext.swift` — make shared Metal context access non-UI-isolated and safe for analyzer defaults.
- `rawViewer/services/rawBayerAnalyzer.swift` — make analyzer dependencies concurrency-safe enough for background task execution.
- `rawViewer/services/jpgAnalyzer.swift` — make analyzer dependencies concurrency-safe enough for background task execution.
- `rawViewer/services/exifReader.swift` — remove the CFDate forced-cast warning.
- `rawViewer/services/fileScanner.swift` — mark scanner as sendable-safe if task-group compilation requires it.
- `rawViewer/services/duplicateGrouper.swift` — mark grouper as sendable-safe if task-group compilation requires it.
- `rawViewer/services/configLoader.swift` — mark loader as sendable-safe if task-group compilation requires it.
- `rawViewer/services/photoAnalysisService.swift` — replace GCD group/semaphore orchestration with async limited-concurrency task groups and failure-aware result merging.
- `rawViewer/models/photoModels.swift` — keep failed analyses out of Normal and make `displayUrl` respect real JPG/RAW availability.
- `rawViewer/services/analysisStore.swift` — serialize load/mutate/save critical sections while preserving JSON format and atomic writes.
- `rawViewer/models/jsonReviewStateStore.swift` — route mutations through the serialized store API.
- `rawViewer/services/photoDisplayService.swift` — reduce uncancellable GCD image loading work.
- `rawViewer/services/photoThumbnailService.swift` — reduce uncancellable GCD thumbnail loading work.
- `docs/manualValidation/20260613_xcodeWarningsQualityFix.md` — manual acceptance checklist required because tests and scripts are forbidden.

Files not to modify:

- UI layout files unless the compiler requires only actor annotation.
- `rawViewer/bridge/libRawBridge.*` in this plan; LibRaw error-string improvement is outside the warning-critical path.
- Any XCTest target, Package manifest, or validation script.

---

## Task 1: Clear low-risk build and entry-point warnings

**Goal:** A clean build no longer reports duplicate `-lc++`, AppKit delegate isolation, unused `index`, or CFDate forced-cast warnings.

**Files touched:**

- `rawViewer.xcodeproj/project.pbxproj` — remove duplicate `-lc++` linker flag.
- `rawViewer/main.swift` — convert top-level startup to explicit MainActor app entry.
- `rawViewer/appDelegate.swift` — make delegate isolation explicit if needed.
- `rawViewer/services/exifReader.swift` — remove CFDate cast warning.
- `rawViewer/services/photoAnalysisService.swift` — remove unused `index` while preserving current behavior until Task 3.

------

#### Step 1 — Implement

- [ ] In `rawViewer.xcodeproj/project.pbxproj`, remove `"-lc++",` from both Debug and Release `OTHER_LDFLAGS` arrays. Keep every other flag unchanged.

Before:

```text
OTHER_LDFLAGS = (
    "-lraw",
    "-lc++",
    "-framework",
    Accelerate,
```

After:

```text
OTHER_LDFLAGS = (
    "-lraw",
    "-framework",
    Accelerate,
```

- [ ] Replace the full contents of `rawViewer/main.swift` with:

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-13
Description: 显式 AppKit 入口。v1.1 使用 @main + @MainActor 包装启动流程，避免 Swift 6 下 AppKit delegate actor 隔离警告
*/

import AppKit

@main
struct pickpickApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = appDelegate()
        app.delegate = delegate
        app.run()
    }
}
```

- [ ] If the compiler still warns about `appDelegate` isolation, update the class declaration in `rawViewer/appDelegate.swift` from:

```swift
final class appDelegate: NSObject, NSApplicationDelegate {
```

to:

```swift
@MainActor
final class appDelegate: NSObject, NSApplicationDelegate {
```

Also update the file header version/date/description to:

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: 使用 AppKit application delegate 创建并持有 pickpick 主窗口控制器；清理启动强制解包，启动调试日志改为 --debug 控制。v1.3 明确 MainActor 隔离以匹配 AppKit delegate 生命周期
*/
```

- [ ] In `rawViewer/services/exifReader.swift`, replace:

```swift
let absolute = CFDateGetAbsoluteTime(value as! CFDate)
```

with:

```swift
guard let date = value as? CFDate else {
    return .notFound
}
let absolute = CFDateGetAbsoluteTime(date)
```

Also update the file header to:

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-13
Description: 使用 ImageIO 读取 EXIF DateTimeOriginal, 失败回退到 Spotlight kMDItemContentCreationDate。v1.1 调整 Spotlight CFDate 转换写法以消除 Swift warning
*/
```

- [ ] In `rawViewer/services/photoAnalysisService.swift`, replace both loops that bind an unused `index`:

```swift
for (index, pair) in pairs.enumerated() {
```

with:

```swift
for pair in pairs {
```

Also update the header to:

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 主编排, 替代原 photoAnalyzerBridge。v1.2 移除未使用循环 index，后续并发编排在独立任务中重构
*/
```

------

#### Step 2 — Verify based on the plan goal

No test target, test framework, or script may be created. Verify with a clean Xcode build only:

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task1_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Then inspect warnings manually:

```bash
rg -n "duplicate libraries|forced downcast|Immutable value 'index'|Main actor-isolated conformance" /tmp/pickpick_task1_build.log
```

Expected result: no matching output.

------

✅ **Done when:** The clean build succeeds and the four warning patterns above are absent. Do not start Task 2 until this condition is met.

---

## Task 2: Make Metal analysis context and analyzers background-callable

**Goal:** A clean build no longer reports `metalAnalysisContext.shared()` as a main actor-isolated call from JPG/RAW analyzer initializers.

**Files touched:**

- `rawViewer/metal/metalAnalysisContext.swift` — make shared context access independent of UI actor.
- `rawViewer/services/jpgAnalyzer.swift` — make default context provider sendable and non-UI dependent.
- `rawViewer/services/rawBayerAnalyzer.swift` — make default context provider sendable and non-UI dependent.

------

#### Step 1 — Implement

- [ ] In `rawViewer/metal/metalAnalysisContext.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: Metal 设备 / queue / pipeline 上下文；初始化失败改为 throws，避免设备或 shader 异常时 fatalError 退出。v1.2 将 shared 访问声明为非 UI actor 隔离，供后台分析任务安全调用
*/
```

- [ ] In the same file, replace the static cache and shared function block:

```swift
private static let cachedResult: Result<metalAnalysisContext, Error> = Result {
    try metalAnalysisContext()
}

public static func shared() throws -> metalAnalysisContext {
    try cachedResult.get()
}
```

with:

```swift
private nonisolated static let cachedResult: Result<metalAnalysisContext, Error> = Result {
    try metalAnalysisContext()
}

public nonisolated static func shared() throws -> metalAnalysisContext {
    try cachedResult.get()
}
```

If the compiler rejects `nonisolated static let` for this Swift toolchain, use this fallback in the same file instead:

```swift
private static let contextLock = NSLock()
private static var cachedResult: Result<metalAnalysisContext, Error>?

public nonisolated static func shared() throws -> metalAnalysisContext {
    contextLock.lock()
    defer { contextLock.unlock() }
    if let cachedResult {
        return try cachedResult.get()
    }
    let result = Result { try metalAnalysisContext() }
    cachedResult = result
    return try result.get()
}
```

When using the fallback, add `import Foundation` is already present, so no import change is needed.

- [ ] In `rawViewer/services/jpgAnalyzer.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析。v1.3 让 contextProvider 可从后台分析任务调用并消除 MainActor shared 警告
*/
```

- [ ] In the same file, replace:

```swift
private let contextProvider: () throws -> metalAnalysisContext
```

with:

```swift
private let contextProvider: @Sendable () throws -> metalAnalysisContext
```

- [ ] Replace the initializer signature:

```swift
public init(
    contextProvider: @escaping () throws -> metalAnalysisContext = metalAnalysisContext.shared,
    maxJpgPixels: Int = 100_000_000
) {
```

with:

```swift
public init(
    contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() },
    maxJpgPixels: Int = 100_000_000
) {
```

- [ ] In `rawViewer/services/rawBayerAnalyzer.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: RAW Bayer 原始值分析: LibRaw 取数据, Metal GPU 4 个 kernel, CPU 后处理曝光/虚焦/DR。v1.3 让 contextProvider 可从后台分析任务调用并消除 MainActor shared 警告
*/
```

- [ ] In the same file, replace:

```swift
private let contextProvider: () throws -> metalAnalysisContext
```

with:

```swift
private let contextProvider: @Sendable () throws -> metalAnalysisContext
```

- [ ] Replace the initializer:

```swift
public init(contextProvider: @escaping () throws -> metalAnalysisContext = metalAnalysisContext.shared) {
    self.contextProvider = contextProvider
}
```

with:

```swift
public init(contextProvider: @escaping @Sendable () throws -> metalAnalysisContext = { try metalAnalysisContext.shared() }) {
    self.contextProvider = contextProvider
}
```

------

#### Step 2 — Verify based on the plan goal

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task2_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Inspect warnings:

```bash
rg -n "main actor-isolated static method 'shared\(\)'|Call to main actor-isolated static method" /tmp/pickpick_task2_build.log
```

Expected result: no matching output.

------

✅ **Done when:** The clean build succeeds and no `metalAnalysisContext.shared()` actor-isolation warning remains. Do not start Task 3 until this condition is met.

---

## Task 3: Replace blocking analysis orchestration with async limited concurrency

**Goal:** Analyzing a folder no longer uses `DispatchGroup.wait` or `DispatchSemaphore.wait`, preserves current progress semantics, and completes into the same saved analysis format.

**Files touched:**

- `rawViewer/services/photoAnalysisService.swift` — replace GCD orchestration with limited task groups.
- `rawViewer/services/exifReader.swift` — mark reader safe for concurrent use if compiler requires it.
- `rawViewer/services/rawBayerAnalyzer.swift` — mark analyzer safe for task group capture if compiler requires it.
- `rawViewer/services/jpgAnalyzer.swift` — mark analyzer safe for task group capture if compiler requires it.

------

#### Step 1 — Implement

- [ ] In `rawViewer/services/photoAnalysisService.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: 主编排, 替代原 photoAnalyzerBridge。v1.3 使用 async 限流 task group 替换 DispatchGroup/Semaphore 阻塞等待，保留扫描/EXIF/分析/分组/保存流程
*/
```

- [ ] Add these private helper structs inside `photoAnalysisService` before `// MARK: - Analyze`:

```swift
    private struct exifStageResult {
        let index: Int
        let pair: photoFilePair
        let item: photoItem
        let shootingTime: duplicateGrouper.entry?
    }

    private struct analysisStageResult {
        let index: Int
        let photoId: String
        let result: rawAnalysisResult
        let phase: analysisPhase
    }
```

- [ ] Replace the entire current `public func analyze(folderUrl:progress:)` implementation with this implementation:

```swift
    public func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary {
        let config = try cfgLoader.load(for: folderUrl)

        progress(analysisProgress(phase: .scanning, completedCount: 0, totalCount: 0, overallProgress: 0.0))
        let pairs = try scanner.scanTopLevel(folderUrl)
        let totalCount = pairs.count
        guard totalCount > 0 else {
            progress(analysisProgress(phase: .completed, completedCount: 0, totalCount: 0, overallProgress: 1.0))
            return analysisSummary(totalPhotos: 0, blurryCount: 0, overexposedCount: 0, underexposedCount: 0, normalCount: 0)
        }

        progress(analysisProgress(phase: .exifReading, completedCount: 0, totalCount: totalCount, overallProgress: 0.1))
        let exifResults = await runExifStage(pairs: pairs, totalCount: totalCount, progress: progress)

        var recordsById: [String: photoItem] = [:]
        var shootingTimes: [duplicateGrouper.entry] = []
        for result in exifResults {
            recordsById[result.item.photoId] = result.item
            if let shootingTime = result.shootingTime {
                shootingTimes.append(shootingTime)
            }
        }

        progress(analysisProgress(phase: .rawAnalysis, completedCount: 0, totalCount: totalCount, overallProgress: 0.2))
        let analysisResults = await runAnalysisStage(pairs: pairs, config: config, totalCount: totalCount, progress: progress)

        for result in analysisResults {
            if var item = recordsById[result.photoId] {
                item.isBlurry = result.result.isBlurry
                item.exposureStatus = result.result.exposureStatus
                item.dynamicRange = result.result.dynamicRange
                item.analysisSource = result.result.analysisSource
                recordsById[result.photoId] = item
            }
        }

        progress(analysisProgress(phase: .duplicateGrouping, completedCount: 0, totalCount: totalCount, overallProgress: 0.85))
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, groupId) in groupMap {
            if var item = recordsById[photoId] {
                item.reviewGroupId = groupId
                recordsById[photoId] = item
            }
        }

        progress(analysisProgress(phase: .organizing, completedCount: 0, totalCount: totalCount, overallProgress: 0.9))
        let finalRecords = pairs.compactMap { recordsById[$0.photoId] }
        try store.save(folderUrl: folderUrl, records: finalRecords, config: config)

        let summary = computeSummary(finalRecords)
        progress(analysisProgress(phase: .completed, completedCount: totalCount, totalCount: totalCount, overallProgress: 1.0))
        return summary
    }
```

- [ ] Add these private helper methods below `// MARK: - Private Helpers` and above `runJpgFallback`:

```swift
    private func runExifStage(
        pairs: [photoFilePair],
        totalCount: Int,
        progress: @escaping (analysisProgress) -> Void
    ) async -> [exifStageResult] {
        let concurrency = min(8, max(1, pairs.count))
        var nextIndex = 0
        var completed = 0
        var results: [exifStageResult] = []
        results.reserveCapacity(pairs.count)

        await withTaskGroup(of: exifStageResult.self) { group in
            func enqueueNext() {
                guard nextIndex < pairs.count else { return }
                let index = nextIndex
                let pair = pairs[index]
                nextIndex += 1
                group.addTask { [exif] in
                    let timeResult = exif.readBestShootingTime(rawPath: pair.rawPath, jpgPath: pair.jpgPath)
                    let item = photoItem(
                        photoId: pair.photoId,
                        jpgPath: pair.jpgPath ?? pair.rawPath ?? "",
                        rawPath: pair.rawPath,
                        analysisSource: ""
                    )
                    let shootingTime = timeResult.found
                        ? duplicateGrouper.entry(photoId: pair.photoId, epochSeconds: timeResult.epochSeconds)
                        : nil
                    return exifStageResult(index: index, pair: pair, item: item, shootingTime: shootingTime)
                }
            }

            for _ in 0..<concurrency {
                enqueueNext()
            }

            while let result = await group.next() {
                results.append(result)
                completed += 1
                let overall = 0.1 + 0.1 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: .exifReading, completedCount: completed, totalCount: totalCount, overallProgress: overall))
                enqueueNext()
            }
        }

        return results.sorted { $0.index < $1.index }
    }

    private func runAnalysisStage(
        pairs: [photoFilePair],
        config: analysisConfig,
        totalCount: Int,
        progress: @escaping (analysisProgress) -> Void
    ) async -> [analysisStageResult] {
        let concurrency = min(max(config.metalConcurrency, 1), max(1, pairs.count))
        var nextIndex = 0
        var completed = 0
        var results: [analysisStageResult] = []
        results.reserveCapacity(pairs.count)

        await withTaskGroup(of: analysisStageResult.self) { group in
            func enqueueNext() {
                guard nextIndex < pairs.count else { return }
                let index = nextIndex
                let pair = pairs[index]
                nextIndex += 1
                group.addTask { [rawAnalyzer, jpgAnalyzerService] in
                    let result: rawAnalysisResult
                    let phase: analysisPhase
                    if pair.hasRaw, let rawPath = pair.rawPath {
                        phase = .rawAnalysis
                        do {
                            result = try rawAnalyzer.analyze(rawPath: rawPath, config: config)
                        } catch {
                            result = self.runJpgFallback(pair: pair, config: config)
                        }
                    } else if pair.hasJpg, let jpgPath = pair.jpgPath {
                        phase = .jpgAnalysis
                        do {
                            result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                        } catch {
                            result = rawAnalysisResult(
                                isBlurry: false,
                                exposureStatus: "failed",
                                dynamicRange: nil,
                                blackLevel: 0,
                                whiteLevel: 0,
                                analysisSource: "jpg_failed"
                            )
                        }
                    } else {
                        phase = .jpgAnalysis
                        result = rawAnalysisResult(
                            isBlurry: false,
                            exposureStatus: "failed",
                            dynamicRange: nil,
                            blackLevel: 0,
                            whiteLevel: 0,
                            analysisSource: "none"
                        )
                    }
                    return analysisStageResult(index: index, photoId: pair.photoId, result: result, phase: phase)
                }
            }

            for _ in 0..<concurrency {
                enqueueNext()
            }

            while let result = await group.next() {
                results.append(result)
                completed += 1
                let overall = 0.2 + 0.6 * Double(completed) / Double(totalCount)
                progress(analysisProgress(phase: result.phase, completedCount: completed, totalCount: totalCount, overallProgress: overall))
                enqueueNext()
            }
        }

        return results.sorted { $0.index < $1.index }
    }
```

- [ ] The helper above captures `self.runJpgFallback` inside a task group. If the compiler reports a Sendable warning for capturing `self`, add this focused helper below `runAnalysisStage` and change the fallback call to use the helper capture instead.

Add:

```swift
    private func makeJpgFallbackRunner(config: analysisConfig) -> @Sendable (photoFilePair) -> rawAnalysisResult {
        let jpgAnalyzerService = self.jpgAnalyzerService
        return { pair in
            guard pair.hasJpg, let jpgPath = pair.jpgPath else {
                return rawAnalysisResult(
                    isBlurry: false,
                    exposureStatus: "failed",
                    dynamicRange: nil,
                    blackLevel: 0,
                    whiteLevel: 0,
                    analysisSource: "jpg_failed"
                )
            }
            do {
                let result = try jpgAnalyzerService.analyze(jpgPath: jpgPath, config: config)
                return rawAnalysisResult(
                    isBlurry: result.isBlurry,
                    exposureStatus: result.exposureStatus,
                    dynamicRange: result.dynamicRange,
                    blackLevel: result.blackLevel,
                    whiteLevel: result.whiteLevel,
                    analysisSource: "jpg_fallback"
                )
            } catch {
                return rawAnalysisResult(
                    isBlurry: false,
                    exposureStatus: "failed",
                    dynamicRange: nil,
                    blackLevel: 0,
                    whiteLevel: 0,
                    analysisSource: "jpg_failed"
                )
            }
        }
    }
```

Then before `withTaskGroup` in `runAnalysisStage`, add:

```swift
let jpgFallback = makeJpgFallbackRunner(config: config)
```

And replace:

```swift
result = self.runJpgFallback(pair: pair, config: config)
```

with:

```swift
result = jpgFallback(pair)
```

- [ ] Update existing `runJpgFallback(pair:config:)` failure branches so they return `exposureStatus: "failed"` instead of `"normal"` when no fallback result is available:

```swift
exposureStatus: "failed",
```

Only successful JPG fallback should preserve the analyzer's real exposure status.

- [ ] If the compiler reports Sendable warnings for service captures in task group closures, add the following focused conformance annotations:

In `rawViewer/services/exifReader.swift`:

```swift
public final class exifReader: @unchecked Sendable {
```

In `rawViewer/services/rawBayerAnalyzer.swift`:

```swift
public final class rawBayerAnalyzer: rawBayerAnalyzing, @unchecked Sendable {
```

In `rawViewer/services/jpgAnalyzer.swift`:

```swift
public final class jpgAnalyzer: jpgAnalyzing, @unchecked Sendable {
```

And update protocol declarations if needed:

```swift
public protocol rawBayerAnalyzing: AnyObject, Sendable {
```

```swift
public protocol jpgAnalyzing: AnyObject, Sendable {
```

------

#### Step 2 — Verify based on the plan goal

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task3_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Inspect warnings and forbidden blocking calls:

```bash
rg -n "DispatchGroup|DispatchSemaphore|\.wait\(|Instance method 'wait'|Thread Performance Checker" rawViewer/services/photoAnalysisService.swift /tmp/pickpick_task3_build.log
```

Expected result: no matching output for `photoAnalysisService.swift`, and no build warning about `wait`.

Manual App verification:

1. Launch App from Xcode.
2. Select a folder with at least one JPG and one RAW if available.
3. Confirm progress goes through scanning, EXIF, RAW/JPG analysis, grouping, organizing, completed.
4. Confirm the group grid appears after completion.
5. Watch Xcode console during analysis; the previous `photoAnalysisService.analyze` Thread Performance Checker backtrace should not appear.

------

✅ **Done when:** Clean build succeeds, `photoAnalysisService.swift` no longer contains blocking GCD wait/semaphore orchestration, and manual folder analysis still reaches the group grid. Do not start Task 4 until this condition is met.

---

## Task 4: Keep failed analyses out of Normal and fix display URL semantics

**Goal:** Photos whose analysis failed are not shown as Normal, and RAW-only photos no longer produce a JPG display URL.

**Files touched:**

- `rawViewer/models/photoModels.swift` — add failure semantic helpers, update group creation, update display URL availability checks.
- `rawViewer/services/photoAnalysisService.swift` — ensure summary treats failed analysis as not normal.

------

#### Step 1 — Implement

- [ ] In `rawViewer/models/photoModels.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.9
Date: 2026-06-13
Description: 新增照片展示旋转角度持久化，并保持旧 analysis.json 解码兼容；补充 reviewStatus 解码同名遮蔽说明。v1.9 明确分析失败不归入 Normal，并修正 displayUrl 对 RAW-only/JPG-only 的文件可用性判断
*/
```

- [ ] Add this extension after the existing `public extension photoItem` block with `hasExistingJpgFile` / `hasExistingRawFile`:

```swift
public extension photoItem {
    var hasFailedAnalysis: Bool {
        exposureStatus == "failed" || analysisSource == "jpg_failed" || analysisSource == "none"
    }

    var isNormalAnalysisResult: Bool {
        !hasFailedAnalysis && !isBlurry && exposureStatus == "normal"
    }
}
```

- [ ] In `makeVisiblePhotoGroups(from:)`, replace:

```swift
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && !isInValidDuplicateGroup($0) }, into: &groups)
```

with:

```swift
appendGroup(.normal, photos: visiblePhotos.filter { $0.isNormalAnalysisResult && !isInValidDuplicateGroup($0) }, into: &groups)
```

- [ ] Replace the full `displayUrl(for:source:)` function with:

```swift
public func displayUrl(for photo: photoItem, source: displaySource) -> displayAvailability {
    switch source {
    case .jpg:
        guard photo.hasExistingJpgFile() else { return .unavailable }
        return .available(URL(fileURLWithPath: photo.jpgPath))
    case .raw:
        guard photo.hasExistingRawFile(), let rawPath = photo.rawPath else { return .unavailable }
        return .available(URL(fileURLWithPath: rawPath))
    }
}
```

- [ ] In `rawViewer/services/photoAnalysisService.swift`, replace this condition in `computeSummary(_:)`:

```swift
if !item.isBlurry && item.exposureStatus == "normal" { normal += 1 }
```

with:

```swift
if item.isNormalAnalysisResult { normal += 1 }
```

Also update the file header version/date/description to:

```swift
/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: 主编排, 替代原 photoAnalyzerBridge。v1.4 保持失败分析不计入 normal summary，与分组语义一致
*/
```

------

#### Step 2 — Verify based on the plan goal

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task4_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Manual App verification:

1. Select a folder containing RAW-only photos. Confirm JPG segment is disabled for RAW-only photos.
2. Select a folder containing JPG-only photos. Confirm RAW segment is disabled for JPG-only photos.
3. Select a folder containing a damaged or unsupported JPG/RAW file. Confirm App does not crash.
4. Confirm damaged or unsupported files are not counted in the Normal group.

------

✅ **Done when:** Clean build succeeds and manual checks confirm failed analyses do not appear as Normal and display source availability matches actual file types. Do not start Task 5 until this condition is met.

---

## Task 5: Serialize analysis JSON mutations without changing schema

**Goal:** Rapid review operations no longer risk overlapping load/mutate/save cycles while preserving the existing `analysis.json` schema.

**Files touched:**

- `rawViewer/services/analysisStore.swift` — add serialized mutation API.
- `rawViewer/models/jsonReviewStateStore.swift` — route state changes through the serialized mutation API.

------

#### Step 1 — Implement

- [ ] In `rawViewer/services/analysisStore.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 在 ~/Library/Application Support/rawViewer/{folderHash}/ 存储 analysis.json。v1.2 增加串行 load-mutate-save 更新入口，避免快速 review 操作互相覆盖
*/
```

- [ ] Add this property after `private let appSupportDir: URL`:

```swift
    private let ioQueue = DispatchQueue(label: "rawViewer.analysisStore.io")
```

- [ ] Add this method after `public func save(folderUrl:records:config:) throws`:

```swift
    public func update(folderUrl: URL, mutate: (inout [photoItem]) throws -> Void) throws {
        try ioQueue.sync {
            var records = try loadUnlocked(for: folderUrl)
            try mutate(&records)
            try saveUnlocked(folderUrl: folderUrl, records: records, config: nil)
        }
    }
```

- [ ] Replace `public func load(for folderUrl: URL) throws -> [photoItem]` implementation with:

```swift
    public func load(for folderUrl: URL) throws -> [photoItem] {
        try ioQueue.sync {
            try loadUnlocked(for: folderUrl)
        }
    }
```

- [ ] Replace `public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws` implementation with:

```swift
    public func save(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        try ioQueue.sync {
            try saveUnlocked(folderUrl: folderUrl, records: records, config: config)
        }
    }
```

- [ ] Add these private unlocked methods below `save(folderUrl:records:config:)` and above `summaryCounts(_:)`:

```swift
    private func loadUnlocked(for folderUrl: URL) throws -> [photoItem] {
        let url = resultsUrl(for: folderUrl)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(analysisFile.self, from: data)
        return root.photos
    }

    private func saveUnlocked(folderUrl: URL, records: [photoItem], config: analysisConfig? = nil) throws {
        let dir = resultsUrl(for: folderUrl).deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var existing = analysisFile()
        let url = resultsUrl(for: folderUrl)
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            existing = try JSONDecoder().decode(analysisFile.self, from: data)
        }

        existing.schemaVersion = "2.0"
        existing.folderPath = folderUrl.path
        existing.updatedAt = isoNow()
        if existing.createdAt.isEmpty { existing.createdAt = existing.updatedAt }
        if let config {
            existing.configSnapshot = config
        }
        existing.photos = records
        existing.summary = summaryCounts(records)

        let data = try JSONEncoder().encode(existing)
        try data.write(to: url, options: .atomic)
    }
```

- [ ] Remove the old load/save bodies duplicated by the unlocked methods so the file has exactly one public `load`, one public `save`, one public `update`, one private `loadUnlocked`, and one private `saveUnlocked`.

- [ ] In `rawViewer/models/jsonReviewStateStore.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.7
Date: 2026-06-13
Description: 新增 Restore Normal 和照片旋转角度持久化接口；保留 review 状态写回时既有 configSnapshot。v1.7 通过 analysisStore 串行 update 入口执行 JSON 状态变更
*/
```

- [ ] Replace `public func update(_ mutate: (inout [photoItem]) -> Void) throws` with:

```swift
    public func update(_ mutate: (inout [photoItem]) -> Void) throws {
        guard let folderUrl else { return }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            mutate(&items)
        }
    }
```

- [ ] Replace `private func updateThrowing(_ mutate: (inout [photoItem]) throws -> Void) throws` with:

```swift
    private func updateThrowing(_ mutate: (inout [photoItem]) throws -> Void) throws {
        guard let folderUrl else { return }
        try analysisStore.shared.update(folderUrl: folderUrl) { items in
            try mutate(&items)
        }
    }
```

------

#### Step 2 — Verify based on the plan goal

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task5_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Manual App verification:

1. Analyze a folder and open a group.
2. Rotate the current photo multiple times quickly.
3. Delete one photo.
4. Use Restore Normal on one abnormal photo if such a group exists.
5. Quit and relaunch the App.
6. Reopen the same folder and confirm rotations, deletion status, and Restore Normal effects persist.
7. If Xcode console shows JSON decode errors, fix the storage implementation before proceeding.

------

✅ **Done when:** Clean build succeeds and rapid manual review operations persist correctly after relaunch. Do not start Task 6 until this condition is met.

---

## Task 6: Reduce uncancellable image loading work

**Goal:** Cancelling UI image load tasks stops downstream image loading work before decode whenever possible, while preserving the existing image service public API.

**Files touched:**

- `rawViewer/services/photoDisplayService.swift` — replace GCD continuations with cancellable detached tasks.
- `rawViewer/services/photoThumbnailService.swift` — replace GCD continuations with cancellable detached tasks.

------

#### Step 1 — Implement

- [ ] In `rawViewer/services/photoDisplayService.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-13
Description: JPG/RAW display 图加载服务，独立缓存 JPG(20) 和 RAW(10)，加载前按文件类型校验，避免 RAW-only 照片被当作 JPG 显示。v1.3 使用可取消 detached task 收敛后台解码工作
*/
```

- [ ] Replace `loadDisplayJpg(for:)` implementation with:

```swift
    public func loadDisplayJpg(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingJpgFile(fileManager: fileManager) else {
            return .unavailable("JPG missing")
        }

        let key = "\(photo.photoId)|displayJpg" as NSString
        if let cached = jpgCache.object(forKey: key) {
            return .image(cached.image)
        }

        let photoId = photo.photoId
        let jpgPath = photo.jpgPath
        let result = await Task.detached(priority: .userInitiated) { [weak self] -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadJpg(jpgPath: jpgPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                let key = "\(photoId)|displayJpg" as NSString
                self.jpgCache.setObject(photoCachedImage(image: image), forKey: key)
            }
            return result
        }.value
        return result
    }
```

- [ ] Replace `loadDisplayRaw(for:)` implementation with:

```swift
    public func loadDisplayRaw(for photo: photoItem) async -> photoImageResult {
        guard photo.hasExistingRawFile(fileManager: fileManager) else {
            return .unavailable("RAW missing")
        }

        let key = "\(photo.photoId)|displayRaw" as NSString
        if let cached = rawCache.object(forKey: key) {
            return .image(cached.image)
        }

        let photoId = photo.photoId
        let rawPath = photo.rawPath
        let result = await Task.detached(priority: .userInitiated) { [weak self] -> photoImageResult in
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            guard let self else { return .unavailable("Service deallocated") }
            let result = self.loadRaw(rawPath: rawPath)
            guard !Task.isCancelled else { return .unavailable("Cancelled") }
            if case .image(let image) = result {
                let key = "\(photoId)|displayRaw" as NSString
                self.rawCache.setObject(photoCachedImage(image: image), forKey: key)
            }
            return result
        }.value
        return result
    }
```

- [ ] If the compiler reports Sendable warnings for `photoDisplayService`, add this focused class annotation:

```swift
public final class photoDisplayService: @unchecked Sendable {
```

- [ ] In `rawViewer/services/photoThumbnailService.swift`, update the file header to:

```swift
/*
Author: wilbur
Version: 1.2
Date: 2026-06-13
Description: 基于 CGImageSource 的降采样缩略图加载服务，避免加载完整图像，缓存 NSImage 以隔离内存占用。v1.2 使用可取消 detached task 收敛后台缩略图解码工作
*/
```

- [ ] Replace `loadThumbnail(for:maxWidth:maxHeight:)` implementation with:

```swift
    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let photoId = photo.photoId
        let jpgPath = photo.jpgPath
        let maxPixelSize = max(maxWidth, maxHeight)
        return await Task.detached(priority: .userInitiated) { [weak self] -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }
            let image = self.decodeThumbnail(path: jpgPath, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return nil }
            if let image {
                let key = "\(photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
                self.cache.setObject(image, forKey: key)
            }
            return image
        }.value
    }
```

- [ ] If the compiler reports Sendable warnings for `photoThumbnailService`, add this focused class annotation:

```swift
public final class photoThumbnailService: @unchecked Sendable {
```

------

#### Step 2 — Verify based on the plan goal

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_task6_build.log
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Manual App verification:

1. Open a folder with many photos.
2. Rapidly scroll the thumbnail list.
3. Rapidly switch photos with Up/Down keys.
4. Confirm old images do not appear after switching.
5. Confirm the app remains responsive and memory does not grow continuously during repeated switching.

------

✅ **Done when:** Clean build succeeds and rapid manual image navigation remains correct and responsive. Do not start Task 7 until this condition is met.

---

## Task 7: Add manual validation checklist document

**Goal:** The project contains a written manual checklist that covers every approved verification path without adding tests or scripts.

**Files touched:**

- `docs/manualValidation/20260613_xcodeWarningsQualityFix.md` — manual validation checklist.

------

#### Step 1 — Implement

- [ ] Create `docs/manualValidation/20260613_xcodeWarningsQualityFix.md` with this full content:

```markdown
# Manual Validation — Xcode Warnings Quality Fix

## Constraints

- Do not add XCTest, Quick, Nimble, or any other test framework.
- Do not add validation scripts.
- Validation uses Xcode build output, Xcode console, and manual App behavior only.

## Build Validation

1. Run:

   ```bash
   xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build
   ```

2. Confirm build output contains:

   ```text
   ** BUILD SUCCEEDED **
   ```

3. Confirm Xcode no longer reports these warning families:

   - duplicate `-lc++`
   - CFDate forced downcast warning
   - unused `index`
   - AppKit delegate MainActor warning
   - `metalAnalysisContext.shared()` MainActor warning
   - `DispatchGroup.wait` unavailable from async contexts

## Startup Validation

1. Launch pickpick from Xcode.
2. Confirm the main window appears.
3. Confirm the title is `pickpick`.
4. Close the last window.
5. Confirm the App terminates normally.

## Analysis Validation

1. Select a folder containing JPG-only photos.
2. Confirm progress reaches completion and the group grid opens.
3. Select a folder containing RAW-only photos.
4. Confirm progress reaches completion and the group grid opens.
5. Select a folder containing RAW+JPG pairs.
6. Confirm progress reaches completion and duplicate/quality groups appear when applicable.
7. Select a folder containing one damaged or unsupported image.
8. Confirm the App does not crash.
9. Confirm the damaged or unsupported image is not shown as Normal.
10. Watch the Xcode console during analysis and confirm the previous `photoAnalysisService.analyze` Thread Performance Checker backtrace does not appear.

## Browser Validation

1. Open a non-duplicate group.
2. Use Up/Down keys to navigate photos.
3. Confirm the displayed image matches the selected thumbnail.
4. Confirm JPG segment is enabled only when a real JPG exists.
5. Confirm RAW segment is enabled only when a real RAW exists.
6. Zoom in, zoom out, and reset zoom.
7. Rotate left and right.
8. Leave and re-enter the group and confirm rotation persists.

## Duplicate Compare Validation

1. Open a duplicate group.
2. Confirm left and right images load.
3. Use Left Arrow to keep the left photo.
4. Reopen another duplicate group if available.
5. Use Right Arrow to keep the right photo.
6. Use Keep both.
7. Confirm JPG/RAW segment availability matches files on either side.
8. Confirm zoom and rotation actions affect both sides.

## State Mutation Validation

1. Delete a photo.
2. Confirm the file moves to macOS Trash.
3. Quit and relaunch the App.
4. Reopen the same folder.
5. Confirm the deleted photo is not visible.
6. Use Restore Normal on an abnormal photo.
7. Quit and relaunch the App.
8. Confirm the restored photo no longer appears in the abnormal group.
9. Perform rotation, delete, and Restore Normal actions quickly in sequence.
10. Quit and relaunch the App.
11. Confirm all states persisted correctly and no JSON decode error appears in Xcode console.
```

------

#### Step 2 — Verify based on the plan goal

No build is needed for this docs-only task. Manually open the checklist file and confirm it contains sections for:

- Build Validation
- Startup Validation
- Analysis Validation
- Browser Validation
- Duplicate Compare Validation
- State Mutation Validation

------

✅ **Done when:** The checklist exists at `docs/manualValidation/20260613_xcodeWarningsQualityFix.md` and includes all sections above. Do not start Task 8 until this condition is met.

---

## Task 8: Final full build and manual acceptance pass

**Goal:** The full project builds cleanly and the approved manual acceptance paths pass without adding tests or scripts.

**Files touched:**

- No source files should be modified in this task unless fixing a failure found during final validation.

------

#### Step 1 — Implement

- [ ] Run final clean build:

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build 2>&1 | tee /tmp/pickpick_final_quality_build.log
```

- [ ] Inspect target warning families:

```bash
rg -n "duplicate libraries|forced downcast|Immutable value 'index'|Main actor-isolated conformance|main actor-isolated static method|Instance method 'wait'|Thread Performance Checker" /tmp/pickpick_final_quality_build.log
```

Expected result: no matching output for build-time warnings. Runtime `Thread Performance Checker` must be checked in Xcode console while manually analyzing a folder.

- [ ] Complete the manual checklist in `docs/manualValidation/20260613_xcodeWarningsQualityFix.md`.

- [ ] If any failure appears, fix only the smallest code path responsible for the failure, rerun the final build command, and repeat the relevant manual checklist section.

------

#### Step 2 — Verify based on the plan goal

Expected final build result:

```text
** BUILD SUCCEEDED **
```

Expected manual validation result:

```text
All manual checklist sections completed without blocking failure.
```

No test target, test framework, or validation script should exist after this task.

------

✅ **Done when:** Final clean build succeeds, target warning families are absent, and every manual checklist section has been completed successfully.

---

## Self-Review

### Spec coverage

- Build warning cleanup: Task 1 and Task 2.
- Swift 6 actor/concurrency warnings: Task 1, Task 2, Task 3.
- Thread Performance Checker root cause: Task 3.
- Analysis failure semantics: Task 3 and Task 4.
- JSON state consistency: Task 5.
- Image loading cancellation behavior: Task 6.
- RAW-only/JPG-only display semantics: Task 4.
- No test frameworks and no scripts: enforced in every verification section and Task 7.
- Manual acceptance: Task 7 and Task 8.

### Placeholder scan

The plan contains no deferred implementation markers. Every code edit is represented as an exact replacement, exact insertion, or complete file content for new docs.

### Type consistency

The plan consistently uses existing project type names:

- `photoAnalysisService`
- `analysisProgress`
- `analysisPhase`
- `photoFilePair`
- `photoItem`
- `rawAnalysisResult`
- `analysisConfig`
- `displaySource`
- `displayAvailability`

### Verification completeness

Because test frameworks and scripts are forbidden by the approved recipe, each task uses clean build plus focused manual validation. Task 8 performs the final full acceptance pass.
