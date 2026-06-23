# 综合曝光 / 模糊检测算法处理逻辑图

日期：2026-06-22  
状态：设计草稿  
目标：用“全局统计 + 网格区域统计 + 主因分类”替代当前单阈值曝光/模糊判断，减少 underexposed / blurry 误报。

## Mermaid 流程图

```mermaid
flowchart TD
    start([开始分析单张照片]) --> input{照片输入类型}

    input -->|有 RAW| rawPath[读取 RAW Bayer 数据]
    input -->|仅 JPG| jpgPath[读取 JPG 图像]
    input -->|RAW 失败且有 JPG| jpgFallback[使用 JPG fallback]

    rawPath --> rawPlane[生成 RAW 亮度平面\nGreen Plane / 线性亮度]
    jpgPath --> jpgPlane[生成 JPG 灰度平面\nsRGB Gray]
    jpgFallback --> jpgPlane

    rawPlane --> normalize[归一化亮度数据\nRAW: blackLevel/whiteLevel\nJPG: 0~255]
    jpgPlane --> normalize

    normalize --> downsample[降采样分析平面\n控制计算量，保持结构信息]

    downsample --> globalMetrics[计算全局指标]
    downsample --> gridSplit[切分 NxN 区域网格\n默认 5x5，可配置]
    downsample --> focusMask[生成有效清晰度区域\n排除极暗/极亮/低信息区域]

    globalMetrics --> g1[亮度分布\nmean / median / p01 / p05 / p10 / p90 / p99]
    globalMetrics --> g2[暗部/高光比例\ndarkRatio / deepDarkRatio / highlightRatio]
    globalMetrics --> g3[动态范围特征\nshadowLift / highlightHeadroom / tonalSpread]

    gridSplit --> tileLoop[逐 tile 计算指标]
    tileLoop --> t1[每格亮度\nmean / median / p10 / p90]
    tileLoop --> t2[每格暗部比例\ndarkRatio / deepDarkRatio]
    tileLoop --> t3[每格局部对比\nlocalContrast]
    tileLoop --> t4[每格清晰度\nLaplacian / gradient]

    t1 --> tileSummary[汇总区域分布]
    t2 --> tileSummary
    t3 --> tileSummary
    t4 --> tileSummary

    tileSummary --> ts1[暗 tile 数量与占比]
    tileSummary --> ts2[有效亮 tile 数量与占比]
    tileSummary --> ts3[中心区域亮度/对比]
    tileSummary --> ts4[边缘区域与中心差异]
    tileSummary --> ts5[清晰 tile 数量与占比]

    focusMask --> blurMetrics[计算清晰度指标]
    blurMetrics --> b1[全图 Laplacian]
    blurMetrics --> b2[中心区域 Laplacian]
    blurMetrics --> b3[有效曝光区域 Laplacian]
    blurMetrics --> b4[清晰 tile 占比]

    g1 --> exposureScore[计算曝光评分]
    g2 --> exposureScore
    g3 --> exposureScore
    ts1 --> exposureScore
    ts2 --> exposureScore
    ts3 --> exposureScore
    ts4 --> exposureScore

    b1 --> blurScore[计算模糊评分]
    b2 --> blurScore
    b3 --> blurScore
    b4 --> blurScore
    ts5 --> blurScore

    exposureScore --> underScore[underexposedScore]
    exposureScore --> overScore[overexposedScore]
    blurScore --> blurryScore[blurryScore]

    underScore --> decision[主因分类器]
    overScore --> decision
    blurryScore --> decision

    decision --> rule1{曝光问题是否强成立?}
    rule1 -->|underScore 高且整体左移| underPrimary[primaryIssue = underexposed]
    rule1 -->|overScore 高且高光大面积溢出| overPrimary[primaryIssue = overexposed]
    rule1 -->|否| rule2{模糊问题是否强成立?}

    rule2 -->|blurryScore 高且有效曝光区域也低清晰| blurryPrimary[primaryIssue = blurry]
    rule2 -->|否| normalPrimary[primaryIssue = normal]

    underPrimary --> result[输出分析结果]
    overPrimary --> result
    blurryPrimary --> result
    normalPrimary --> result

    result --> fields[写入 photoItem\nexposureStatus / isBlurry / analysisSource / dynamicRange]
    fields --> cache[保存 analysis.json\n含 configSnapshot]
    cache --> finish([结束])
```

## 关键判断原则

```mermaid
flowchart LR
    localDark[局部暗部多] --> notEnough{是否整体亮度左移?}
    notEnough -->|否| normal[不判 underexposed]
    notEnough -->|是| checkBright{是否缺少有效亮 tile?}
    checkBright -->|否| normal
    checkBright -->|是| checkCenter{中心区域是否也明显偏暗?}
    checkCenter -->|否| normal
    checkCenter -->|是| under[判 underexposed]

    lowLap[低 Laplacian] --> exposureBad{曝光是否严重不足?}
    exposureBad -->|是| underWins[优先判 underexposed\n降低 blurry 置信度]
    exposureBad -->|否| focusRegion{有效曝光区域是否也低清晰?}
    focusRegion -->|是| blurry[判 blurry]
    focusRegion -->|否| normal2[不判 blurry]
```

## 面向 0621 的验收逻辑

```mermaid
flowchart TD
    dataset[0621 样本集] --> positives[欠曝正例\nP1002511\nP1002538\nP1002539\nP1002552]
    dataset --> falsePositives[当前 underexposed 其余 13 张\n视为误报，应回到 normal]

    positives --> target1[必须判为 underexposed]
    positives --> target2[不再作为 blurry 主类出现]

    falsePositives --> target3[不得判为 underexposed]
    falsePositives --> target4[若无强模糊证据，应判 normal]

    target1 --> pass{验收通过?}
    target2 --> pass
    target3 --> pass
    target4 --> pass
```

## 设计备注

- 网格默认建议从 `5x5` 开始：比 `3x3` 更能区分局部阴影，又不会像 `8x8` 那样过度敏感。
- 曝光判定不再只看暗像素比例，而是要求多个条件共同成立：整体亮度偏低、有效亮区缺失、暗 tile 覆盖广、中心区域也偏暗。
- 模糊判定不再只看全图 Laplacian，而是在“有效曝光区域”里判断清晰度，避免欠曝照片因为低对比被误判 blurry。
- 最终输出仍兼容现有 UI 字段：`exposureStatus` 和 `isBlurry`，但内部增加评分与主因分类逻辑。
