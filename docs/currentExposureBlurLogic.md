# 当前欠曝/过曝与虚焦判断逻辑

## 范围

本文记录当前代码真实执行路径，用于确认曝光与虚焦判断是否符合预期。

涉及文件：

```text
rawViewer/services/photoAnalysisService.swift
rawViewer/services/rawBayerAnalyzer.swift
rawViewer/services/jpgAnalyzer.swift
rawViewer/metal/rawAnalysisShaders.metal
rawViewer/services/analysisConfig.swift
rawViewer/config.yaml
rawViewer/models/photoModels.swift
```

## 1. 总流程

```text
用户选择文件夹
    │
    ▼
photoAnalysisService.analyze(folderUrl:)
    │
    ├─ 1. configLoader.load(for: folderUrl)
    │       │
    │       ├─ 当前代码：优先读 照片文件夹/config.yaml
    │       ├─ 然后读 Bundle.main/config.yaml
    │       └─ 最后用 analysisConfig.defaults
    │
    ├─ 2. fileScanner.scanTopLevel(folderUrl)
    │       │
    │       └─ 扫描 RAW/JPG，生成 photoFilePair
    │
    ├─ 3. EXIF 读取拍摄时间
    │
    ├─ 4. 对每个 photoFilePair 做图像分析
    │       │
    │       ├─ 如果有 RAW
    │       │       │
    │       │       ├─ 优先 rawBayerAnalyzer.analyze(rawPath:)
    │       │       └─ 如果 RAW 分析失败，并且有 JPG，则 fallback 到 jpgAnalyzer
    │       │
    │       └─ 如果没有 RAW 但有 JPG
    │               │
    │               └─ jpgAnalyzer.analyze(jpgPath:)
    │
    ├─ 5. duplicateGrouper 做重复组
    │
    └─ 6. analysisStore.save(...)
            │
            └─ 写入 Application Support 里的 analysis.json
```

重点：当前 RAW 优先。只有 RAW 分析失败时，才用 JPG fallback。

## 2. 当前配置参数

当前 `rawViewer/config.yaml`：

```yaml
exposure_detection:
  overexpose_pixel_threshold: 0.96
  underexpose_pixel_threshold: 0.04
  overexpose_ratio_limit: 0.05
  underexpose_ratio_limit: 0.05

blur_detection:
  laplacian_threshold_raw: 5000.0
  laplacian_threshold_jpg: 10.0
```

含义：

```text
过曝：
  像素亮度超过 overexpose_pixel_threshold
  且这类像素占比超过 overexpose_ratio_limit
  => overexposed

欠曝：
  像素亮度低于 underexpose_pixel_threshold
  且这类像素占比超过 underexpose_ratio_limit
  => underexposed

虚焦：
  拉普拉斯方差 variance 小于 laplacian_threshold_xxx
  => blurry
```

当前严格程度：

```text
超过 5% 的像素很亮 => 过曝
超过 5% 的像素很暗 => 欠曝
```

## 3. RAW 曝光判断流程

### 3.1 RAW 过曝/欠曝流程图

```text
RAW 文件
  │
  ▼
LibRaw 打开 RAW
  │
  ├─ 读取 rawImage
  ├─ 读取 blackLevel
  ├─ 读取 whiteLevel
  ├─ 读取 visibleWidth / visibleHeight
  └─ 读取 visibleOffsetX / visibleOffsetY
  │
  ▼
计算绝对曝光阈值
  │
  ├─ overThreshold =
  │     blackLevel + (whiteLevel - blackLevel) * overexposePixelThreshold
  │
  └─ underThreshold =
        blackLevel + (whiteLevel - blackLevel) * underexposePixelThreshold
  │
  ▼
Metal: bayerHistogramKernel
  │
  ├─ 遍历 visible area 的每个 RAW 像素
  │
  ├─ 如果 rawValue >= overThreshold
  │       overCount += 1
  │
  └─ 如果 rawValue <= underThreshold 且 rawValue > 0
          underCount += 1
  │
  ▼
CPU 汇总 4 个 Bayer 通道的计数
  │
  ├─ overRatio = overCount / totalVisiblePixels
  └─ underRatio = underCount / totalVisiblePixels
  │
  ▼
最终曝光分类
  │
  ├─ if overRatio > overexposeRatioLimit
  │       exposureStatus = "overexposed"
  │
  ├─ else if underRatio > underexposeRatioLimit
  │       exposureStatus = "underexposed"
  │
  └─ else
          exposureStatus = "normal"
```

### 3.2 RAW 公式

代码位置：

```text
rawViewer/services/rawBayerAnalyzer.swift
```

当前 RAW 绝对阈值：

```swift
let absOver = UInt32(black) + UInt32(Double(white - black) * config.exposure.overexposePixelThreshold)
let absUnder = UInt32(black) + UInt32(Double(white - black) * config.exposure.underexposePixelThreshold)
```

假设：

```text
blackLevel = 512
whiteLevel = 16319
overexposePixelThreshold = 0.96
underexposePixelThreshold = 0.04
```

则：

```text
有效亮度范围 = 16319 - 512 = 15807

过曝阈值：
512 + 15807 * 0.96 ≈ 15686

欠曝阈值：
512 + 15807 * 0.04 ≈ 1144
```

所以 RAW 中：

```text
rawValue >= 15686       => 计为高亮像素
rawValue <= 1144 且 > 0 => 计为暗部像素
```

再按比例判断：

```text
高亮像素占比 > 5% => overexposed
暗部像素占比 > 5% => underexposed
```

### 3.3 RAW 曝光判断优先级

当前代码：

```swift
if overRatio > overexposeRatioLimit {
    exposureStatus = "overexposed"
} else if underRatio > underexposeRatioLimit {
    exposureStatus = "underexposed"
} else {
    exposureStatus = "normal"
}
```

含义：

```text
如果一张照片同时满足过曝和欠曝，当前代码会优先判定为 overexposed。
```

当前不会输出：

```text
both
highDynamicRange
mixedExposure
```

只会三选一：

```text
overexposed / underexposed / normal
```

## 4. JPG 曝光判断流程

### 4.1 JPG 过曝/欠曝流程图

```text
JPG 文件
  │
  ▼
CoreImage 读取 JPG
  │
  ▼
渲染到 RGBA8 Metal Texture
  │
  ▼
Metal: rgbToGrayKernel
  │
  └─ 每个像素转灰度：
      gray = R * 0.299 + G * 0.587 + B * 0.114
  │
  ▼
计算 JPG 绝对阈值
  │
  ├─ overThreshold = 255 * overexposePixelThreshold
  └─ underThreshold = 255 * underexposePixelThreshold
  │
  ▼
Metal: jpgHistogramKernel
  │
  ├─ 如果 gray > overThreshold
  │       overCount += 1
  │
  └─ 如果 gray < underThreshold
          underCount += 1
  │
  ▼
CPU 计算比例
  │
  ├─ overRatio = overCount / totalPixels
  └─ underRatio = underCount / totalPixels
  │
  ▼
最终曝光分类
  │
  ├─ if overRatio > overexposeRatioLimit
  │       exposureStatus = "overexposed"
  │
  ├─ else if underRatio > underexposeRatioLimit
  │       exposureStatus = "underexposed"
  │
  └─ else
          exposureStatus = "normal"
```

### 4.2 JPG 公式

代码位置：

```text
rawViewer/services/jpgAnalyzer.swift
rawViewer/metal/rawAnalysisShaders.metal
```

当前阈值：

```swift
let absOver = UInt32(Double(255) * config.exposure.overexposePixelThreshold)
let absUnder = UInt32(Double(255) * config.exposure.underexposePixelThreshold)
```

如果当前参数是：

```text
overexposePixelThreshold = 0.96
underexposePixelThreshold = 0.04
```

那么：

```text
overThreshold = 255 * 0.96 = 244.8 => UInt32 后为 244
underThreshold = 255 * 0.04 = 10.2 => UInt32 后为 10
```

Metal 实际判断：

```metal
if (gray > config.overThreshold) {
    overCount += 1;
}

if (gray < config.underThreshold) {
    underCount += 1;
}
```

所以 JPG 中实际是：

```text
gray > 244 => 高亮像素
gray < 10  => 暗部像素
```

再按比例判断：

```text
高亮像素占比 > 5% => overexposed
暗部像素占比 > 5% => underexposed
```

### 4.3 RAW 与 JPG 的边界差异

当前 RAW 和 JPG 的比较符号不完全一致：

```text
RAW：
  过曝：rawValue >= overThreshold
  欠曝：rawValue <= underThreshold 且 rawValue > 0

JPG：
  过曝：gray > overThreshold
  欠曝：gray < underThreshold
```

这通常影响不大，但如果需要规则完全一致，后续可以统一。

## 5. RAW 虚焦判断流程

### 5.1 RAW 虚焦流程图

```text
RAW 文件
  │
  ▼
LibRaw 读取 Bayer rawImage
  │
  ▼
取 visible area
  │
  ▼
Metal: bayerToGreenPlaneKernel
  │
  └─ 每个 2x2 Bayer block 取两个 Green 像素
      greenValue = (G1 - blackLevel + G2 - blackLevel) / 2
      如果低于 blackLevel，则 clamp 到 0
  │
  ▼
得到半分辨率 Green Plane
  │
  ▼
Metal: greenLaplacianKernel
  │
  └─ 对 Green Plane 做 4 邻域 Laplacian：
      laplacian = center * 4 - left - right - up - down
  │
  ▼
Metal: reduceLaplacianKernel
  │
  ├─ 统计 laplacian 总和 sum
  └─ 统计 laplacian 平方和 sumSq
  │
  ▼
CPU 计算方差
  │
  ├─ mean = sum / pixelCount
  └─ variance = sumSq / pixelCount - mean * mean
  │
  ▼
虚焦判断
  │
  ├─ if variance < laplacianThresholdRaw
  │       isBlurry = true
  │
  └─ else
          isBlurry = false
```

### 5.2 RAW 虚焦公式

当前 RAW 拉普拉斯公式：

```text
laplacian = center * 4 - left - right - up - down
```

注意：代码注释里写的是：

```text
Green Plane Laplacian (3x3, 边界 0 填充)
```

但实际代码不是完整 3x3，也不是边界 0 填充。

实际是：

```text
4 邻域 Laplacian
边界 clamp 到边缘像素
```

边界逻辑：

```metal
leftX = x == 0 ? 0 : x - 1
rightX = x + 1 >= width ? width - 1 : x + 1
upY = y == 0 ? 0 : y - 1
downY = y + 1 >= height ? height - 1 : y + 1
```

最终：

```text
variance < 5000 => RAW 虚焦
variance >= 5000 => RAW 不虚焦
```

## 6. JPG 虚焦判断流程

### 6.1 JPG 虚焦流程图

```text
JPG 文件
  │
  ▼
CoreImage 读取 JPG
  │
  ▼
渲染到 RGBA8 Metal Texture
  │
  ▼
Metal: rgbToGrayKernel
  │
  └─ gray = R * 0.299 + G * 0.587 + B * 0.114
  │
  ▼
Metal: jpgLaplacianKernel
  │
  └─ 对灰度图做 4 邻域 Laplacian：
      laplacian = center * 4 - left - right - up - down
  │
  ▼
Metal: reduceLaplacianKernel
  │
  ├─ 统计 laplacian 总和 sum
  └─ 统计 laplacian 平方和 sumSq
  │
  ▼
CPU 计算方差
  │
  ├─ mean = sum / pixelCount
  └─ variance = sumSq / pixelCount - mean * mean
  │
  ▼
虚焦判断
  │
  ├─ if variance < laplacianThresholdJpg
  │       isBlurry = true
  │
  └─ else
          isBlurry = false
```

### 6.2 JPG 虚焦公式

JPG 拉普拉斯公式与 RAW 一样：

```text
laplacian = center * 4 - left - right - up - down
```

不同的是输入：

```text
RAW 输入：半分辨率 Green Plane，值域大致是 RAW 原始强度减 blackLevel
JPG 输入：8-bit 灰度图，值域 0~255
```

所以阈值不同：

```text
RAW: variance < 5000 => blurry
JPG: variance < 10   => blurry
```

## 7. 曝光和虚焦之间的关系

当前逻辑里，曝光判断和虚焦判断是独立计算的。

一张照片可以同时是：

```text
underexposed + blurry
overexposed + not blurry
normal + blurry
```

最终 JSON 分别存：

```json
{
  "exposureStatus": "underexposed",
  "isBlurry": true
}
```

## 8. UI 分组展示逻辑

代码位置：

```text
rawViewer/models/photoModels.swift
```

分组顺序：

```text
1. overexposed
2. underexposed
3. blurry
4. normal
5. duplicate groups
```

重要条件：

```text
如果照片属于有效 duplicate group，
它不会进入 overexposed / underexposed / blurry / normal，
而是进入 duplicate group。
```

分组逻辑：

```text
visiblePhotos
  │
  ├─ 有效重复组照片 => duplicate group
  │
  ├─ exposureStatus == "overexposed" => overexposed
  │
  ├─ exposureStatus == "underexposed" => underexposed
  │
  ├─ isBlurry == true => blurry
  │
  └─ !isBlurry && exposureStatus == "normal" => normal
```

如果一张照片是：

```text
underexposed + blurry
```

且不在 duplicate group 里，那么它会先进入：

```text
underexposed
```

不会进入 blurry 组。

## 9. 当前逻辑可能不符合预期的地方

### 9.1 曝光判断偏粗暴

当前规则：

```text
只要超过 5% 的像素很暗，就判欠曝。
只要超过 5% 的像素很亮，就判过曝。
```

对正常照片可能太严格。例如一张正常人像、街景、室内照片，有 5% 阴影区域很常见，不一定代表欠曝。

### 9.2 没有区分“局部阴影”和“整体欠曝”

当前判断的是：

```text
暗部像素占比
```

不是：

```text
整体亮度偏低
```

因此容易把以下照片判为欠曝：

```text
主体曝光正常，但背景有大片黑色区域
夜景照片
舞台照
黑衣服/黑背景
阴影区域较多的照片
```

### 9.3 没有区分“局部高光”和“整体过曝”

当前判断的是：

```text
高亮像素占比
```

因此容易把以下照片判为过曝：

```text
天空
灯光
反光
白墙
阳光斑点
婚纱/白衣服
```

### 9.4 曝光状态只能三选一

当前只能输出：

```text
overexposed
underexposed
normal
```

如果一张照片既有死黑又有死白，当前会优先判：

```text
overexposed
```

不会表达：

```text
高动态范围
对比过强
同时过曝欠曝
```

### 9.5 虚焦判断是全图拉普拉斯方差

当前虚焦判断是：

```text
整张图的边缘强度方差
```

可能误判虚焦的情况：

```text
低纹理照片
纯色背景
天空
墙面
虚化背景占比大但主体清晰
浅景深照片
```

可能漏判虚焦的情况：

```text
高 ISO 噪点很多
锐化过度
纹理很多但主体没对上焦
```

## 10. 一句话总结

当前过曝/欠曝逻辑：

```text
数全图有多少像素落在极亮/极暗区域；超过配置比例就判过曝/欠曝。
```

当前虚焦逻辑：

```text
对全图做 4 邻域 Laplacian；计算 Laplacian 方差；方差低于阈值就判虚焦。
```

整体定位：

```text
当前算法更像“全图统计型快速筛选器”，不是严格摄影语义上的“主体曝光/主体对焦判断器”。
```
