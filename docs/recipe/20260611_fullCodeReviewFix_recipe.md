# Recipe — 全量代码审查问题修复方案

## 背景

基于 `docs/codeReview/260611_full_code_review.md` 的全量审查结果，本方案覆盖全部 17 个问题。目标选择为 **完整性优先**：不仅消除崩溃、卡死、状态错乱，也要明确数据一致性、错误处理、并发边界、资源保护和验收标准。

本方案不新增 XCTest target。验证方式为 Debug 构建、关键路径手动验收和必要的轻量自检。

当前项目状态：

- `xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build` 当前通过。
- 工作区存在大量未提交变更，包括删除旧 `cpp/` 模块、新增 Swift 原生分析服务和 LibRaw bridge。
- 修复应只触及审查问题相关文件，不做无关重构。

## 方案选择

采用 **方案 2：完整性优先的定向重构**。

不采用最小补丁式修复，因为它会让 JSON 状态事务、错误提示和并发规则继续分散。不采用架构治理式修复，因为当前应用规模不需要新增大量抽象。本方案只在现有边界上做小范围结构调整：配置校验归 `configLoader`，review 写入归 `jsonReviewStateStore`，页面导航数据同步归 `appCoordinator`，分析并发和资源保护归分析服务/Analyzer。

---

## 1. 配置与资源防护

### 目标

消除错误配置和超大图片导致的卡死、崩溃、资源爆炸问题。

覆盖问题：

- `metalConcurrency = 0` 导致永久卡死
- 曝光阈值越界导致 `UInt32` 转换崩溃或判定错误
- JPG 超高像素图导致 Metal buffer / texture 内存过高
- Metal encoder 强制解包导致 GPU 异常路径崩溃
- RAW DR 计算使用 histogram bin 语义错误

### 设计

#### 1.1 `configLoader` 成为配置边界

所有来自 YAML 的值在 `configLoader` 中完成校验，不让非法值进入分析层。

规则：

- exposure pixel threshold：限制在 `0.0...1.0`
- exposure ratio limit：限制在 `0.0...1.0`
- blur threshold：必须 finite 且 `>= 0`，非法时使用默认值
- metalConcurrency：限制在 `1...4`
- YAML 类型不匹配、NaN、Infinity：回退默认值

`rawBayerAnalyzer` 和 `jpgAnalyzer` 不重复实现配置校验，避免规则分散。

#### 1.2 JPG 分析增加像素数上限

在 `jpgAnalyzer.analyze` 读取 `CIImage.extent` 后增加最大像素数检查。

默认上限：`100_000_000` 像素。

超过上限时抛出明确错误，由上层现有 fallback / `jpg_failed` 逻辑处理。现阶段不引入降采样分析，避免改变虚焦/曝光算法语义。

#### 1.3 显示 JPG 增加基础尺寸保护

`photoDisplayService.loadJpg` 读取 CIImage 后检查：

- extent finite
- 宽高 > 0
- 像素数不超过上限

超过上限返回 `.unavailable("JPG too large")`。缩略图不受影响，因为缩略图已走 `CGImageSource` 降采样路径。

#### 1.4 Metal compute encoder 全部改为 guard

`rawBayerAnalyzer` 和 `jpgAnalyzer` 中所有 `cmd.makeComputeCommandEncoder()!` 改为 guard 抛错。

异常路径统一抛错，由现有 fallback 或 UI 错误展示处理。

#### 1.5 RAW 动态范围按真实码值计算

`computePercentiles` 返回的是 histogram bin，不再直接当作 RAW 码值。计算 DR 前先转换：

```swift
let maxBin = Double(binCount - 1)
let p01Code = Double(p01) / maxBin * Double(white - black)
let p999Code = Double(p999) / maxBin * Double(white - black)
```

再计算 `sceneSpreadEv` 和 `codeRangeEv`。

### 不做

- 不新增 config schema 字段
- 不新增测试 target
- 不实现 JPG 降采样分析
- 不在第 1 章处理 `metalAnalysisContext.shared` 初始化失败；该问题统一放到第 4 章错误反馈与可恢复初始化中处理

### 验收标准

- 错误 `metal_concurrency: 0` 不再卡死
- 曝光阈值配置为负数或大于 1 时不会崩溃
- 超大 JPG 不会导致内存爆炸
- Metal encoder 创建失败不会强制崩溃
- RAW DR 计算不再把 bin 直接当码值

---

## 2. 分析并发与主线程边界

### 目标

修复分析流程中的随机 UI 问题、数据竞争和进度倒退问题。

覆盖问题：

- 后台队列直接调用 `progressController.update`
- `exifReader` 共享 `DateFormatter` 并发访问
- 进度使用 `index + 1`，并发完成顺序下会跳动或倒退
- EXIF 阶段一次性提交所有任务，面对大图库资源压力过高

### 设计

#### 2.1 UI 更新只在 MainActor 执行

`photoAnalysisService` 保持纯服务层，不依赖 AppKit，也不承诺 progress 回调线程。

在 `appCoordinator.startAnalysis` 中明确切主线程：

```swift
_ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
    Task { @MainActor in
        progressController.update(progress: progress)
    }
}
```

边界：service 可以在后台线程报告进度，coordinator 负责 UI 主线程更新。

#### 2.2 `exifReader` 移除共享 `DateFormatter`

删除 `dateFormatter` 属性，`parseExifDate` 内部创建局部 formatter。

理由：最小修改，彻底消除线程安全问题。EXIF / Spotlight IO 成本远高于 formatter 创建成本，不引入锁。

#### 2.3 进度改用真实完成计数

EXIF 阶段和分析阶段分别维护真实完成数：

- `exifCompletedCount`
- `analysisCompletedCount`

每个任务完成时在锁内递增并读取当前 completed 值，再计算 progress。保证 completedCount 和 overallProgress 单调递增。

#### 2.4 EXIF 并发限流

保持现有 `DispatchQueue + DispatchGroup` 模式，但增加 semaphore 限流。

建议值：`8`。

理由：避免几千张照片时一次性打爆 ImageIO、Spotlight 和文件句柄；改动小，与现有 GPU semaphore 风格一致。

#### 2.5 分析阶段保持 GPU concurrency，但修正 leave 和 progress

分析阶段继续使用 queue + semaphore。`metalConcurrency` 已在第 1 章限制到 `1...4`。

修正点：

- `analysisGroup.leave()` 放入 `defer`
- progress 使用真实完成计数

#### 2.6 不引入取消机制

当前没有用户取消入口。本轮不做取消按钮，也不做 structured concurrency 大重写。

### 验收标准

- 分析过程中 AppKit UI 更新只发生在主线程
- 大量照片 EXIF 读取不会共享 `DateFormatter`
- 进度百分比和 completedCount 单调递增
- 1000+ 张照片时不会一次性无限 EXIF 并发
- Debug 构建通过

---

## 3. Review 状态事务与 coordinator 同步

### 目标

修复删除、保留、返回分组页后的内存态/JSON 状态不一致问题。

覆盖问题：

- 浏览器删除后返回分组页显示旧数据
- 删除/保留操作文件系统与 JSON 状态可能半成功
- 重复比较多次 load/save JSON，不是原子操作
- 重复比较控制器用 `try?` 吞掉错误

### 设计

#### 3.1 `jsonReviewStateStore` 增加批量更新接口

在 `jsonReviewStateStoring` 中增加一个批量 mutation 接口：

```swift
func update(_ mutate: (inout [photoItem]) -> Void) throws
```

实现方式：一次 load，一次 mutate，一次 save。

保留现有 `mark`、`setTemplate`、`clearReviewGroupId`，但内部可复用 `update`。这样兼容现有调用，也给 ViewModel 提供事务式更新入口。

#### 3.2 浏览器删除改成一次 JSON 写入

`photoBrowserViewModel.confirmDelete` 仍先移动文件到废纸篓，再一次性将目标 photoId 标记为 `.trashed`。

理由：当前 macOS trash 操作不可真正事务化。若先写 JSON 再 trash，失败时会把未删除文件隐藏；若先 trash 再写 JSON，写入失败会留下“文件已删但 JSON active”。本轮保持先 trash，再减少 JSON 多次写入窗口，并在 UI 处显示错误。

#### 3.3 重复比较动作改成单次 JSON mutation

`keepLeft`、`keepRight`、`keepBoth`、`markFinalKept` 不再连续调用多次 store 方法。每个用户动作只进行一次 `store.update`。

状态规则：

- keepLeft：right 标记 `.trashed`；若只剩 left，则 left 标记 `.kept`、设置 template、清空 left 的 reviewGroupId
- keepRight：left 标记 `.trashed`；若只剩 right，则 right 标记 `.kept`、设置 template、清空 right 的 reviewGroupId
- keepBoth：left/right 标记 `.kept` 并清空各自 reviewGroupId；若剩余照片仍属于原 duplicate group，则为剩余组设置选定 templatePhotoId

注意：`keepBoth` 中应先保存原始 groupId，再移除内存数组，避免移除后 `mainPhoto` 指向新照片导致 groupId 语义混乱。

#### 3.4 coordinator 返回分组前刷新数据

`appCoordinator.showBrowser` 和 `showDuplicate` 的 `onBack` 均在 `showGroups()` 前尝试 `reloadData()`。

```swift
do { try reloadData() } catch { /* showGroups with existing records or showError */ }
showGroups()
```

对于删除成功后的浏览器页面，当前控制器内已更新局部 photos；返回时 reloadData 会同步全局 records。

#### 3.5 控制器不再用 `try?` 吞错

`duplicateCompareViewController` 的 keep left/right/both 全部改为 `do/catch`。

失败时显示 `NSAlert`，并保持当前 UI 状态，不假装动作成功。

`photoBrowserViewController.deleteClicked` 的 catch 也从 `print` 改成 alert。

### 验收标准

- 浏览器删除照片后返回分组页不再显示已 trashed 项
- 重复比较 keep 操作失败时用户能看到错误
- 每个重复比较动作只进行一次 JSON 写入
- `keepBoth` 在 2 张和 3+ 张场景下状态正确
- 删除/保留后重新进入分组，分组数量和照片列表与 JSON 一致

---

## 4. UI 错误反馈与显示一致性

### 目标

让错误路径对用户可见，减少黑屏、静默失败和页面行为不一致。

覆盖问题：

- `showError(_:)` 只设置状态，不实际渲染错误文字
- Browser 切换 JPG/RAW 不写入 `displaySourceStore`
- `appDelegate` 中有不必要强制解包和临时日志
- `analysisStore.hasResults` 只看文件存在，损坏 JSON 阻断重新分析
- `metalAnalysisContext` fatalError 风险

### 设计

#### 4.1 `photoMetalViewController` 增加 AppKit 错误 label

不在 Metal draw 里画文字，而是在 `photoMetalViewController` 的 container 中增加一个居中的 `NSTextField`。

状态规则：

- `load(image:)`：隐藏错误 label，显示 metalView
- `reset()`：隐藏错误 label，清空 metalView
- `showError(_:)`：显示错误 label，清空 metalView

这样比在 Metal 内绘制文本更简单，也符合 AppKit 现有风格。

#### 4.2 Browser source 切换持久化

`photoBrowserViewController.sourceChanged` 写入 `displaySourceStore().current`，与 Duplicate 页面行为一致。

不新增 ViewModel 依赖，保持最小修改。

#### 4.3 appDelegate 清理强制解包和调试日志

将 `controller.window!` 改为 `guard let window`。启动日志保留必要信息即可，移除临时 emoji 和 CRITICAL 文案。

#### 4.4 损坏 analysis.json 的处理

`analysisStore.hasResults` 不再作为“可加载”的唯一依据。

`appCoordinator.startAnalysis` 流程调整为：

1. 如果结果文件存在，尝试 `loadRecords`
2. load 成功则进入 groups
3. load 失败则执行重新分析
4. 重新分析仍失败才进入错误页

不新增“重建缓存”按钮，避免扩大 UI 范围。

#### 4.5 `metalAnalysisContext` 改为可抛错初始化

`metalAnalysisContext` 不再在初始化失败时 `fatalError`。设计为可恢复错误边界：

- `metalAnalysisContext` 的内部初始化改为 throwing
- 提供共享访问入口，例如 `metalAnalysisContext.shared()`，返回 `throws -> metalAnalysisContext`
- 内部用 `Result<metalAnalysisContext, Error>` 缓存初始化结果，避免重复编译 pipeline
- 缺少 Metal、commandQueue 创建失败、library 缺失、pipeline 创建失败都抛出可读错误

`rawBayerAnalyzer` 和 `jpgAnalyzer` 不再在属性初始化时强制拿到 context。它们改为在 `analyze` 内获取 context：

- `rawBayerAnalyzer.analyze` 开始时 `let context = try contextProvider()`
- `jpgAnalyzer.analyze` 开始时 `let context = try contextProvider()`，并在拿到 context 后创建局部 `CIContext`

这样可以保持 analyzer 初始化不抛错，避免大范围改动 `photoAnalysisService` 的默认参数；同时当设备不支持 Metal 或 shader 缺失时，错误会沿现有 `throws` 路径进入 coordinator 错误页，而不是应用直接退出。

### 验收标准

- RAW/JPG 不可用时主图区域显示错误文本，而不是纯黑屏
- Browser 与 Duplicate 的 JPG/RAW 选择持久化行为一致
- 启动窗口逻辑不再使用不必要强制解包
- 损坏 analysis.json 时可重新分析，不直接卡在错误页
- Metal 初始化失败时进入可恢复错误路径，不直接 `fatalError` 退出
- Debug 构建通过

---

## 5. 验收与手动测试清单

### 构建验证

执行：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

必须通过。

### 手动验收

#### 5.1 配置防护

准备临时图库目录，放入非法 `config.yaml`：

```yaml
exposure_detection:
  overexpose_pixel_threshold: -1
  underexpose_pixel_threshold: 2
  overexpose_ratio_limit: -0.5
  underexpose_ratio_limit: 8
analysis:
  metal_concurrency: 0
```

期望：应用不崩溃、不永久卡住，可完成分析或给出明确错误。

#### 5.2 分析进度

用包含多张 JPG/RAW 的目录启动分析。

期望：进度 completedCount 单调递增，百分比不倒退，UI 不出现主线程异常。

#### 5.3 浏览器删除同步

进入任意非重复组，删除当前照片或勾选多张删除，返回分组页。

期望：已删除照片不再出现在分组页或缩略图列表，重新进入也不出现。

#### 5.4 重复比较状态

分别验证：

- 两张重复：Keep left / Keep right / Keep both
- 三张以上重复：Keep both 后继续比较剩余照片
- trash 或 JSON 写入失败时能看到错误 alert

期望：JSON 状态、分组页面和实际文件状态一致。

#### 5.5 显示错误文本

选择 RAW 缺失或无法解码的照片，切到 RAW。

期望：主图区域显示可读错误，而不是黑屏。

#### 5.6 source 持久化

在 Browser 切到 RAW，返回后再进入其他组。

期望：source 选择保持一致，与 Duplicate 页面行为一致。

---

## 实施顺序建议

1. 配置校验与 Metal encoder guard
2. 分析进度、MainActor UI 更新、EXIF DateFormatter 修复
3. `jsonReviewStateStore.update` 与 ViewModel 事务写入
4. coordinator 返回刷新与控制器错误 alert
5. 显示错误 label、source 持久化、appDelegate 清理
6. 构建验证与手动验收

每一步完成后都应至少运行一次 Debug build。第 3、4 步完成后需要重点手动验证删除与重复比较流程。

## 范围外事项

- 不新增 XCTest target
- 不新增取消按钮
- 不重写分析流程为 structured concurrency
- 不引入新的 error presenter 抽象
- 不引入完整依赖注入容器；仅把 `metalAnalysisContext` 初始化失败改为可抛错路径
- 不实现 JPG 降采样分析
- 不做无关命名/格式重构
