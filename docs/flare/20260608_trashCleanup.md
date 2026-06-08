# Trash 扫描修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 1) 修复 photoBrowserViewController convenience init 中 trashService 未注入的问题；2) 在加载文件夹后扫描 JSON 中 `.trashed` 但文件仍在磁盘上的照片，将其补移入废纸篓。

**Architecture:** 在 `photoTrashService` 中新增 `cleanupTrashedPhotos` 方法，批量处理残留文件；`appCoordinator` 在 `startAnalysis` 加载 records 后调用清理；同时修复 `photoBrowserViewController` 的 convenience init 接受外部注入的 trashService。

**Tech Stack:** Swift, AppKit (FileManager.trashItem)

---

### 文件结构

| 文件 | 职责 |
|------|------|
| `rawViewer/photoTrashService.swift` | 修改：新增 `cleanupTrashedPhotos(_ photos: [photoItem])` 方法 |
| `rawViewer/photoBrowserViewController.swift` | 修改：convenience init 添加 trashService 参数 |
| `rawViewer/appCoordinator.swift` | 修改：`startAnalysis` 加载 records 后调用 trashService 清理残留文件 |

---

### Task 1: photoTrashService 新增 cleanupTrashedPhotos

**Goal:** `photoTrashService` 能批量扫描一组 `photoItem`，对其中 `reviewStatus == .trashed` 但文件仍存在于磁盘上的照片执行移入废纸篓操作；静默跳过文件已不存在或非 trashed 状态的照片。

**Files touched:**

- `rawViewer/photoTrashService.swift` — 协议新增方法签名 + 实现类新增方法

------

#### Step 1 — Implement

在 `photoTrashServicing` 协议和 `photoTrashService` 实现中新增 `cleanupTrashedPhotos` 方法：

```swift
// rawViewer/photoTrashService.swift — 完整文件

/*
Author: wilbur
Version: 1.1
Date: 2026-06-08
Description: 照片废纸篓服务：将 photoItem 的 JPG/RAW 文件移入 macOS 废纸篓；支持批量清理残留的 trashed 文件
*/

import Foundation

public enum photoTrashError: Error {
    case trashFailed(path: String, underlying: Error)
}

public protocol photoTrashServicing {
    /// 将照片的 JPG 与 RAW（如有）移到系统废纸篓。
    /// 文件已不存在 → 静默返回。
    /// 任一文件移入废纸篓失败 → 抛 photoTrashError，已移入的不回滚。
    func trash(_ photo: photoItem) throws

    /// 批量扫描照片列表，对 reviewStatus == .trashed 且文件仍存在于磁盘的照片移入废纸篓。
    /// 静默跳过：非 trashed 状态的照片、文件已不存在的照片、移入失败的照片（仅打印警告）。
    func cleanupTrashedPhotos(_ photos: [photoItem])
}

public final class photoTrashService: photoTrashServicing {
    public init() {}

    public func trash(_ photo: photoItem) throws {
        let paths = [photo.jpgPath, photo.rawPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let fm = FileManager.default
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                var resultUrl: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
            } catch {
                throw photoTrashError.trashFailed(path: path, underlying: error)
            }
        }
    }

    public func cleanupTrashedPhotos(_ photos: [photoItem]) {
        let fm = FileManager.default
        let trashedPhotos = photos.filter { $0.reviewStatus == .trashed }

        for photo in trashedPhotos {
            let paths = [photo.jpgPath, photo.rawPath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }

            for path in paths {
                guard fm.fileExists(atPath: path) else { continue }
                do {
                    var resultUrl: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultUrl)
                } catch {
                    print("⚠️ cleanupTrashedPhotos: failed to trash \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}
```

------

#### Step 2 — Compile

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
# Expected output:
# ** BUILD SUCCEEDED **
```

✅ **Done when:** BUILD SUCCEEDED，无任何编译错误。

---

### Task 2: 修复 photoBrowserViewController convenience init

**Goal:** `photoBrowserViewController` 的 `convenience init(group:store:imageService:)` 接受外部传入的 `trashService`，不再自行创建新实例。

**Files touched:**

- `rawViewer/photoBrowserViewController.swift` — convenience init 添加 trashService 参数

------

#### Step 1 — Implement

修改 convenience init 签名，添加 `trashService` 参数：

```swift
// photoBrowserViewController.swift — 仅修改 convenience init 这一处

public convenience init(group: photoGroup, store: jsonReviewStateStoring, trashService: photoTrashServicing = photoTrashService(), imageService: photoImageService = photoImageService()) {
    let initialSource = displaySourceStore().current
    let viewModel = photoBrowserViewModel(photos: group.photos, store: store, trashService: trashService, displaySource: initialSource)
    self.init(viewModel: viewModel, imageService: imageService)
    self.groupTitle = group.kind.title
}
```

变更点：
- 添加 `trashService: photoTrashServicing = photoTrashService()` 参数
- `photoBrowserViewModel(...)` 中 `trashService: photoTrashService()` → `trashService: trashService`

------

#### Step 2 — Compile

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
# Expected output:
# ** BUILD SUCCEEDED **
```

✅ **Done when:** BUILD SUCCEEDED，无任何编译错误。

---

### Task 3: appCoordinator 加载后清理残留 trashed 文件

**Goal:** `appCoordinator.startAnalysis` 在成功加载 records 后，调用 `trashService.cleanupTrashedPhotos(records)` 将 JSON 中已标记 `.trashed` 但文件仍在磁盘上的照片移入废纸篓。

**Files touched:**

- `rawViewer/appCoordinator.swift` — startAnalysis 中加载 records 后调用清理

------

#### Step 1 — Implement

在 `startAnalysis` 方法中，两个加载 records 的位置（缓存加载路径 & 分析完成后加载路径）之后添加清理调用：

```swift
// appCoordinator.swift — startAnalysis 方法中的修改

public func startAnalysis(folderUrl: URL) {
    currentFolderUrl = folderUrl
    screenState = .progress

    let progressController = progressViewController()
    window?.contentViewController = progressController

    Task { @MainActor in
        do {
            if FileManager.default.fileExists(atPath: folderUrl.appendingPathComponent(".cache/analysis.json").path) {
                let loadedRecords = try analyzer.loadAnalysisResult(folderUrl: folderUrl)
                self.records = loadedRecords
                self.trashService.cleanupTrashedPhotos(self.records)  // ← 新增
                self.showGroups()
                return
            }
            _ = try await analyzer.startAnalysis(folderUrl: folderUrl, configUrl: folderUrl.appendingPathComponent("config.yaml")) { progress in
                progressController.update(progress: progress)
            }
            self.records = try analyzer.loadAnalysisResult(folderUrl: folderUrl)
            self.trashService.cleanupTrashedPhotos(self.records)  // ← 新增
            self.showGroups()
        } catch {
            self.screenState = .error(error.localizedDescription)
            self.showError(message: error.localizedDescription)
        }
    }
}
```

更新文件头 Version 1.1 → 1.2，更新 Description。

------

#### Step 2 — Compile

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' build
# Expected output:
# ** BUILD SUCCEEDED **
```

✅ **Done when:** BUILD SUCCEEDED，无任何编译错误。

---

## Self-Review

**1. Spec coverage:**
- [x] 修复 photoBrowserViewController convenience init 的 trashService 注入问题 → Task 2
- [x] 打开文件夹后扫描 JSON 中 `.trashed` 但文件仍在磁盘上的照片 → Task 1 + Task 3
- [x] 清理操作静默跳过失败项，不阻塞正常流程 → Task 1 cleanupTrashedPhotos 实现

**2. Placeholder scan:**
- [x] 无 TBD / TODO / "... rest of function"
- [x] 所有代码块完整可运行

**3. Type consistency:**
- [x] `photoTrashServicing` 协议新增方法与实现类一致
- [x] `appCoordinator` 持有的 `trashService: photoTrashServicing` 类型可调用新方法
- [x] `photoBrowserViewController` convenience init 的 `trashService` 参数有默认值，不影响现有调用方

**4. 边界情况考虑:**
- [x] 首次分析（无缓存）也执行清理 — 虽然新分析结果不会有 trashed 记录，但调用无副作用（空列表直接返回）
- [x] `cleanupTrashedPhotos` 不会抛出错误 — 单个文件失败仅 print 警告，不中断批量处理
- [x] 文件已不存在时静默跳过 — `FileManager.fileExists` 检查

---

## Execution Handoff

Plan complete and saved to `docs/flare/20260608_trashCleanup.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
