# 代码审核报告 — codeReviewFixes 实现

## 总览

- 审核文件：18 个
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 0 个（复审中发现 1 个 High 问题，已当场修复）
- 整体评价：本轮实现覆盖了计划中的状态一致性、缓存 key、RAW/JPG 安全边界、Bayer pattern、UI 复用与脆弱点修复。最终 Debug 构建通过。

---

## 审核范围

- `rawViewer/duplicate/duplicateCompareViewModel.swift`
- `rawViewer/browser/photoBrowserViewController.swift`
- `rawViewer/models/jsonReviewStateStore.swift`
- `rawViewer/services/analysisStore.swift`
- `rawViewer/appCoordinator.swift`
- `rawViewer/services/photoDisplayService.swift`
- `rawViewer/services/photoThumbnailService.swift`
- `rawViewer/services/rawBayerAnalyzer.swift`
- `rawViewer/services/jpgAnalyzer.swift`
- `rawViewer/bridge/libRawBridge.h`
- `rawViewer/bridge/libRawBridge.mm`
- `rawViewer/metal/rawAnalysisShaders.metal`
- `rawViewer/views/photoThumbnailCellView.swift`
- `rawViewer/views/groupCardView.swift`
- `rawViewer/views/groupCollectionViewItem.swift`
- `rawViewer/duplicate/duplicateCompareViewController.swift`
- `rawViewer/groupGrid/groupGridViewController.swift`
- `rawViewer/mainWindowController.swift`

---

## 问题清单

### 已修复 — 🟠 High：损坏缓存会导致重分析后的保存再次失败

**位置**：`rawViewer/services/analysisStore.swift` / `saveUnlocked(folderUrl:records:config:)`

**问题**：`startAnalysis` 已经能在缓存解码失败时进入重分析，但 `analysisStore.saveUnlocked` 原本会在保存前再次读取并解码旧 `analysis.json`。如果旧缓存文件损坏，重分析成功后保存阶段仍会因为旧文件解码失败而失败，用户路径仍无法恢复。

**已执行修复**：保存新分析结果时，旧文件只有在可读且可解码时才用于继承历史 root 字段；损坏文件直接以新的 `analysisFile()` 覆盖。

```swift
if fileManager.fileExists(atPath: url.path),
   let data = try? Data(contentsOf: url),
   let decoded = try? JSONDecoder().decode(analysisFile.self, from: data) {
    existing = decoded
}
```

修复后已重新运行 Debug 构建并通过。

---

## 优点记录

- `keepBoth` 改为先构造 `nextPhotos`，落盘成功后再替换内存，修复状态分裂路径。
- display/thumbnail 缓存 key 纳入真实路径、文件大小、mtime，能避免跨文件夹同名照片串图。
- RAW/JPG/display 加入尺寸与内存预算检查，降低极端图片触发 trap / OOM 的风险。
- LibRaw bridge 返回可见区域 Bayer pattern，并把 open/unpack 错误向 Swift 暴露，可诊断性明显提升。
- 缩略图 cell 与 group card 都加入复用校验/取消任务，解决异步旧图写入新视图的典型问题。

---

## 验证记录

最终验证命令：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO build
```

结果：`BUILD SUCCEEDED`。

---

## 修复优先级建议

当前审核范围内没有剩余 Critical/High 问题。建议后续若继续增强，可优先补充真实样本手动回归：

1. 损坏 `analysis.json` 后重新打开同一文件夹，确认会重分析并覆盖旧缓存。
2. 非 RGGB RAW 样本验证 Bayer pattern 通道与 green plane 结果。
3. 快速滚动分组页/缩略图列表，确认无复用串图。
