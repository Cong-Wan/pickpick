# 去除 cpp 原生分析重构审查问题修复方案

**Date:** 2026-06-11  
**Source Review:** `docs/codeReview/20260610_remove_cpp_native.md`  
**Related Plan:** `docs/flare/20260610_remove_cpp_native_analysis.md`  
**Related Recipe:** `docs/recipe/20260610_remove_cpp_native_analysis_recipe.md`  
**Scope:** 完整记录审查报告中的所有问题；本轮实施优先修复 Critical + High，Medium/Low 作为 follow-up 管理。

---

## 1. 目标

基于 `docs/codeReview/20260610_remove_cpp_native.md` 的审查结果，对当前 Swift 原生分析重构做发布前收口。

本方案不重新设计分析架构，不恢复 cpp，不扩大 UI 改造范围，只修复审查报告中影响正确性、可维护性和数据一致性的关键问题，并把其它问题作为后续 follow-up 记录。

---

## 2. 修复分层

### 2.1 本轮必须修复：Critical + High

本轮修复 6 类问题：

1. `config.yaml` schema 与 Swift ratio 配置不一致，且未加入 bundle resources。
2. `libRawBridge` 解码失败仍返回非空 handle。
3. `analysisStore` 通过 `photoItemRecord` 做冗余转换，且代码里出现不必要的 `pickpick.` 模块名前缀。
4. `rawBayerAnalyzer` / `jpgAnalyzer` percentile 计算使用 `0` 作为哨兵，存在误判风险。
5. `laplacianKernelSize` 是死配置，当前 Metal kernel 不读取。
6. `jsonReviewStateStore` 写回 review 状态时使用 `analysisConfig.defaults` 覆盖真实 `configSnapshot`。

### 2.2 本轮可选小修

若实施成本很低，可一起修：

1. `libRawBridge.h` 补充 raw image 指针生命周期说明。
2. `analysisStore` 初始化 Application Support 目录时避免 `try!` crash。
3. 相关文件头版本号与 Description 更新。

### 2.3 后续 follow-up

只在方案中记录，不纳入本轮必须实施：

1. `metalAnalysisContext` 的 `fatalError` 改为可抛错初始化。
2. `rawBayerAnalyzer.analyze` 真正 async 化。
3. progress 权重更贴近实际耗时。
4. `metalConcurrency` 默认值调优。
5. `metalPhotoView` draw 早退旧帧残留。
6. `fileScanner` 风格优化。
7. `mainWindowController` 冗余初始化清理。

---

## 3. 文件级修改方案

### 3.1 `rawViewer/config.yaml`

#### 问题

当前配置仍是旧 cpp 时代 schema：

```yaml
overexpose_pixel_threshold: 245
underexpose_pixel_threshold: 10
```

但 Swift 代码期待 ratio：

```swift
absOver = black + (white - black) * ratio
```

如果用户目录下存在旧 schema config，会导致过曝/欠曝判断错误。

#### 修复

替换为 Swift schema 2.0：

```yaml
# pickpick 默认分析参数
# Swift 原生分析 schema 2.0
# exposure_detection 中的像素阈值均为 0.0~1.0 ratio。

exposure_detection:
  overexpose_pixel_threshold: 0.96
  underexpose_pixel_threshold: 0.04
  overexpose_ratio_limit: 0.05
  underexpose_ratio_limit: 0.05

blur_detection:
  laplacian_threshold_raw: 5000.0
  laplacian_threshold_jpg: 10.0

analysis:
  metal_concurrency: 2
```

#### 关键决策

本轮删除 `laplacian_kernel_size` 配置字段，而不是实现 5x5/7x7 kernel。

原因：

- 当前 Metal kernel 已硬编码 3x3。
- 实现动态 kernel 会扩大 Metal 改动范围。
- 保留字段会误导用户“改了会生效”。
- 删除字段是最小正确修复。

---

### 3.2 `rawViewer.xcodeproj/project.pbxproj`

#### 问题

`config.yaml` 没有加入 `Copy Bundle Resources`，导致：

```swift
Bundle.main.url(forResource: "config", withExtension: "yaml")
```

实际返回 nil。

#### 修复

将 `rawViewer/config.yaml` 加入 `pickpick` target 的 Resources build phase。

#### 验收

构建产物中应能找到：

```plain
pickpick.app/Contents/Resources/config.yaml
```

可用以下方式验证：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
find ~/Library/Developer/Xcode/DerivedData -path '*pickpick.app/Contents/Resources/config.yaml' -print
```

---

### 3.3 `rawViewer/services/analysisConfig.swift`

#### 问题

`blurConfig.laplacianKernelSize` 被定义、解析、持久化，但没有任何分析代码读取。

#### 修复

删除：

```swift
public var laplacianKernelSize: Int
```

并同步删除 init 参数与 defaults 中的：

```swift
laplacianKernelSize: 3
```

#### 文件头

版本建议：

```swift
Version: 1.1
Description: 移除未生效的 laplacianKernelSize 死配置，保持 config schema 与 Metal 3x3 kernel 行为一致
```

---

### 3.4 `rawViewer/services/configLoader.swift`

#### 问题

当前仍解析：

```swift
laplacian_kernel_size
```

但该字段实际无效。

#### 修复

删除 `laplacianKernelSize` 解析逻辑。

保留：

```plain
laplacian_threshold_raw
laplacian_threshold_jpg
metal_concurrency
```

#### 可选增强

本轮不强制增加复杂校验器。若实施时选择增加最小保护，可将 exposure ratio clamp 到 `[0, 1]`，但不得引入迁移旧 schema 的额外行为。

---

### 3.5 `rawViewer/bridge/libRawBridge.mm`

#### 问题

当前失败时仍返回 handle：

```cpp
if (ret != LIBRAW_SUCCESS) {
    h->lastError = "open_file failed";
    return h;
}
```

这与 Swift 侧：

```swift
guard let handle = rwRawOpen(rawPath) else {
    throw rawOpenError(rawPath)
}
```

语义冲突。

#### 修复

失败时释放并返回 `nullptr`：

```cpp
void* rwRawOpen(const char* path) {
    if (path == nullptr) return nullptr;

    auto* h = new RawHandle;

    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) {
        delete h;
        return nullptr;
    }

    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) {
        delete h;
        return nullptr;
    }

    return h;
}
```

#### 取舍

失败返回 `nullptr` 后，Swift 无法通过 handle 读取 `lastError` 详细内容。本轮接受这个取舍，原因：

- 用户层只需要知道 RAW 打开失败并回退 JPG。
- 重点是修正所有权和 handle 语义。
- 如果后续需要保留详细错误，可新增 thread-local error，但本轮不扩展。

---

### 3.6 `rawViewer/bridge/libRawBridge.h`

#### 问题

`rawImage` 生命周期依赖 LibRaw handle，但头文件没有说明。

#### 修复

补充注释：

```c
// rawImage points to LibRaw internal raw_image.
// It remains valid after rwRawOpen until rwRawClose.
// Do not call dcraw_process/recycle/clear_mem before Swift copies it.
const uint16_t* rawImage;
```

---

### 3.7 `rawViewer/models/photoModels.swift`

#### 问题

`photoItem` 目前不是 `Codable`，导致 `analysisStore` 额外引入 `photoItemRecord` 做转换。

#### 修复

改为：

```swift
public struct photoItem: Codable, Equatable, Identifiable
```

其它字段已满足 Codable：

- `reviewStatus: Codable`
- `dynamicRangeData: Codable`
- `String`
- `Bool`
- Optional String

#### 文件头

版本建议：

```plain
Version: 1.4
Description: photoItem 增加 Codable 支持，简化 analysisStore 持久化 schema
```

---

### 3.8 `rawViewer/services/analysisStore.swift`

#### 问题 1：冗余 record

当前有：

```swift
struct photoItemRecord: Codable, Equatable
```

以及：

```swift
extension photoItemRecord { init(from item: photoItem) }
extension photoItem { init(from record: photoItemRecord) }
```

这会让 JSON schema 维护成本增加。

#### 修复 1

删除 `photoItemRecord`，改为：

```swift
struct analysisFile: Codable {
    var schemaVersion: String = "2.0"
    var folderPath: String = ""
    var createdAt: String = ""
    var updatedAt: String = ""
    var summary: summaryData = summaryData()
    var photos: [photoItem] = []
    var configSnapshot: analysisConfig?
}
```

load：

```swift
return root.photos
```

save：

```swift
existing.photos = records
```

#### 问题 2：`pickpick.reviewStatus`

删除 record 后自然消失。

#### 问题 3：review 写回覆盖 configSnapshot

当前 save 必须传 config：

```swift
save(folderUrl: records: config:)
```

导致 `jsonReviewStateStore` 只能传 defaults。

#### 修复 3

改为：

```swift
public func save(
    folderUrl: URL,
    records: [photoItem],
    config: analysisConfig? = nil
) throws
```

写入逻辑：

```swift
if let config {
    existing.configSnapshot = config
}
```

这样：

- 分析完成时传真实 config，会写入或更新 snapshot。
- review 状态更新时传 nil，会保留旧 snapshot。

#### 可选小修：避免 `try!`

当前：

```swift
self.appSupportDir = try! fileManager.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
).appendingPathComponent("rawViewer", isDirectory: true)
```

改为 do-catch，失败回退临时目录：

```swift
do {
    self.appSupportDir = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ).appendingPathComponent("rawViewer", isDirectory: true)
} catch {
    self.appSupportDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rawViewer", isDirectory: true)
}
```

---

### 3.9 `rawViewer/models/jsonReviewStateStore.swift`

#### 问题

当前 review 写回：

```swift
try analysisStore.shared.save(folderUrl: folderUrl, records: records, config: analysisConfig.defaults)
```

会覆盖真实 `configSnapshot`。

#### 修复

改为：

```swift
try analysisStore.shared.save(folderUrl: folderUrl, records: records, config: nil)
```

或利用默认参数：

```swift
try analysisStore.shared.save(folderUrl: folderUrl, records: records)
```

#### 文件头

版本建议：

```plain
Version: 1.5
Description: review 状态写回时保留既有 configSnapshot，避免覆盖真实分析配置
```

---

### 3.10 `rawViewer/services/rawBayerAnalyzer.swift`

#### 问题

percentile 计算使用：

```swift
var p01Bin: UInt32 = 0
if p01Bin == 0, cum >= p01Target {
    p01Bin = UInt32(i)
}
```

`0` 同时表示“未设置”和“第 0 个 bin”，语义不清。

还有：

```swift
UInt64(Int64(p01Target))
```

转换不必要。

#### 修复

改为 Optional：

```swift
private func computePercentiles(
    greenHist: [UInt32],
    totalPixels: UInt64,
    binCount: Int
) -> (UInt32, UInt32) {
    guard totalPixels > 0, !greenHist.isEmpty else { return (0, 0) }

    let p01Target = UInt64(Double(totalPixels) * 0.001)
    let p999Target = UInt64(Double(totalPixels) * 0.999)

    var cum: UInt64 = 0
    var p01Bin: UInt32?
    var p999Bin: UInt32?

    for i in 0..<binCount {
        cum += UInt64(greenHist[i])

        if p01Bin == nil, cum >= p01Target {
            p01Bin = UInt32(i)
        }

        if p999Bin == nil, cum >= p999Target {
            p999Bin = UInt32(i)
            break
        }
    }

    return (
        p01Bin ?? 0,
        p999Bin ?? UInt32(max(0, binCount - 1))
    )
}
```

调用处建议：

```swift
let (p01, p999) = computePercentiles(
    greenHist: greenHist,
    totalPixels: UInt64(greenW * greenH),
    binCount: Int(binCount)
)
```

---

### 3.11 `rawViewer/services/jpgAnalyzer.swift`

#### 问题

同样使用 `p01Bin == 0` 哨兵。

#### 修复

改为 Optional：

```swift
private func computePercentiles(
    histogram: [UInt32],
    totalPixels: UInt64
) -> (UInt32, UInt32) {
    guard totalPixels > 0, !histogram.isEmpty else { return (0, 0) }

    let p01Target = UInt64(Double(totalPixels) * 0.001)
    let p999Target = UInt64(Double(totalPixels) * 0.999)

    var cum: UInt64 = 0
    var p01Bin: UInt32?
    var p999Bin: UInt32?

    for i in 0..<histogram.count {
        cum += UInt64(histogram[i])

        if p01Bin == nil, cum >= p01Target {
            p01Bin = UInt32(i)
        }

        if p999Bin == nil, cum >= p999Target {
            p999Bin = UInt32(i)
            break
        }
    }

    return (
        p01Bin ?? 0,
        p999Bin ?? UInt32(max(0, histogram.count - 1))
    )
}
```

---

### 3.12 `rawViewer/services/photoAnalysisService.swift`

#### 问题

当前初始化默认 jpg analyzer：

```swift
self.jpgAnalyzer = jpgAnalyzer ?? pickpick.jpgAnalyzer()
```

`pickpick.` 前缀没有必要，容易误解为外部模块。

#### 修复

由于 `jpgAnalyzer` 类型名、初始化参数名和 stored property 名容易同名遮蔽，推荐使用静态工厂方法消除歧义：

```swift
public init(
    scanner: fileScanner = fileScanner(),
    exif: exifReader = exifReader(),
    grouper: duplicateGrouper = duplicateGrouper(),
    rawAnalyzer: rawBayerAnalyzing = rawBayerAnalyzer(),
    jpgAnalyzerOverride: (any jpgAnalyzing)? = nil,
    store: analysisStore = .shared,
    cfgLoader: configLoader = configLoader()
) {
    self.scanner = scanner
    self.exif = exif
    self.grouper = grouper
    self.rawAnalyzer = rawAnalyzer
    self.jpgAnalyzer = jpgAnalyzerOverride ?? Self.makeDefaultJpgAnalyzer()
    self.store = store
    self.cfgLoader = cfgLoader
}

private static func makeDefaultJpgAnalyzer() -> any jpgAnalyzing {
    jpgAnalyzer()
}
```

---

## 4. 数据流修复后状态

### 4.1 分析路径

```plain
folderUrl/config.yaml
    ↓ fallback
Bundle.main/config.yaml
    ↓ fallback
analysisConfig.defaults
    ↓
photoAnalysisService.analyze
    ↓
rawBayerAnalyzer / jpgAnalyzer
    ↓
analysisStore.save(config: actualConfig)
    ↓
analysis.json.configSnapshot
```

### 4.2 Review 写回路径

```plain
jsonReviewStateStore.mark / setTemplate / clearReviewGroupId
    ↓
analysisStore.load
    ↓
mutate records
    ↓
analysisStore.save(config: nil)
    ↓
保留既有 configSnapshot
```

### 4.3 RAW 失败路径

```plain
rwRawOpen
    ├─ open_file failed → delete handle → nullptr
    ├─ unpack failed    → delete handle → nullptr
    └─ success          → handle
```

Swift：

```plain
handle == nil → throw RAW open failed → JPG fallback
```

---

## 5. 错误处理策略

### 5.1 配置错误

本轮不新增复杂校验器。

原因：

- 当前目标是 schema 正确和 bundle 可用。
- `configLoader` 已有字段缺失 fallback defaults。
- 用户目录下旧 config 仍可能错误，但文档明确 schema 2.0 后，后续可单独加迁移或校验。

### 5.2 RAW 解码失败

失败返回 `nullptr`，由 Swift fallback JPG。

不在本轮新增 thread-local detailed error，避免桥接层复杂化。

### 5.3 持久化失败

`analysisStore.save` 继续向上抛错，由现有 UI error path 展示。

可选小修中，Application Support 初始化失败回退 tmp，避免启动阶段 crash。

---

## 6. 测试与验收方案

### 6.1 编译验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' build
```

成功标准：

```plain
** BUILD SUCCEEDED **
```

### 6.2 Bundle config 验证

构建后确认 app bundle 内存在：

```plain
Contents/Resources/config.yaml
```

并且内容为 ratio schema。

### 6.3 配置链路验证

准备一个照片目录，放入：

```yaml
exposure_detection:
  overexpose_pixel_threshold: 0.92
  underexpose_pixel_threshold: 0.04
  overexpose_ratio_limit: 0.05
  underexpose_ratio_limit: 0.05

blur_detection:
  laplacian_threshold_raw: 5000.0
  laplacian_threshold_jpg: 10.0

analysis:
  metal_concurrency: 2
```

重新分析后确认：

1. `analysis.json` 根级 `configSnapshot` 记录的是 `0.92`。
2. 删除目录 config 后重新分析，使用 bundle/default 的 `0.96`。

### 6.4 review 写回验证

步骤：

1. 完成一次分析。
2. 记录 `analysis.json.configSnapshot`。
3. 在 UI 中 mark 某张照片为 passed/trashed/kept。
4. 重新读取 `analysis.json`。

成功标准：

- `photos[].reviewStatus` 已变化。
- `configSnapshot` 未被改成 defaults。
- `updatedAt` 可更新，但 `createdAt` 保持原值。

### 6.5 percentile 验证

虽然项目当前没有测试框架，本轮至少通过代码审查确认以下输入行为：

1. 空 histogram → `(0, 0)`
2. 全部像素在 bin 0 → `p01 = 0`
3. 第一个非空 bin 是 10 → `p01 = 10`
4. `p999` 未命中时 fallback 到最后 bin

如果后续引入测试，可优先为 `computePercentiles` 抽出纯函数测试。

### 6.6 RAW 失败路径验证

用损坏 RAW 或非 RAW 文件伪装为 `.RW2`：

成功标准：

1. `rwRawOpen` 不泄漏 handle。
2. Swift 侧进入 JPG fallback。
3. 没有出现“先成功后 LibRaw error”的双重语义。

---

## 7. 实施顺序建议

### Step 1：配置 schema 与 bundle

修改：

- `rawViewer/config.yaml`
- `rawViewer.xcodeproj/project.pbxproj`
- `analysisConfig.swift`
- `configLoader.swift`

验证：

- build 通过
- bundle 有 config.yaml

### Step 2：持久化 schema 简化

修改：

- `photoModels.swift`
- `analysisStore.swift`

验证：

- `photoItem` Codable 编译通过
- `analysisStore.load/save` 编译通过

### Step 3：review 写回保留 configSnapshot

修改：

- `jsonReviewStateStore.swift`
- `analysisStore.save` 默认参数

验证：

- review 操作不覆盖 configSnapshot

### Step 4：LibRaw bridge 语义修复

修改：

- `libRawBridge.h`
- `libRawBridge.mm`

验证：

- build 通过
- RAW 打开失败返回 nil

### Step 5：percentile 修复

修改：

- `rawBayerAnalyzer.swift`
- `jpgAnalyzer.swift`

验证：

- build 通过
- 逻辑审查通过

### Step 6：去掉 `pickpick.` 前缀

修改：

- `photoAnalysisService.swift`
- `analysisStore.swift` 中相关残留

验证：

- build 通过
- 无 `pickpick.` 业务调用残留

---

## 8. 不纳入本轮的明确边界

本轮不做：

1. 不重写 Metal kernel。
2. 不实现可配置 Laplacian kernel size。
3. 不引入 XCTest。
4. 不改 UI 页面结构。
5. 不改分析结果展示逻辑。
6. 不恢复 cpp。
7. 不做旧 `.cache/analysis.json` 迁移。
8. 不做完整 config schema migration。

---

## 9. 成功标准

本方案完成后应满足：

1. `xcodebuild` 编译通过。
2. app bundle 中包含新 schema `config.yaml`。
3. 默认配置、folder 配置、hardcoded defaults 三层 fallback 语义一致。
4. `laplacianKernelSize` 不再作为无效配置暴露。
5. RAW 解码失败时 bridge 返回 `nullptr`，不泄漏 handle。
6. `photoItem` 直接 Codable，`analysisStore` 不再依赖 `photoItemRecord`。
7. 业务源码中无不必要的 `pickpick.` 模块名前缀。
8. review 写回不覆盖真实 `configSnapshot`。
9. percentile 计算不再用 `0` 作为未设置哨兵。
10. 审查报告中的 Critical + High 问题全部有明确处理结果。
11. Medium/Low 问题已记录为 follow-up，不混入本轮实施范围。

---

## 10. Follow-up 登记

以下问题来自审查报告，已确认不进入本轮必须修复范围：

| 问题 | 原因 | 后续建议 |
|---|---|---|
| `metalAnalysisContext` 使用 `fatalError` | 改动涉及初始化错误传递链路 | 单独设计 Metal 不可用时的用户提示 |
| `exifReader` CoreFoundation 释放语义需要说明 | 当前 Swift ARC 基本安全，不影响本轮正确性 | 在文件头或局部注释说明 CF 对象由 Swift ARC 管理 |
| `rawBayerAnalyzer.analyze` 同步阻塞 | 需要重构分析 pipeline 为 async | 后续拆分 open/dispatch/post-process 阶段 |
| `metalPhotoView` 早退旧帧残留 | 视图显示问题，独立于分析链路 | 后续单独修复 draw fallback |
| `fileScanner` 字典更新风格 | 可读性建议 | 后续碰到扫描逻辑时顺手整理 |
| `analysisStore` Application Support 初始化 `try!` | 本轮列为可选小修，若未做需保留跟踪 | 改为 do-catch，失败回退 tmp 目录 |
| `libRawBridge` raw image 所有权语义 | 本轮列为可选注释，若未做需保留跟踪 | 在 bridge 头文件说明 rawImage 生命周期 |
| `analysisConfig.defaults` 字面量维护风险 | 不影响当前行为 | 后续改为 `static func makeDefault()` 工厂 |
| `metalConcurrency` 默认值偏保守 | 性能调优问题 | 后续基准测试后调整默认值 |
| progress 权重硬编码 | 不影响正确性 | 后续按实际耗时或完成数动态计算 |
| `mainWindowController` 初始化冗余 | 无功能影响 | 后续清理初始化路径 |
| `analysisStore.folderHash` prefix 表述易误解 | 文档/命名清晰度问题 | 后续补注释，说明 8 bytes digest = 16 hex chars |
