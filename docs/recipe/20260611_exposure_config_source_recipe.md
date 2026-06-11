# 曝光参数放宽与配置来源统一方案

## 背景

本方案针对两个问题：

1. `D12EC2A6130AB943/analysis.json` 中过多照片被归类为欠曝或过曝。
2. 当前 `configLoader` 会优先读取被分析文件夹内的 `config.yaml`，这不符合预期；运行参数应统一来自编译进 app bundle 的 `rawViewer/config.yaml`。

分析目标 JSON：

```text
~/Library/Containers/Wilbur.pickpick/Data/Library/Application Support/rawViewer/D12EC2A6130AB943/analysis.json
```

其对应照片目录：

```text
/Users/wilbur/Downloads/test_bak2
```

## 当前 JSON 分析结果

### 汇总

当前 `summary`：

```json
{
  "totalPhotos": 168,
  "underexposed": 147,
  "overexposed": 14,
  "normal": 7,
  "blurry": 11
}
```

按曝光分类占比：

| 分类 | 数量 | 占比 |
| --- | ---: | ---: |
| 欠曝 underexposed | 147 | 87.5% |
| 过曝 overexposed | 14 | 8.3% |
| 正常 normal | 7 | 4.2% |

当前结果明显过严：仅 4.2% 被归为 normal，说明曝光判定阈值需要放宽。

### 当前使用的配置快照

JSON 中的 `configSnapshot`：

```json
{
  "exposure": {
    "overexposePixelThreshold": 0.96,
    "underexposePixelThreshold": 0.04,
    "overexposeRatioLimit": 0.05,
    "underexposeRatioLimit": 0.05
  },
  "blur": {
    "laplacianThresholdJpg": 10,
    "laplacianThresholdRaw": 5000
  },
  "metalConcurrency": 6
}
```

曝光判定逻辑当前为：

```swift
if overRatio > overexposeRatioLimit {
    exposureStatus = "overexposed"
} else if underRatio > underexposeRatioLimit {
    exposureStatus = "underexposed"
} else {
    exposureStatus = "normal"
}
```

其中：

- `overexposePixelThreshold`：像素亮度超过该阈值，计为高亮像素。
- `underexposePixelThreshold`：像素亮度低于该阈值，计为暗部像素。
- `overexposeRatioLimit`：高亮像素占比超过该值，判定过曝。
- `underexposeRatioLimit`：暗部像素占比超过该值，判定欠曝。

当前 `ratioLimit` 都是 `0.05`，即只要 5% 像素落入高亮/暗部区域，就会判定异常。对实际照片来说，这个规则偏严格：很多正常照片也可能有超过 5% 的阴影区域或高光区域。

### 按分析来源分布

| analysisSource | 数量 | 曝光分类 |
| --- | ---: | --- |
| raw | 158 | underexposed 137, overexposed 14, normal 7 |
| jpg | 10 | underexposed 10 |

结论：

- 问题主要发生在 RAW 分析上，因为 158 张中 151 张被归为欠/过曝。
- JPG 数量较少，但 10 张全部被判为欠曝，也说明欠曝规则偏严。

### 当前 JSON 的限制

当前 JSON 没有保存这些关键诊断字段：

- 每张照片的 `overRatio`
- 每张照片的 `underRatio`
- 每张照片实际使用的绝对阈值
- 曝光判定时的像素计数

因此，无法只靠现有 JSON 精确推导“把参数改成多少后，会有多少张从 underexposed/overexposed 变回 normal”。本方案只能基于最终分类比例和现有阈值进行保守调参。若后续需要精调，应在 JSON 中新增诊断字段。

## 参数调整方案

### 推荐方案：保守放宽曝光判定

把编译进 app 的 `rawViewer/config.yaml` 中曝光参数调整为：

```yaml
exposure_detection:
  overexpose_pixel_threshold: 0.98
  underexpose_pixel_threshold: 0.02
  overexpose_ratio_limit: 0.10
  underexpose_ratio_limit: 0.15
```

调整理由：

1. `underexposed` 当前占比 87.5%，误判压力最大，所以欠曝侧放宽更多。
2. `underexpose_pixel_threshold: 0.04 -> 0.02`：只有更接近纯黑的像素才计为暗部像素。
3. `underexpose_ratio_limit: 0.05 -> 0.15`：暗部像素占比需要超过 15% 才判定欠曝。
4. `overexpose_pixel_threshold: 0.96 -> 0.98`：只有更接近纯白/高亮的像素才计为高亮像素。
5. `overexpose_ratio_limit: 0.05 -> 0.10`：高亮像素占比需要超过 10% 才判定过曝。

这是一组“明显更宽松但不过度失控”的初始参数，适合先跑一次完整分析，观察 normal 数量是否明显回升。

### 不建议一次性过度放宽

不建议直接改成：

```yaml
underexpose_ratio_limit: 0.30
overexpose_ratio_limit: 0.20
```

原因：

- 当前 JSON 缺少原始比例，无法判断这些阈值是否会把真正异常照片也全部吞掉。
- 一次放太宽会导致调参方向不可解释，不利于后续校准。

### 建议的二次调参规则

重新分析后，看新的 `summary`：

- 如果 `underexposed` 仍然明显过多：
  - 先把 `underexpose_ratio_limit` 从 `0.15` 提到 `0.20`。
  - 如仍过多，再把 `underexpose_pixel_threshold` 从 `0.02` 降到 `0.015`。

- 如果 `overexposed` 仍然明显过多：
  - 先把 `overexpose_ratio_limit` 从 `0.10` 提到 `0.15`。
  - 如仍过多，再把 `overexpose_pixel_threshold` 从 `0.98` 提到 `0.99`。

- 如果异常照片明显漏检：
  - 反向收紧对应参数。

## 配置来源统一方案

### 当前行为

`rawViewer/services/configLoader.swift` 当前加载顺序是：

```text
folderUrl/config.yaml > Bundle.main/config.yaml > analysisConfig.defaults
```

这会导致同一个 app 在不同照片文件夹下使用不同配置，不符合“统一从编译进 app 的 config.yaml 读取”的要求。

### 目标行为

改为：

```text
Bundle.main/config.yaml > analysisConfig.defaults
```

明确不再读取：

```text
被分析文件夹/config.yaml
```

### 保留 defaults 兜底

虽然运行参数应统一来自 bundle config，但仍建议保留 `analysisConfig.defaults` 兜底，原因：

- Xcode Copy Bundle Resources 如果配置错误导致 `config.yaml` 未打包，app 不应直接崩溃。
- 兜底值与 `rawViewer/config.yaml` 应保持一致或足够安全。
- `configSnapshot` 会记录最终实际使用参数，便于发现 bundle config 是否未生效。

### 需要修改的文件

#### `rawViewer/services/configLoader.swift`

修改 `load(for:)`：

从：

```swift
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

改为：

```swift
public func load(for folderUrl: URL) throws -> analysisConfig {
    if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
        return try load(from: bundleConfig)
    }
    return analysisConfig.defaults
}
```

`folderUrl` 在当前签名下会变成未使用参数。为了最小改动，可以保留签名并写成：

```swift
public func load(for folderUrl: URL) throws -> analysisConfig {
    _ = folderUrl
    if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
        return try load(from: bundleConfig)
    }
    return analysisConfig.defaults
}
```

这样不影响 `photoAnalysisService` 的调用点。

#### `rawViewer/config.yaml`

调整曝光参数为推荐值：

```yaml
exposure_detection:
  overexpose_pixel_threshold: 0.98
  underexpose_pixel_threshold: 0.02
  overexpose_ratio_limit: 0.10
  underexpose_ratio_limit: 0.15
```

并同步更新注释，说明参数已经放宽。

#### `rawViewer/services/analysisConfig.swift`

建议同步 `analysisConfig.defaults`，让兜底值与 `rawViewer/config.yaml` 一致：

```swift
overexposePixelThreshold: 0.98,
underexposePixelThreshold: 0.02,
overexposeRatioLimit: 0.10,
underexposeRatioLimit: 0.15
```

这样即使 bundle config 缺失，也不会回到旧的严格参数。

## 验证方案

### 1. 构建验证

使用 Xcode 或命令行构建，确认配置文件仍被打包进 app bundle。

建议命令：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

### 2. 清理旧分析缓存

因为 app 如果发现已有 `analysis.json` 会直接加载缓存，不会重新分析，所以必须删除旧结果：

```bash
rm -rf "$HOME/Library/Containers/Wilbur.pickpick/Data/Library/Application Support/rawViewer/D12EC2A6130AB943"
```

### 3. 重新分析

用 Xcode 运行 app，重新选择：

```text
/Users/wilbur/Downloads/test_bak2
```

等待重新分析完成。

### 4. 检查新 JSON

运行：

```bash
jq '.folderPath, .summary, .configSnapshot' \
"$HOME/Library/Containers/Wilbur.pickpick/Data/Library/Application Support/rawViewer/D12EC2A6130AB943/analysis.json"
```

期望：

1. `configSnapshot.exposure` 显示新参数：

```json
{
  "overexposePixelThreshold": 0.98,
  "underexposePixelThreshold": 0.02,
  "overexposeRatioLimit": 0.10,
  "underexposeRatioLimit": 0.15
}
```

2. `summary.normal` 应显著高于当前的 `7`。
3. `summary.underexposed` 应显著低于当前的 `147`。
4. `summary.overexposed` 应低于或接近当前的 `14`，但不应异常升高。

## 后续可选增强

如果下一轮仍需要精确调参，建议新增曝光诊断字段到 JSON：

```json
"exposureDiagnostics": {
  "overRatio": 0.0123,
  "underRatio": 0.0845,
  "overCount": 12345,
  "underCount": 67890,
  "totalPixels": 1000000,
  "overThreshold": 15992,
  "underThreshold": 828
}
```

有了这些字段后，就能直接统计不同阈值下的误判分布，而不是只能通过最终分类结果反推。

本轮不建议把诊断字段作为必要范围，因为用户当前要求是：

1. 参数先放宽。
2. 配置来源统一为编译进 app 的 `config.yaml`。

## 实施范围

本方案建议只做三处最小修改：

1. `configLoader.swift`：移除文件夹级 config 读取。
2. `config.yaml`：放宽曝光参数。
3. `analysisConfig.swift`：同步默认曝光参数。

不修改：

- 虚焦参数。
- 分析流程架构。
- JSON schema。
- UI 展示逻辑。
- duplicate 分组逻辑。

## 成功标准

1. app 不再读取照片文件夹内的 `config.yaml`。
2. `configSnapshot` 记录的新曝光参数来自 bundle config。
3. 删除旧缓存并重新分析 `test_bak2` 后，normal 数量明显增加，underexposed/overexposed 数量明显下降。
4. 旧 review 状态写入逻辑不受影响。
