# RAW-heavy 缩略图显示修复实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复 RAW-heavy / RAW-only 分组页缩略图不显示，以及进入这些分组后图片显示被 RAW 缩略图后台解码拖慢的问题。

**架构：** 只修改缩略图服务内部实现：先按真实文件类型选择 JPG 或 RAW 缩略图源，再对 RAW 缩略图解码做串行限流，并让 RAW 优先使用内嵌预览。UI、分析结果 schema、大图显示服务保持不变。

**技术栈：** Swift、AppKit `NSImage`、ImageIO `CGImageSourceCreateThumbnailAtIndex`、Grand Central Dispatch、Xcode `xcodebuild`。

---

## 文件结构

本计划只修改一个文件：

- `rawViewer/services/photoThumbnailService.swift` — 缩略图加载服务。负责根据 `photoItem` 选择缩略图源、降采样解码 JPG/RAW 缩略图、缓存成功结果，并对 RAW 缩略图解码做串行限流。

本计划不修改以下文件：

- `rawViewer/services/photoAnalysisService.swift` — 不迁移或重写 `analysis.json` 中 RAW-only 的 `jpgPath` 兼容写法。
- `rawViewer/services/photoDisplayService.swift` — 大图 JPG/RAW 显示链路保持不变。
- `rawViewer/views/groupCardView.swift`、`rawViewer/views/photoThumbnailCellView.swift` — UI 调用缩略图 API 的方式保持不变。
- `rawViewer/services/appDebugLogger.swift` — 已有 `--debug` 解析基础设施保持不变。本次不新增详细日志，只移除 `photoThumbnailService` 中会触发 MainActor warning 的临时诊断日志。

---

### Task 1: 修复缩略图源选择、RAW 内嵌预览优先与 RAW 限流

**目标：** RAW-heavy 分组页不再因为大量 RAW 缩略图并发解码而长期空白；JPG 缩略图继续快速显示；构建不再出现 `photoThumbnailService.swift` 的 MainActor debug log warning。

**涉及的文件：**

- `rawViewer/services/photoThumbnailService.swift` — 缩略图加载服务，集中实现源选择、RAW 解码限流、ImageIO options 分支和缓存。

------

#### Step 1 — 实现

用下面完整内容替换 `rawViewer/services/photoThumbnailService.swift`。

```swift
/*
Author: wilbur
Version: 1.3
Date: 2026-06-17
Description: 基于 CGImageSource 的降采样缩略图加载服务；v1.3 按真实 JPG/RAW 文件选择缩略图源，RAW 使用内嵌预览优先并串行限流，避免 RAW-heavy 分组页缩略图解码阻塞显示
*/

import AppKit
import ImageIO

nonisolated public final class photoThumbnailService: @unchecked Sendable {
    private enum thumbnailSource: Sendable {
        case jpg(path: String)
        case raw(path: String)

        var path: String {
            switch self {
            case .jpg(let path), .raw(let path):
                return path
            }
        }

        var isRaw: Bool {
            if case .raw = self { return true }
            return false
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let fileManager: FileManager
    private let rawDecodeQueue = DispatchQueue(label: "rawViewer.thumbnail.rawDecode")

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        cache.countLimit = 200
    }

    public func loadThumbnail(for photo: photoItem, maxWidth: Int, maxHeight: Int) async -> NSImage? {
        let cacheKey = "\(photo.photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = thumbnailSource(for: photo) else {
            return nil
        }

        let photoId = photo.photoId
        let maxPixelSize = max(maxWidth, maxHeight)
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }

            let image = self.decodeThumbnail(source: source, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return nil }

            if let image {
                let key = "\(photoId)|thumb|\(maxWidth)x\(maxHeight)" as NSString
                self.cache.setObject(image, forKey: key)
            }
            return image
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func thumbnailSource(for photo: photoItem) -> thumbnailSource? {
        if photo.hasExistingJpgFile(fileManager: fileManager) {
            return .jpg(path: photo.jpgPath)
        }

        guard photo.hasExistingRawFile(fileManager: fileManager),
              let rawPath = photo.rawPath,
              !rawPath.isEmpty else {
            return nil
        }
        return .raw(path: rawPath)
    }

    private func decodeThumbnail(source: thumbnailSource, maxPixelSize: Int) -> NSImage? {
        if source.isRaw {
            return rawDecodeQueue.sync {
                guard !Task.isCancelled else { return nil }
                return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
            }
        }

        return decodeImageSourceThumbnail(path: source.path, source: source, maxPixelSize: maxPixelSize)
    }

    private func decodeImageSourceThumbnail(path: String, source: thumbnailSource, maxPixelSize: Int) -> NSImage? {
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return nil
        }
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }

        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        if source.isRaw {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
```

实现说明：

- `thumbnailSource(for:)` 必须优先检查真实 JPG，再检查真实 RAW。
- RAW-only 记录即使 `jpgPath` 指向 `.RW2`，也必须通过 `.raw(path:)` 分支处理。
- RAW 分支必须经过 `rawDecodeQueue.sync`，保证同一时间只有一个 RAW 缩略图解码。
- JPG 分支不经过 `rawDecodeQueue`，保持现有并行速度。
- RAW 使用 `kCGImageSourceCreateThumbnailFromImageIfAbsent`，JPG 使用 `kCGImageSourceCreateThumbnailFromImageAlways`。
- 不在此文件中调用 `appDebugLogger.log`，避免默认 MainActor 隔离下的构建 warning。

------

#### Step 2 — 运行验证

先运行构建验证。此命令会保存构建日志，并检查构建成功以及 `photoThumbnailService.swift` 没有 warning。

```bash
set -o pipefail
xcodebuild \
  -project rawViewer.xcodeproj \
  -scheme pickpick \
  -configuration Debug \
  -derivedDataPath build/derived \
  build 2>&1 | tee /tmp/rawThumbnailDisplayFix_build.log

grep -q "BUILD SUCCEEDED" /tmp/rawThumbnailDisplayFix_build.log
if grep -q "photoThumbnailService.swift:.*warning" /tmp/rawThumbnailDisplayFix_build.log; then
  echo "Unexpected photoThumbnailService warning"
  exit 1
fi
```

预期：

- 命令退出码为 0；
- `/tmp/rawThumbnailDisplayFix_build.log` 中包含 `BUILD SUCCEEDED`；
- 命令不会打印 `Unexpected photoThumbnailService warning`；
- 构建过程无 crash、无编译错误。

再运行 app 启动烟雾验证。此命令使用已有 `--debug` 参数，只检查关键节点输出，不要求详细缩略图日志。

```bash
APP="build/derived/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick"
"$APP" --folder=/Users/wilbur/Downloads/test_bak2 --debug > /tmp/rawThumbnailDisplayFix_app.log 2>&1 &
PID=$!
sleep 12
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

grep -q "display groups numberOfItems count=" /tmp/rawThumbnailDisplayFix_app.log
if grep -q "thumbnail decodeThumbnail" /tmp/rawThumbnailDisplayFix_app.log; then
  echo "Unexpected verbose thumbnail debug log"
  exit 1
fi
```

预期：

- 命令退出码为 0；
- app 能启动到分组页，日志中包含 `display groups numberOfItems count=`；
- app 启动期间无 crash；
- 不再输出 `thumbnail decodeThumbnail` 这类详细缩略图诊断日志。

最后进行人工界面验收：

1. 启动 Debug app，选择 `/Users/wilbur/Downloads/test_bak2`。
2. 等待分组页出现。
3. 观察 JPG-heavy 分组缩略图应快速出现。
4. 观察 RAW-heavy 分组缩略图不应长期全为空白，应逐步出现。
5. 进入一个 RAW-only 或 RAW-heavy 普通分组，主图应能显示，界面不应明显卡死。
6. 返回分组页，再进入其他分组，app 不应 crash。

如果任一验证失败，必须修复 `rawViewer/services/photoThumbnailService.swift` 后重新运行本 Step 2 的全部验证命令。不得跳过构建检查，不得弱化 warning 检查，不得进入完成状态。

------

✅ **完成的标志：** 第二步所有验证通过：构建通过、`photoThumbnailService.swift` 无 warning、app 可启动到分组页、关键输出符合预期，并且人工界面验收确认 RAW-heavy 缩略图逐步显示、进入分组后主图能显示。

------

## 自我复审

### 1. 规范覆盖

- 源选择：Task 1 的 `thumbnailSource(for:)` 覆盖。
- JPG 优先：Task 1 的 `thumbnailSource(for:)` 第一分支覆盖。
- RAW-only fallback：Task 1 的 `thumbnailSource(for:)` RAW 分支覆盖。
- RAW 内嵌预览优先：Task 1 的 `decodeImageSourceThumbnail` 中 `kCGImageSourceCreateThumbnailFromImageIfAbsent` 覆盖。
- RAW 限流：Task 1 的 `rawDecodeQueue` 和 `decodeThumbnail` 覆盖。
- 不修改 schema / UI / 大图链路：文件结构和 Task 1 范围已限定。
- 消除 MainActor warning：Task 1 删除 `photoThumbnailService.swift` 内 `appDebugLogger.log` 调用，并在验证命令中检查 warning。

### 2. 占位符扫描

计划已完成占位符扫描，未发现未完成标记、空实现说明或省略实现。代码块是完整文件内容。

### 3. 类型一致性

- `thumbnailSource`、`thumbnailSource(for:)`、`decodeThumbnail(source:maxPixelSize:)`、`decodeImageSourceThumbnail(path:source:maxPixelSize:)` 在同一任务中定义并使用。
- `photo.hasExistingJpgFile(fileManager:)` 和 `photo.hasExistingRawFile(fileManager:)` 与 `photoModels.swift` 现有方法签名一致。
- `rawDecodeQueue` 是 `DispatchQueue`，已通过 `Foundation` 间接可用；当前项目 Swift 文件已能通过 AppKit 使用 Foundation 类型。

### 4. 验证完整性

- 构建验证有精确 `xcodebuild` 命令。
- 运行验证有精确 app 启动命令。
- 关键输出检查包含 `display groups numberOfItems count=`。
- warning 检查明确针对 `photoThumbnailService.swift`。
- 完成条件明确，不允许跳过失败验证。
