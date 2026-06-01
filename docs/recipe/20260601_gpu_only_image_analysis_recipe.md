# GPU-only 图片分析方案

## 背景

当前 `cpp/` 图片分析模块同时存在 CPU、auto、Metal 三种 backend。默认配置为 `auto`，在 Apple Metal 可用时会优先走 GPU。但现有 Metal 路径使用 Core Image + MPS 时存在隐式颜色空间、像素尺度和 histogram 范围问题，导致 GPU 结果与 CPU 基准明显不一致。

项目目标已经收窄为：**只支持 M 系列芯片 macOS**。因此产品运行路径不再需要 CPU/auto backend，也不需要兼容非 Apple 平台。

## 目标

1. 图片分析产品路径只允许使用 Metal/GPU。
2. 不再提供 CPU / auto 分析选项。
3. 修复 GPU 计算结果与 CPU reference 不一致的问题。
4. 图片像素级计算全部在 GPU 内连续完成。
5. 中间图像数据不 readback 到 CPU。
6. CPU 只读取最终聚合结果并生成业务判断。
7. 测试中允许保留 CPU reference，用于验证 GPU 正确性；CPU reference 不作为产品功能。

## 非目标

1. 不实现 RAW 转换 GPU 化。当前 RAW 转 JPG 仍使用 LibRaw + OpenCV CPU 路径。
2. 不支持 Intel Mac、Linux、Windows。
3. 不保留 CPU fallback。
4. 不继续依赖 MPS 处理核心数值逻辑，避免隐式尺度和通道语义。

## 核心设计

采用自定义 Metal compute shader 完成图片分析，Core Image 只负责将图片解码/渲染到 Metal texture。GPU pipeline 一次性完成灰度、Laplacian、直方图和统计归约，最后只 readback 小结果。

### GPU 内部数据流

```text
图片文件
  ↓
Core Image 解码 / 渲染到 rgbaTexture
  ↓
Metal kernel 1: RGB → Gray
  输出 grayBuffer 或 grayTexture，灰度范围固定为 0~255
  ↓
Metal kernel 2: Gray → Laplacian
  输出 laplacianBuffer
  ↓
Metal kernel 3: Histogram / Exposure Count
  输出 histogramBuffer[256]
  ↓
Metal kernel 4: Laplacian Reduction
  输出 statsBuffer(sum, sumSq, min, max)
  ↓
CPU readback:
  - histogramBuffer[256]
  - statsBuffer
  - totalPixels
  ↓
CPU 生成 AnalyzeResult
```

### 避免多次拷贝的原则

能在 GPU 上连续完成的计算必须在 GPU pipeline 内一次性完成。禁止将灰度图、Laplacian 图或其它中间图像 readback 到 CPU 后再传回 GPU。

错误模式：

```text
GPU 灰度
  ↓ readback
CPU 处理 / 再上传
  ↓
GPU Laplacian
  ↓ readback
CPU 处理 / 再上传
```

目标模式：

```text
GPU 灰度 → GPU Laplacian → GPU histogram/reduction → readback 小结果
```

这样可以减少 CPU/GPU 同步、减少内存传输，并避免性能被数据拷贝吞掉。

## 数值定义

### 灰度

GPU shader 显式实现灰度转换，不使用 `CIColorMonochrome`。

目标与 OpenCV `COLOR_BGR2GRAY` 的 8-bit 结果对齐：

```text
gray = round(0.299 * R + 0.587 * G + 0.114 * B)
```

灰度值 clamp 到 `[0, 255]`，并以整数 bin 语义进入 histogram。

### Laplacian

默认只支持 3x3 kernel：

```text
 0 -1  0
-1  4 -1
 0 -1  0
```

边界策略需要固定并与测试 reference 一致。优先使用 clamp-to-edge，避免未定义边界访问。

如果配置中 `laplacian_kernel_size != 3`，产品路径返回明确错误，或配置加载阶段直接拒绝。当前方案选择：**配置加载阶段只允许 3**。

### Histogram 与曝光

GPU 统计 256-bin histogram。

- 灰度值 `> overexposePixelThreshold` 计入过曝像素。
- 灰度值 `< underexposePixelThreshold` 计入欠曝像素。

曝光状态仍由 CPU 根据 GPU readback 的计数和比例生成：

```text
if overRatio > overexposeRatioLimit:
    overexposed
else if underRatio > underexposeRatioLimit:
    underexposed
else:
    normal
```

### Laplacian 统计

GPU 输出：

- `sum`
- `sumSq`
- `min`
- `max`

CPU 只做标量计算：

```text
mean = sum / totalPixels
variance = sumSq / totalPixels - mean * mean
stddev = sqrt(max(0, variance))
isBlurry = variance < laplacianThreshold
```

这不属于像素级图片分析，只是对 GPU 聚合结果做业务判断。

## 代码结构

### 新增文件

- `cpp/src/gpuImageKernels.metal`
  - `rgbToGrayKernel`
  - `laplacianKernel`
  - `histogramKernel`
  - `reduceLaplacianKernel`

### 修改文件

- `cpp/src/macImageAnalyzer.mm`
  - 创建 Metal library / compute pipelines。
  - 管理 GPU buffer / texture。
  - 调度 GPU-only pipeline。
  - readback histogram + stats。

- `cpp/src/imageAnalyzer.cpp`
  - 删除 CPU fallback / auto 调度。
  - `ImageAnalyzer::analyze()` 只调用 `analyzeWithMacMetal()`。

- `cpp/include/taskState.h`
  - 移除或弱化 `ImageBackend` 选择。
  - `AnalyzeResult.backendUsed` 默认改为 `metal`。

- `cpp/src/taskState.cpp`
  - 删除不再需要的 backend 字符串转换，或只允许 `metal`。

- `cpp/src/configLoader.cpp`
  - 不再接受 `cpu` / `auto` 分析 backend。
  - `laplacian_kernel_size` 只允许 3。

- `cpp/config.yaml`
  - 删除 `analysis_backend` 选择，或固定为 `metal`。
  - 注释说明 M 系列 macOS GPU-only。

- `cpp/CMakeLists.txt`
  - 将 `.metal` shader 纳入构建或运行时加载资源方案。

- `cpp/tests/imageAnalyzerTests.cpp`
  - 改为验证产品 GPU analyzer。
  - 测试黑图、白图、混合图、渐变图。

- `cpp/tests/imageAnalyzerBackendTests.cpp`
  - 删除 CPU/auto backend 行为测试。
  - 改为验证 GPU-only backend 和 GPU/CPU reference 对齐。

## 测试策略

产品代码不保留 CPU backend，但测试代码可以包含局部 CPU reference 函数。

测试流程：

```text
生成测试图片
  ↓
调用产品 GPU analyzer
  ↓
测试内 CPU reference 分析同一图片
  ↓
比较：
  - histogram bins
  - totalPixels
  - overexposePixelCount
  - underexposePixelCount
  - exposureStatus
  - laplacian mean
  - laplacian variance
  - laplacian min/max
  - isBlurry
```

测试图片：

1. 全黑图。
2. 全白图。
3. 黑白棋盘图。
4. 灰阶渐变图。
5. 当前 backend 渐变样例图。

允许浮点误差：

- histogram 和曝光计数必须完全一致。
- Laplacian mean / variance / min / max 允许极小浮点误差。
- `isBlurry` 和 `exposureStatus` 必须一致。

## 错误处理

1. 非 Apple 平台：构建阶段或运行阶段失败，错误明确说明只支持 M 系列 macOS。
2. Metal device 不可用：分析失败，错误明确说明 Metal GPU required。
3. shader library / pipeline 创建失败：分析失败并返回具体错误。
4. 图片解码失败：返回 `Core Image failed to read image`。
5. 配置中的 `laplacian_kernel_size != 3`：配置加载失败。

## 成功标准

1. 产品运行路径不存在 CPU/auto 图片分析选择。
2. `ImageAnalyzer::analyze()` 只调用 Metal analyzer。
3. GPU pipeline 不 readback 灰度图或 Laplacian 图等中间图像数据。
4. 只 readback histogram 和 Laplacian stats。
5. GPU 分析与测试内 CPU reference 对齐。
6. `rawViewerTests` 全部通过。
7. 默认配置在 M 系列 macOS 上直接使用 GPU 分析。

## 自检

- 无 TBD/TODO。
- 明确了只支持 M 系列 macOS。
- 明确 RAW 转换不在本次 GPU-only 范围内。
- 明确 CPU 只作为测试 reference，不作为产品运行 backend。
- 明确中间数据不 readback，只 readback 聚合结果。
- 明确 `laplacian_kernel_size` 当前只支持 3。
