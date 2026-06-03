# rawViewer 构建修复 + 崩溃修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking tracking.

**Goal:** 修复 Xcode 构建失败 + 修复 Swift 侧运行时崩溃隐患，让 App 能编译通过且基本流程不崩。

**Architecture:** 分三层修复：1) 项目配置（pbxproj + 架构）让链接通过；2) Swift 崩溃修复（数组越界 + 线程安全 + ISO8601DateFormatter）；3) 死代码清理。每层独立可验证。

**Tech Stack:** Swift 5, AppKit, Xcode pbxproj, C++ (ObjC++ 桥接)

---

### Task 1: 修复 Xcode 项目链接错误

**Goal:** `xcodebuild ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` 编译 rawViewer target 成功，无 undefined symbol 错误。

**Files touched:**

- `rawViewer.xcodeproj/project.pbxproj` — 添加 jpgWriter.mm 和 photoMetadataReader.mm 的 PBXFileReference + PBXBuildFile，加入 rawViewer target 的 Sources build phase

------

#### Step 1 — 编辑 pbxproj 添加两个缺失的 C++ 源文件

在 `project.pbxproj` 中添加 `cpp/src/jpgWriter.mm` 和 `cpp/src/photoMetadataReader.mm`：

1. 在 `PBXFileReference` section 中添加两个条目（使用与现有手动添加文件一致的 ID 格式 `A100000000000000000000XX`）：
   - `A10000000000000000000060` → `cpp/src/jpgWriter.mm` (lastKnownFileType = sourcecode.cpp.objcpp; path = cpp/src/jpgWriter.mm; sourceTree = "<group>")
   - `A10000000000000000000061` → `cpp/src/photoMetadataReader.mm` (lastKnownFileType = sourcecode.cpp.objcpp; path = cpp/src/photoMetadataReader.mm; sourceTree = "<group>")

2. 在 `PBXBuildFile` section 中添加两个条目：
   - `A10000000000000000000062` → `cpp/src/jpgWriter.mm in Sources` (fileRef = A10000000000000000000060)
   - `A10000000000000000000063` → `cpp/src/photoMetadataReader.mm in Sources` (fileRef = A10000000000000000000061)

3. 在 cpp group (`4AE33933EEF34E19AF7037C3`) 的 children 列表中追加这两个 fileRef ID

4. 在 rawViewer target 的 `PBXSourcesBuildPhase` (`D8DB71302FC92FEA00F93F82` 下属的 Sources phase) 的 files 列表中追加这两个 buildFile ID

------

#### Step 2 — 验证构建成功

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
```

如果仍有 undefined symbol，检查是否还有其他 `.mm/.cpp` 文件遗漏，补充后重新构建。

------

✅ **Done when:** `xcodebuild` 输出 `BUILD SUCCEEDED`，无链接错误。

------

### Task 2: 统一所有 target 的 ARCHS = arm64

**Goal:** 默认 `xcodebuild build`（不手动传 ARCHS）也能成功，不出现 x86_64 回退。

**Files touched:**

- `rawViewer.xcodeproj/project.pbxproj` — 给 rawViewerTests target 的 Debug 和 Release 配置添加 `ARCHS = arm64`

------

#### Step 1 — 在 rawViewerTests 的两个 build configuration 中添加 ARCHS = arm64

在 pbxproj 中找到 rawViewerTests target 的 Debug 和 Release xcconfig 条目（ID `5D22961DA10749A287C56954` 和 `C1D9EB9CA8FA4D76A4792636` 相关的配置），在 buildSettings 中添加：

```
ARCHS = arm64;
```

------

#### Step 2 — 验证默认构建成功

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
# 不应出现 "ONLY_ACTIVE_ARCH=YES requested with multiple ARCHS" 警告
```

------

✅ **Done when:** 不传 `ARCHS=arm64` 参数也能构建成功，无架构回退警告。

------

### Task 3: 修复 duplicateCompareState 数组越界

**Goal:** `keepLeft()` 和 `keepRight()` 在删除到只剩 1 张或 0 张照片时，`candidateIndex` 不超出 `photos.indices` 范围，不会崩溃。

**Files touched:**

- `rawViewer/duplicateCompareViewController.swift` — 修复 keepLeft 和 keepRight 的 candidateIndex 计算

------

#### Step 1 — 修改 candidateIndex 赋值

在 `duplicateCompareViewController.swift` 中做两处修改：

**keepLeft() 第 34 行附近：**
```swift
// Before:
candidateIndex = min(1, photos.count)
// After:
candidateIndex = min(1, max(0, photos.count - 1))
```

**keepRight() 第 48 行附近：**
```swift
// Before:
candidateIndex = min(newMainIndex + 1, photos.count)
// After:
candidateIndex = min(newMainIndex + 1, max(0, photos.count - 1))
```

------

#### Step 2 — 验证编译通过

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
```

------

✅ **Done when:** Swift 编译通过，且逻辑上 `candidateIndex` 永远 ≤ `photos.count - 1`。

------

### Task 4: 移除 photoThumbnailCache

**Goal:** 删除 `photoThumbnailCache.swift`，因为所有图片显示均通过 GPU 解码（`metalPhotoView`），预览区域只需缩小显示同一张图，不需要单独的缩略图缓存。

**Files touched:**

- `rawViewer/photoThumbnailCache.swift` — 删除

------

#### Step 1 — 删除文件

```bash
rm rawViewer/photoThumbnailCache.swift
```

由于 rawViewer 目录使用 `PBXFileSystemSynchronizedRootGroup`，Xcode 会自动检测文件移除，无需手动编辑 pbxproj。

------

#### Step 2 — 验证编译通过

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 编译通过，磁盘上不再存在 photoThumbnailCache.swift。

------

### Task 5: 修复 isoNow() 重复创建 ISO8601DateFormatter

**Goal:** `isoNow()` 使用缓存的 formatter 实例而非每次新建。

**Files touched:**

- `rawViewer/jsonReviewStateStore.swift` — 将 ISO8601DateFormatter 改为类级别缓存实例

------

#### Step 1 — 修改 isoNow 实现

在 `jsonReviewStateStore.swift` 中替换：

```swift
// Before:
private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

// After:
private let isoFormatter = ISO8601DateFormatter()

private func isoNow() -> String {
    isoFormatter.string(from: Date())
}
```

------

#### Step 2 — 验证编译通过

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 编译通过，`isoNow()` 不再每次创建新的 formatter。

------

### Task 6: 清理死代码

**Goal:** 删除未被任何代码引用的 Swift 文件，减少维护噪音。

**Files touched:**

- `rawViewer/ContentView.swift` — 删除（Xcode 模板残留，未被引用）
- `rawViewer/rawViewerApp.swift` — 删除（`rawViewerAppEntry` 未被读取，`@main` 在 appDelegate.swift 中）

------

#### Step 1 — 删除两个文件

```bash
rm rawViewer/ContentView.swift
rm rawViewer/rawViewerApp.swift
```

由于 rawViewer 目录使用 `PBXFileSystemSynchronizedRootGroup`，Xcode 会自动检测文件移除，无需手动编辑 pbxproj。

------

#### Step 2 — 验证构建通过

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -target rawViewer -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -5
# Expected output: ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 构建通过，磁盘上不再存在 ContentView.swift 和 rawViewerApp.swift。

------