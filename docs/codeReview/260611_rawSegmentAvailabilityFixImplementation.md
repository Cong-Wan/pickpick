# 代码审核报告 — JPG/RAW 按钮可用性修复实现

### 总览
- **审核文件：** 5 个
  - `rawViewer/services/appFileLogger.swift`
  - `rawViewer/models/photoModels.swift`
  - `rawViewer/services/photoDisplayService.swift`
  - `rawViewer/browser/photoBrowserViewController.swift`
  - `rawViewer/duplicate/duplicateCompareViewController.swift`
- **执行计划：** `docs/flare/20260611_rawSegmentAvailabilityFix.md`
- **追加修正：** 用户指出只有 RAW 没有 JPG 时，JPG 也应置灰；本轮已补齐 JPG/RAW 对称可用性判断。
- **验证结果：** `xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build` 已通过
- **发现问题：** 🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 1 个
- **整体评价：** 当前实现已从“只禁用 RAW”扩展为“JPG/RAW 双向按真实文件存在性禁用”。普通浏览器和重复对比页都会分别控制 JPG 与 RAW segment。显示服务也补充了文件类型校验，避免 RAW-only 照片因 `jpgPath` 指向 RAW 文件而被当作 JPG 加载。

---

### 已修复链路

#### 1. 数据模型可用性判断

**位置：** `rawViewer/models/photoModels.swift`

新增：

```swift
photoItem.hasExistingJpgFile(fileManager:)
photoItem.hasExistingRawFile(fileManager:)
```

语义：

- JPG 必须是 `jpg/jpeg` 扩展名且文件存在。
- RAW 必须是 `rw2/cr2` 扩展名且文件存在。

这样避免 RAW-only 场景下 `jpgPath = rawPath` 时误判 JPG 可用。

#### 2. 显示服务防路径混淆

**位置：** `rawViewer/services/photoDisplayService.swift`

`loadDisplayJpg(for:)` 和 `loadDisplayRaw(for:)` 在读缓存/解码前先走模型可用性判断：

- JPG 不存在或不是 JPG 扩展名：返回 `.unavailable("JPG missing")`
- RAW 不存在或不是 RAW 扩展名：返回 `.unavailable("RAW missing")`

这保证了 UI 禁用逻辑和加载服务语义一致。

#### 3. 普通浏览器 segment 对称控制

**位置：** `rawViewer/browser/photoBrowserViewController.swift`

当前照片：

- 有 JPG：JPG segment 可点；否则置灰。
- 有 RAW：RAW segment 可点；否则置灰。
- 当前 source 不可用但另一种 source 可用时，自动切到可用 source。
- 两种 source 都不可用时，两个 segment 都置灰。

#### 4. 重复对比页 segment 对称控制

**位置：** `rawViewer/duplicate/duplicateCompareViewController.swift`

左右任意一侧：

- 有 JPG：JPG segment 可点；否则置灰。
- 有 RAW：RAW segment 可点；否则置灰。
- 当前 source 不可用但另一种 source 可用时，自动切到可用 source。
- 两种 source 都不可用时，两个 segment 都置灰。

---

### 问题清单

#### 🔵 [Low] 日志实际目录在 sandbox 环境下可能不是用户肉眼看到的全局 Application Support

**位置**: `rawViewer/services/appFileLogger.swift:46-55`

**问题**: `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)` 在启用 App Sandbox 的 macOS App 中通常会解析到 App container 内的 Application Support，而不是非沙盒 App 的 `~/Library/Application Support/rawViewer/logs/`。当前实现与项目既有 `analysisStore` 使用方式一致，功能上没有问题；但如果用户按全局路径查找日志，可能找不到。

**修复方案**: 当前不需要修改代码。建议后续用户文档写成“Application Support/rawViewer/logs，沙盒环境下位于 App container 内”。如果未来需要让用户更容易打开日志目录，可以新增菜单项或 Debug 输出实际路径。

---

### 优点记录

- `appFileLogger` 使用串行队列异步写入，避免 UI 线程阻塞和并发 append 交错。
- `photoItem.hasExistingJpgFile` / `hasExistingRawFile` 将文件可用性判断集中，避免 UI 和服务层各自猜测。
- `photoDisplayService` 在缓存前先检查真实文件类型，避免 RAW-only 时 `jpgPath` 指向 RAW 文件造成 JPG 误加载。
- 普通浏览器在读取异步 `requestId` 前先修正 source，避免因 `setDisplaySource` 自增 requestId 导致当前请求被误判陈旧。
- 重复对比页保留“左右任意一侧有对应格式就允许切换”的产品规则，缺失的一侧继续 fallback 并写日志。

---

### 手工验收建议

1. **JPG-only**：JPG 可点，RAW 灰色。
2. **RAW-only**：RAW 可点，JPG 灰色。
3. **JPG + RAW**：JPG 和 RAW 都可点。
4. **记录中有 JPG 路径但 JPG 文件被删**：JPG 灰色；若 RAW 存在则自动切 RAW。
5. **记录中有 RAW 路径但 RAW 文件被删**：RAW 灰色；若 JPG 存在则自动切 JPG。
6. **重复对比页左 RAW-only / 右 JPG-only**：JPG 与 RAW 都可点；切 JPG 时左侧 fallback，切 RAW 时右侧 fallback，并写日志。
