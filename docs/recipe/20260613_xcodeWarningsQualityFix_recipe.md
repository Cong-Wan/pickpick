# Recipe — Xcode 警告与工程质量修复方案

## 背景

本方案基于全项目范围制定，目标不是简单压制 warning，而是解决 Xcode 警告背后的并发模型、actor 隔离、分析失败语义、存储写入一致性等工程质量问题。

已参考：

- `docs/codeReview/260613_xcodeWarningsFullReview.md`
- 近期提交记录
- 全项目 Swift / ObjC++ / Metal / Xcode 配置文件列表

当前约束：

- 不使用 XCTest / Quick / Nimble / 任何测试框架
- 不新增验证脚本
- 验证只允许：`xcodebuild clean build`、Xcode warning 检查、手动 App 验收
- 不做无关 UI 重构
- 不改变现有 App 主要交互流程

---

## 目标

### 必须达成

1. 清理当前 Xcode 主要 warning。
2. 修复 Swift 6 迁移会变成错误的并发/actor 问题。
3. 消除 `photoAnalysisService.analyze` 中 async 上下文的阻塞等待。
4. 降低 Thread Performance Checker 优先级反转问题。
5. 明确 UI 层与服务层 actor 边界。
6. 修正分析失败被当作 normal 的语义风险。
7. 提升 JSON 状态写入一致性。
8. 通过手动验收覆盖核心流程。

### 不做

1. 不新增测试 target。
2. 不新增测试框架。
3. 不新增验证脚本。
4. 不重写 UI。
5. 不引入数据库。
6. 不做大版本 JSON schema 迁移。

---

## 总体方案

采用分阶段修复，避免一次性大重构。

### 阶段 1：清理构建 warning

目标：先处理低风险、高确定性的 warning。

包含：

- 移除重复 `-lc++`
- 修复 `CFDate as!` warning
- 去掉 unused `index`
- 修复 `main.swift` / `appDelegate` 的 MainActor 入口 warning
- 以最小改动明确服务层和 UI 层 actor 边界

验证：

- 执行 `xcodebuild clean build`
- Xcode 不再出现对应 warning

### 阶段 2：重整分析链路并发模型

目标：修复核心问题：async 函数中阻塞 `DispatchGroup.wait`，以及 Thread Performance Checker 优先级反转。

包含：

- `photoAnalysisService.analyze` 去掉 `DispatchGroup.wait`
- 去掉 `DispatchSemaphore.wait`
- 去掉无 QoS 的自建并发队列依赖
- 改成 async 结构化编排
- 保留现有分析流程：扫描 → EXIF → RAW/JPG 分析 → 重复分组 → 保存 → 汇总
- 保留现有进度阶段和百分比语义

验证：

- 手动选择大文件夹分析
- 进度页正常更新
- 分析完成后进入分组页
- 不再出现主要 Thread Performance Checker 堆栈

### 阶段 3：修正中期质量项

目标：处理审阅报告中影响正确性和维护性的质量问题。

包含：

- 分析失败语义明确化
- `analysisStore` / `jsonReviewStateStore` 写入串行化
- 图片加载取消策略收敛
- `displayUrl(.jpg)` 不再对 RAW-only 返回 RAW 路径

验证：

- 手动用 JPG-only / RAW-only / RAW+JPG / 损坏文件夹验收
- 删除、旋转、Restore Normal 后重新进入页面检查状态
- `analysis.json` 仍为合法 JSON

### 阶段 4：文档化人工验收清单

目标：在不引入测试框架和验证脚本的前提下，明确人工验收标准。

包含：

- 构建验收
- 启动验收
- 分析流程验收
- 浏览器验收
- 重复对比验收
- 删除 / Restore Normal / 旋转验收
- JPG / RAW segment 可用性验收

---

## Actor 边界设计

核心原则：UI 明确在 MainActor，分析 / 文件 / Metal 服务不依赖 MainActor。

### UI 层

以下类型属于 UI 层，应保持或显式标注 MainActor：

- `appDelegate`
- `mainWindowController`
- `appCoordinator`
- 所有 `NSViewController`
- 所有 `NSView` / `NSTableCellView` / `NSCollectionViewItem`
- 直接操作 `NSWindow`、`NSButton`、`NSSegmentedControl`、`NSTableView` 的代码

目的：所有 UI 更新仍只在主线程发生。

### 服务层

以下类型不应被 MainActor 绑定：

- `photoAnalysisService`
- `fileScanner`
- `exifReader`
- `duplicateGrouper`
- `rawBayerAnalyzer`
- `jpgAnalyzer`
- `metalAnalysisContext`
- `analysisStore`
- `configLoader`
- `photoTrashService`
- `photoDisplayService`
- `photoThumbnailService`

目的：文件扫描、EXIF、RAW/JPG 分析、Metal 初始化、图片解码都可在后台运行。

### 项目配置选择

本轮不关闭 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。

原因：

- 直接关闭 target 级默认 MainActor 影响面太大。
- AppKit 项目里 UI 默认 MainActor 对现有代码更安全。
- 当前 warning 主要集中在服务 / Metal 层，显式修复即可。

---

## 入口修复设计

`main.swift` 改为显式 MainActor 入口模型。

设计方向：

- 使用 `@main` 包装启动逻辑。
- `static func main()` 标记为 `@MainActor`。
- 保持现有启动顺序不变：
  1. 获取 `NSApplication.shared`
  2. 设置 `.regular`
  3. 创建 `appDelegate`
  4. 设置 delegate
  5. 调用 `app.run()`

验收：

- App 正常启动。
- 主窗口仍显示。
- 不再出现：
  - `Main actor-isolated conformance of 'appDelegate' to 'NSApplicationDelegate' cannot be used in nonisolated context`

---

## 构建配置修复设计

修改点：

- `rawViewer.xcodeproj/project.pbxproj`
  - Debug / Release 的 `OTHER_LDFLAGS` 移除 `"-lc++"`
  - 保留 `"-lraw"`、`"-lz"`、Metal / CoreImage / ImageIO / MetalKit 等 framework

不修改：

- deployment target
- 签名配置
- sandbox 配置
- bundle id

验收：

- `xcodebuild clean build`
- 不再出现：
  - `Ignoring duplicate libraries: '-lc++'`

---

## 分析链路并发设计

`photoAnalysisService.analyze` 对外接口保持不变：

```swift
func analyze(
    folderUrl: URL,
    progress: @escaping (analysisProgress) -> Void
) async throws -> analysisSummary
```

内部改为 async 结构化编排。

### 数据流

1. 加载配置。
2. 扫描文件夹，得到 `photoFilePair` 列表。
3. EXIF 阶段：并发读取拍摄时间，返回 `photoItem` 和可选 `duplicateGrouper.entry`。
4. 分析阶段：并发执行 RAW / JPG 分析，返回每张照片的分析结果。
5. 主流程按 `pairs` 顺序合并结果，生成最终 records。
6. 计算重复组。
7. 保存 JSON。
8. 计算 summary。

### 并发要求

- 不使用 `DispatchGroup.wait`。
- 不使用 `DispatchSemaphore.wait`。
- 不共享可变字典给多个线程写。
- 单个任务返回结果，主流程合并。
- 保留 `config.metalConcurrency` 对 RAW/JPG 分析并发数的限制。
- EXIF 阶段也要限制并发，避免一次性创建过多工作。

### 进度语义

保留现有进度区间：

- scanning：0%
- exifReading：10% → 20%
- rawAnalysis / jpgAnalysis：20% → 80%
- duplicateGrouping：85%
- organizing：90%
- completed：100%

进度触发点从 GCD closure 迁移到 async 收集结果的位置。

### 错误处理

- 配置加载失败：向外 throw。
- 文件夹扫描失败：向外 throw。
- 单张 RAW 分析失败：尝试 JPG fallback。
- 单张 JPG 分析失败：记录失败语义，不让整个分析崩溃。
- 保存失败：向外 throw。

验收：

- 不再出现：
  - `Instance method 'wait' is unavailable from asynchronous contexts`
  - 主要 Thread Performance Checker 优先级反转堆栈
- 分析完成后仍能进入分组页。
- 输出记录顺序仍按文件扫描后的 `pairs` 顺序。

---

## 服务 / Metal 隔离修复设计

目标：消除 `metalAnalysisContext.shared()` 的 MainActor warning。

设计：

- `metalAnalysisContext.shared()` 明确不依赖 UI actor。
- `jpgAnalyzer` / `rawBayerAnalyzer` 的默认 `contextProvider` 不直接触发 MainActor-isolated 方法引用。
- 服务层类型根据需要显式声明非 UI 隔离，保持后台可调用。

验收：

- 不再出现：
  - `Call to main actor-isolated static method 'shared()' in a synchronous nonisolated context`

---

## 小 warning 修复设计

### EXIF CFDate

修改点：

- `exifReader.swift`
- 将 `value as! CFDate` 拆成局部变量，或改为 `as? CFDate`。

验收：

- 不再出现：
  - `Treating a forced downcast to 'CFDate' as optional will never produce 'nil'`

### unused index

修改点：

- `photoAnalysisService.swift`
- 删除未使用 `index`。
- 如果并发重构后循环重写，则自然消除。

验收：

- 不再出现：
  - `Immutable value 'index' was never used`

---

## 分析失败语义设计

当前风险：分析失败可能被落成 normal，导致用户误判。

设计：

- 保持现有 `photoItem` 字段结构，避免 JSON 大版本迁移。
- 继续使用 `analysisSource` 表达分析来源和失败来源。
- 失败来源包括：
  - `jpg_failed`
  - `none`
- `makeVisiblePhotoGroups` / summary 逻辑中，失败记录不得进入 Normal 组。
- 本轮不新增 “Analysis Failed” UI 分组，避免扩大 UI 范围。

验收：

- 损坏 JPG / 无法解析 RAW 不进入 Normal 组。
- App 不崩溃。
- JSON 中能看出失败来源。

---

## 存储写入一致性设计

当前风险：`jsonReviewStateStore.update` 是 load → mutate → save，快速操作理论上可能覆盖更新。

设计：

- 不引入数据库。
- 不改变 JSON schema。
- 给 `analysisStore` 增加内部串行写入边界。
- 保持 `.atomic` 文件写入。
- 所有 review 状态修改仍通过现有 store 抽象完成。

验收：

- 快速连续执行旋转、删除、Restore Normal 后，重新进入 App 状态仍正确。
- `analysis.json` 是合法 JSON。

---

## 图片加载取消设计

当前风险：UI Task cancel 后，已投递到 GCD 的解码仍会继续跑。

设计：

- 不大改图片服务公开 API。
- 减少 GCD 混用。
- `photoDisplayService` / `photoThumbnailService` 内部收敛到可取消的 async 后台任务模型。
- UI 层保留现有 requestId / Task cancel 防错贴逻辑。

验收：

- 快速切换照片不会显示旧图。
- 快速滚动缩略图不会明显卡顿。
- 内存不持续增长。

---

## RAW-only / JPG-only 路径语义设计

当前风险：RAW-only 的 `photoItem.jpgPath` 可能保存 RAW 路径，导致 `displayUrl(.jpg)` 返回 RAW URL。

设计：

- 不立即迁移 JSON schema。
- `displayUrl(for: .jpg)` 检查 JPG 扩展名与文件存在性。
- `displayUrl(for: .raw)` 检查 RAW 扩展名与文件存在性。
- UI 当前 `hasExistingJpgFile` / `hasExistingRawFile` 行为保留。

验收：

- RAW-only 照片 JPG segment 不可选。
- JPG-only 照片 RAW segment 不可选。
- 不再把 RAW 文件当 JPG URL 返回。

---

## 人工验收清单

由于本项目本轮不允许测试框架和验证脚本，验收只使用手动方式。

### 构建验收

1. 执行 `xcodebuild clean build`。
2. 构建成功。
3. Xcode 不再显示本轮目标 warning。

### 启动验收

1. 从 Xcode 启动 App。
2. 主窗口显示。
3. 标题仍为 `pickpick`。
4. 关闭最后一个窗口后 App 正常退出。

### 分析流程验收

1. 选择包含 JPG-only 的文件夹。
2. 选择包含 RAW-only 的文件夹。
3. 选择包含 RAW+JPG 配对的文件夹。
4. 选择包含损坏图片的文件夹。
5. 进度页面阶段正常变化。
6. 分析完成进入分组页。
7. 损坏图片不被误归为 Normal。

### 浏览器验收

1. 打开普通分组。
2. 上下键切换照片。
3. JPG / RAW segment 根据文件存在性启用或禁用。
4. 缩放、重置缩放正常。
5. 左右旋转正常并可持久化。

### 重复对比验收

1. 打开重复分组。
2. 左右箭头保留左 / 右。
3. Keep both 正常。
4. JPG / RAW segment 根据左右任意一侧文件存在性启用或禁用。
5. 双图同步缩放和旋转正常。

### 状态修改验收

1. 删除照片后文件进入废纸篓。
2. 重新进入 App 后已删除照片不再显示。
3. Restore Normal 后照片从异常分组移除。
4. 连续旋转、删除、Restore Normal 后状态仍正确。
5. `analysis.json` 仍能被 App 正常加载。

---

## 实施顺序建议

1. 阶段 1：构建配置、入口、actor 小修、EXIF、小 warning。
2. 阶段 2：`photoAnalysisService` 结构化并发重构。
3. 阶段 3：失败语义、存储串行化、图片加载取消、路径语义。
4. 阶段 4：按人工验收清单完整走一遍。

每个阶段完成后都运行 `xcodebuild clean build`，并手动打开 App 验证关键路径。

---

## 风险与控制

### 风险 1：actor 标注过宽导致 UI 或服务调用链新 warning

控制：优先局部标注，不一次性关闭项目级 MainActor。

### 风险 2：分析并发重构改变进度顺序

控制：保留阶段区间；只要求完成数递增，不要求任务完成顺序与文件顺序一致；最终 records 输出按 `pairs` 顺序。

### 风险 3：失败照片不进 Normal 后可能不显示

控制：本轮先避免误判 normal；若用户后续需要查看失败照片，再单独设计 Analysis Failed 分组。

### 风险 4：存储串行化影响 UI 响应

控制：只串行化文件读改写临界区，不把 UI 操作放入长时间锁内。

---

## 最终成功标准

1. `xcodebuild clean build` 成功。
2. 本轮目标 warning 清零。
3. Swift 6 高风险 warning 消失。
4. 分析流程无 Thread Performance Checker 核心优先级反转堆栈。
5. App 主要功能保持可用：启动、分析、分组、浏览、重复对比、删除、Restore Normal、旋转。
6. 不引入测试框架。
7. 不新增验证脚本。
