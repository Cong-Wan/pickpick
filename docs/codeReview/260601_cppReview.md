# 代码审核报告 — cpp 模块全面审核

## 总览

- 审核范围：`cpp/` 下核心源码、头文件、配置、测试与 CMake；排除 `cpp/build/` 生成物。
- 核心文件：`main.cpp`、`src/*.cpp`、`src/*.mm`、`include/*.h`、`tests/*.cpp`、`CMakeLists.txt`、`config.yaml`。
- 验证结果：执行 `cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests`，构建成功，测试 13 个，失败 2 个。
- 发现问题：🔴 1 个 / 🟠 3 个 / 🟡 6 个 / 🔵 4 个。
- 整体评价：主流程分层清楚，扫描→JSON 状态→规划→RAW 转换→JPG 分析→JSON 落盘的数据流容易理解；但 GPU 分析路径当前与 CPU 结果明显不一致，且 `auto` backend 会在 Metal 成功时直接返回错误结果，是当前最需要修复的问题。

---

## 当前算法与实现方式

### 1. 文件扫描算法

**位置**：`cpp/src/fileScanner.cpp`

实现方式：
1. 只扫描输入目录顶层，不递归。
2. 对每个普通文件取 `stem` 作为 `photoId`。
3. 后缀匹配：`.jpg` / `.jpeg` 归为 JPG，`.rw2` / `.cr2` 归为 RAW，大小写不敏感。
4. 用 `std::map<std::string, PhotoPair>` 按 `photoId` 配对 JPG 与 RAW。
5. 输出前再按 `photoId` 排序。

输入输出：
- 输入：目录路径。
- 输出：`std::vector<PhotoPair>`，每项包含 `photoId`、`jpgPath`、`rawPath`、`hasJpg`、`hasRaw`。

是否用 GPU：否。

### 2. 配置读取与校验算法

**位置**：`cpp/src/configLoader.cpp`

实现方式：
1. 使用 `yaml-cpp` 读取 `config.yaml`。
2. 必填字段缺失直接抛异常。
3. 对数值字段做范围校验：拉普拉斯阈值、曝光阈值、曝光比例、JPG 质量。
4. 拉普拉斯核大小要求为正奇数。
5. 解析 `image_processing.analysis_backend` 与 `raw_backend`，只允许 `auto` / `cpu` / `metal`。
6. `thread_pool.worker_count` 被读取，但实际 `effectiveWorkerCount` 固定为 4。

输入输出：
- 输入：配置文件路径。
- 输出：`AppConfig`。

是否用 GPU：否，只读取是否选择 `metal`。

### 3. 断点续跑规划算法

**位置**：`cpp/src/resumePlanner.cpp`

实现方式：
1. 遍历 JSON 中的 `PhotoTaskState`。
2. RAW 转换任务规则：
   - 如果已有 JPG 和 RAW：跳过 RAW 转换，优先分析已有 JPG。
   - 如果没有 RAW：不做 RAW 转换。
   - 如果 RAW 状态为 `success` 或 `skipped`：不再转换。
   - 其他状态（`pending` / `running` / `failed`）进入 RAW 转换队列。
3. JPG 分析任务规则：
   - 如果分析状态为 `success`：跳过。
   - 如果没有 `jpgPath`：跳过。
   - 其他状态进入分析队列。

输入输出：
- 输入：`std::vector<PhotoTaskState>` 与 `AppConfig`。
- 输出：`PlannedTasks{rawConvertTasks, analyzeTasks}`。

是否用 GPU：否。

### 4. RAW 转 JPG 算法

**位置**：`cpp/src/rawConverter.cpp`

实现方式：
1. 检查 RAW 文件存在。
2. 确保输出 JPG 目录存在。
3. 用 `LibRaw::open_file()` 打开 RAW。
4. 用 `unpack()` 解包。
5. 用 `dcraw_process()` 做 RAW 显影处理。
6. 用 `dcraw_make_mem_image()` 得到内存图像。
7. 根据 `img->colors` 包装成 OpenCV `cv::Mat`：3 通道用 `CV_8UC3`，否则用 `CV_8UC1`。
8. 用 `cv::imwrite()` 按配置质量写 JPG。
9. 用 `dcraw_clear_mem()` 释放 LibRaw 图像内存。
10. 记录各阶段耗时。

输入输出：
- 输入：`RawConvertTask{photoId, rawPath, outputJpgPath}` 与 `AppConfig.rawConversion.jpgQuality`。
- 输出：`RawConvertResult`，包含成功状态、错误信息、JPG 路径与阶段耗时。

是否用 GPU：否。当前 `raw_backend` 配置没有被 RAW 转换路径使用。

### 5. CPU JPG 分析算法

**位置**：`cpp/src/imageAnalyzer.cpp`、`cpp/include/imageAnalysisCore.h`

实现方式：
1. `ImageAnalyzer::analyze()` 根据 backend 分发。
2. CPU 路径 `analyzeWithCpu()`：
   - `cv::imread(path, cv::IMREAD_COLOR)` 读取 JPG/图片。
   - `cv::cvtColor(img, gray, cv::COLOR_BGR2GRAY)` 转灰度。
   - 调用 `fillAnalyzeResultFromGray()`。
3. `fillAnalyzeResultFromGray()`：
   - `cv::Laplacian(gray, laplacian, CV_64F, ksize)` 计算拉普拉斯。
   - `cv::meanStdDev(laplacian)` 得到均值和标准差，方差 = `stddev^2`。
   - `cv::minMaxLoc(laplacian)` 得到拉普拉斯最小/最大值。
   - 遍历灰度图每个像素，累加 256-bin 直方图。
   - 灰度值 `> overexposePixelThreshold` 计入过曝像素。
   - 灰度值 `< underexposePixelThreshold` 计入欠曝像素。
   - 计算过曝/欠曝比例。
   - 如果过曝比例超过阈值，`exposureStatus = overexposed`；否则如果欠曝比例超过阈值，`underexposed`；否则 `normal`。
   - 如果拉普拉斯方差 `< laplacianThreshold`，判定 `isBlurry = true`。

输入输出：
- 输入：`AnalyzeTask{photoId, jpgPath}` 与分析配置。
- 输出：`AnalyzeResult`，包含模糊判断、曝光状态、拉普拉斯统计、直方图、backend 与耗时。

是否用 GPU：否，纯 OpenCV CPU 路径。

### 6. Metal/GPU JPG 分析算法

**位置**：`cpp/src/macImageAnalyzer.mm`、`cpp/src/gpuSupport.mm`

实现方式：
1. `getGpuSupport()` 调用 `MTLCreateSystemDefaultDevice()` 检测 Apple Metal 是否可用。
2. `analyzeWithMacMetal()` 只在 Apple 平台启用，非 Apple 返回失败。
3. 使用 Core Image 从文件创建 `CIImage`。
4. 创建 Metal 设备、Command Queue、Metal-backed `CIContext`。
5. 分配共享内存资源：
   - `grayTexture`：`RGBA8Unorm`，保存灰度结果。
   - `laplacianTexture`：`RGBA32Float`，保存拉普拉斯结果。
   - `meanVarTexture`：`2x1 RGBA32Float`，保存均值/方差。
   - `minMaxTexture`：`2x1 RGBA32Float`，保存最小/最大值。
   - `histogramBuffer`：256 个 `uint32_t` bin。
6. 灰度转换：
   - 使用 `CIColorMonochrome` 过滤器，设置颜色 `(0.299, 0.587, 0.114)` 与强度 `1.0`。
   - 用 Metal-backed `CIContext render:toMTLTexture` 渲染到 `grayTexture`。
7. 拉普拉斯：
   - 使用 `MPSImageConvolution`，3x3 kernel：中心 4，上下左右 -1。
   - 对 RGBA 4 个通道各自卷积。
8. 统计：
   - `MPSImageStatisticsMeanAndVariance` 统计拉普拉斯均值/方差。
   - `MPSImageStatisticsMinAndMax` 统计拉普拉斯最小/最大值。
9. 直方图：
   - `MPSImageHistogram` 对 `grayTexture` 统计 256 bins。
10. `commandBuffer commit` + `waitUntilCompleted`。
11. CPU readback：读取 4 个标量与 256-bin 直方图。
12. 根据直方图做曝光判断，根据方差做模糊判断。

输入输出：
- 输入：`AnalyzeTask` 与分析配置。
- 输出：`AnalyzeResult`，`backendUsed = metal`。

是否用 GPU：是。当前只有 JPG 分析的 Metal 路径使用 GPU；RAW 转换不使用 GPU。

### 7. Backend 调度算法

**位置**：`cpp/src/imageAnalyzer.cpp`

实现方式：
1. `analysis_backend = cpu`：强制 CPU。
2. `analysis_backend = metal`：强制 Metal，失败就返回失败。
3. `analysis_backend = auto`：
   - 如果机器没有 Metal：走 CPU。
   - 如果有 Metal：先走 Metal。
   - Metal 成功：直接返回 Metal 结果。
   - Metal 失败：回退 CPU。

是否用 GPU：当配置为 `metal` 或 `auto` 且 Metal 可用时，JPG 分析使用 GPU。

### 8. 线程池并发算法

**位置**：`cpp/include/threadPool.h`

实现方式：
1. 模板类 `ThreadPool<Task, Result>`。
2. 固定 4 个 worker。
3. 使用 `pthread_create()` 创建线程，并设置 8MB 栈。
4. 任务队列、结果队列分别用 mutex 保护。
5. worker 从任务队列取任务，调用 handler，结果压入结果队列。
6. `waitUntilFinished()` 等待任务队列为空且活动任务数为 0。
7. `stop()` 设置停止标记并 join 所有 worker。

输入输出：
- 输入：任务对象。
- 输出：结果对象。

是否用 GPU：线程池本身不用 GPU，但分析阶段多个 worker 可能并发调用 Metal 路径。

### 9. JSON 状态管理算法

**位置**：`cpp/src/jsonManager.cpp`

实现方式：
1. 初始化 `.cache/analysis.json`，不存在则创建根结构。
2. `mergeScannedPairs()` 将扫描结果合并进 JSON，不删除旧照片。
3. `markRunningAsPending()` 将上次中断的 running 状态回滚为 pending。
4. `updateRawConversionResult()` 写 RAW 转换状态、JPG 路径与错误信息。
5. `updateAnalysisResult()` 写分析状态、模糊/曝光结果、配置快照、拉普拉斯原始数据、直方图数据。
6. `updateSummary()` 每次更新后汇总统计。
7. `atomicSave()` 写临时文件再 `rename` 到最终 JSON。

是否用 GPU：否，只保存 GPU/CPU 分析后的结果，但当前 JSON 未记录 `backendUsed`。

### 10. 端到端主流程

**位置**：`cpp/src/appRunner.cpp`、`cpp/main.cpp`

数据流：

```text
命令行参数
  ↓
RunOptions(folderPath, configPath, resume)
  ↓
ConfigLoader.loadFromFile(config.yaml)
  ↓
FileScanner.scanTopLevel(folderPath)
  ↓
JsonManager.init + mergeScannedPairs + markRunningAsPending + atomicSave
  ↓
JsonManager.getAllPhotoStates
  ↓
ResumePlanner.plan
  ↓
RAW 转换阶段：ThreadPool<RawConvertTask, RawConvertResult>
  ↓
RawConverter.convert / convertWithRetry
  ↓
JsonManager.updateRawConversionResult + atomicSave + conversion.log
  ↓
重新读取 states 并重新 plan
  ↓
JPG 分析阶段：ThreadPool<AnalyzeTask, AnalyzeResult>
  ↓
ImageAnalyzer.analyze / analyzeWithRetry
  ↓
CPU OpenCV 或 Metal GPU 分析
  ↓
JsonManager.updateAnalysisResult + atomicSave + analysis.log
  ↓
JsonManager.getAllPhotoStates
  ↓
RunSummary 输出到 stdout
```

---

## 哪个算法使用了 GPU

当前只有 **JPG 分析算法的 Metal backend** 使用 GPU：

- 入口：`ImageAnalyzer::analyze()`。
- GPU 实现：`analyzeWithMacMetal()` in `cpp/src/macImageAnalyzer.mm`。
- GPU 能力检测：`getGpuSupport()` in `cpp/src/gpuSupport.mm`。
- 使用的 Apple GPU API：Metal、Core Image、MetalPerformanceShaders。
- GPU 处理阶段：灰度转换、拉普拉斯卷积、拉普拉斯统计、灰度直方图。
- CPU readback：最终只拉回均值、方差、最小值、最大值与 256-bin 直方图。

不使用 GPU 的部分：
- 文件扫描。
- YAML 配置解析。
- JSON 状态管理。
- 断点续跑规划。
- RAW 转 JPG（LibRaw + OpenCV CPU）。
- CPU JPG 分析路径。
- 线程池本身。

---

## 问题清单

### 🔴 Critical — Metal 分析结果与 CPU 严重不一致，`auto` 模式会返回错误分析结果

**位置**：`cpp/src/macImageAnalyzer.mm:199-345`、`cpp/src/imageAnalyzer.cpp:45-58`、`cpp/tests/imageAnalyzerBackendTests.cpp:68-112`

**问题**：测试已复现：CPU 判断 `normal`，Metal 判断 `underexposed`；CPU 过曝比例约 `0.034`、欠曝比例约 `0.036`，Metal 过曝比例 `0`、欠曝比例 `1`。拉普拉斯方差也从 CPU 的 `37087.4` 变成 Metal 的 `0.147517`。这说明 Metal 灰度/直方图/拉普拉斯至少有一个环节的数值尺度或通道读取不对。

由于 `auto` backend 在 Metal `success=true` 时直接返回 Metal 结果，用户默认配置 `analysis_backend: auto` 在 Apple + Metal 可用机器上会产生错误照片判定。

**修复方案**：
1. 先禁止 `auto` 返回未经校验的 Metal 结果，临时改为 CPU 默认或只在测试完全通过后启用 Metal。
2. 修正 Metal 灰度生成方式，不要用 `CIColorMonochrome` 误当线性灰度转换。它是单色调滤镜，不等价于 OpenCV `BGR2GRAY`。
3. 修正 MPS 输入像素尺度：`RGBA8Unorm` 进入 MPS 后通常是 0~1 归一化浮点，直方图范围和阈值也应对应 0~1，或者改为明确写入 0~255 float texture。
4. 增加白图、黑图、灰阶图、棋盘图的 CPU/Metal 对齐测试。

示例临时安全回退：

```cpp
AnalyzeResult ImageAnalyzer::analyze(const AnalyzeTask& task, const AppConfig& config) const {
    if (config.imageProcessing.analysisBackend == ImageBackend::Metal) {
        return analyzeWithMacMetal(task, config);
    }

    // 在 Metal 对齐测试全部通过前，auto 使用 CPU，避免默认路径产生错误结果。
    return analyzeWithCpu(task, config);
}
```

更长期方案：自定义 Metal compute shader 输出单通道 `R32Float` 或 `R8Unorm` 灰度，并保证 CPU/Metal 同一灰度公式、同一边界策略、同一数值尺度。

### 🟠 High — CPU 白图测试失败，默认 backend 在测试中走到了 Metal 路径

**位置**：`cpp/tests/imageAnalyzerTests.cpp:54-70`、`cpp/src/imageAnalyzer.cpp:41-58`

**问题**：`imageAnalyzer.detectsOverexposedWhiteImage` 期望 `bins[255] == 256`，实际失败。测试中的 `makeAnalyzerConfig()` 没有显式设置 `analysisBackend = Cpu`，默认是 `Auto`。在 Metal 可用机器上，该测试实际可能走 Metal，而 Metal 直方图当前错误，导致本应验证 CPU 逻辑的单元测试失败。

**修复方案**：测试中强制 CPU backend，让 CPU 单元测试稳定；Metal 对齐另放 backend 测试。

```cpp
static AppConfig makeAnalyzerConfig() {
    AppConfig config;
    // ... 原配置 ...
    config.imageProcessing.analysisBackend = ImageBackend::Cpu;
    return config;
}
```

### 🟠 High — Metal 路径忽略配置的 `laplacianKernelSize`

**位置**：`cpp/src/macImageAnalyzer.mm:33`、`cpp/src/macImageAnalyzer.mm:334`

**问题**：Metal 路径固定 `kLaplacianKernelSize = 3`，而 CPU 路径使用 `config.blurDetection.laplacianKernelSize`。当配置改为 5、7 等正奇数时，CPU/Metal 模糊结果不可比，JSON 中记录的 `kernelSize` 也不反映用户配置。

**修复方案**：
- 如果 Metal 只支持 3x3，则强制 `analysis_backend=metal` 时校验配置必须为 3，否则返回明确错误；`auto` 遇到非 3 时回退 CPU。
- 或实现按配置动态生成 MPS convolution weights。

```cpp
if (config.blurDetection.laplacianKernelSize != 3) {
    result.success = false;
    result.error = "Metal analyzer currently supports laplacian_kernel_size=3 only";
    return result;
}
```

### 🟠 High — 多 worker 并发 Metal 分析每张图重复创建 MTLDevice/CIContext/MPS 对象，性能和稳定性风险高

**位置**：`cpp/src/macImageAnalyzer.mm:183-280`、`cpp/include/threadPool.h:36-68`

**问题**：每张图片都会重新创建 Metal device、command queue、CIContext、MPS op。分析阶段固定 4 worker，并发执行时会频繁创建 GPU 资源，吞吐可能比 CPU 更差，也可能造成 autorelease 对象峰值内存升高。

**修复方案**：
- 至少在 `analyzeWithMacMetal()` 内增加 `@autoreleasepool` 包住 Objective-C 临时对象。
- 后续再考虑线程安全地复用 device/queue/CIContext，或限制 GPU backend worker 数。

```objective-c++
AnalyzeResult analyzeWithMacMetal(const AnalyzeTask& task, const AppConfig& config) {
#if defined(__APPLE__)
    @autoreleasepool {
        // 当前 Metal 实现主体
    }
#else
    // non-Apple fallback
#endif
}
```

### 🟡 Medium — `raw_backend` 配置被解析但没有任何执行效果

**位置**：`cpp/src/configLoader.cpp:94-96`、`cpp/include/taskState.h:56`、`cpp/src/rawConverter.cpp`

**问题**：配置文件提供 `image_processing.raw_backend`，注释写着 `cpu/metal/auto`，但 RAW 转换始终使用 LibRaw + OpenCV CPU 路径。用户如果配置 `raw_backend: metal`，程序不会报错也不会用 GPU，容易误导。

**修复方案**：当前没有 GPU RAW 转换实现时，限制 `raw_backend` 只能是 `cpu` 或 `auto`，并明确 `auto` 等价 CPU；如果是 `metal`，加载配置时报错。

### 🟡 Medium — `thread_pool.worker_count` 被读取但执行层固定 4，配置语义不一致

**位置**：`cpp/src/configLoader.cpp:87-89`、`cpp/include/threadPool.h:35`、`cpp/config.yaml:49-54`

**问题**：配置项存在，但 `ThreadPool::kWorkerCount` 固定为 4，`config.effectiveWorkerCount` 也固定为 4。虽然配置注释有说明，但代码上 `workerCount` 没有校验范围也没有实际传入线程池。

**修复方案**：二选一：
1. 删除或彻底忽略配置项，并在 schema/注释中说死固定 4。
2. 让 `ThreadPool` 构造函数接收 worker 数，并使用 `config.effectiveWorkerCount`。

### 🟡 Medium — RAW 转 JPG 对 LibRaw 输出色彩通道顺序和位深假设过强

**位置**：`cpp/src/rawConverter.cpp:62-68`

**问题**：代码按 `img->colors == 3` 直接包装 `CV_8UC3` 并写 JPG，但没有检查 `img->bits`、`img->type`、通道顺序。LibRaw 输出不一定总是 8-bit RGB；OpenCV `imwrite` 对 3 通道按 BGR 解释，可能导致颜色通道颠倒或高位深数据被错误解释。

**修复方案**：显式检查 `img->bits == 8` 与 `img->colors`，必要时转换位深和 RGB→BGR。

```cpp
if (img->bits != 8) {
    result.success = false;
    result.error = "Unsupported LibRaw output bit depth: " + std::to_string(img->bits);
    rawProcessor.dcraw_clear_mem(img);
    return result;
}

cv::Mat rgb(img->height, img->width, CV_8UC3, img->data);
cv::Mat bgr;
cv::cvtColor(rgb, bgr, cv::COLOR_RGB2BGR);
cv::imwrite(task.outputJpgPath, bgr, params);
```

### 🟡 Medium — JSON 没有保存 `backendUsed`，后续无法追踪某张图是 CPU 还是 Metal 分析

**位置**：`cpp/src/jsonManager.cpp:192-214`、`cpp/include/taskState.h:116`

**问题**：`AnalyzeResult` 有 `backendUsed`，日志也写了 backend，但 JSON 的 `analysis_raw_data` 和顶层 photo 状态没有保存 backend。后续排查 CPU/Metal 差异时，只看 `analysis.json` 无法知道结果来源。

**修复方案**：在 `updateAnalysisResult()` 成功分支写入字段，例如：

```cpp
p["analysis_backend"] = result.backendUsed;
```

失败分支也可写入尝试过的 backend，帮助排查。

### 🟡 Medium — `atomicSave()` 的 rename 跨文件系统和 Windows 语义不完全安全，且失败会留下 tmp

**位置**：`cpp/src/jsonManager.cpp:278-292`

**问题**：当前目标是 macOS/C++，同目录 rename 基本可用；但没有处理 `fs::rename` 异常，也没有在目标存在时做兼容处理。若写入或 rename 失败，调用方直接异常退出，tmp 文件可能残留。

**修复方案**：使用 `std::error_code` 捕获错误并给出明确错误；必要时先 remove 目标或使用平台原子替换 API。

### 🟡 Medium — `std::gmtime` 非线程安全，用在多线程扩展场景有隐患

**位置**：`cpp/src/jsonManager.cpp:20-24`、`cpp/src/appRunner.cpp:126-130`、`cpp/src/appRunner.cpp:192-196`

**问题**：`std::gmtime` 返回静态内部对象指针，非线程安全。目前主要在主线程写日志/JSON，风险不高；但如果后续把日志写入放到 worker，会产生数据竞争。

**修复方案**：macOS/Linux 使用 `gmtime_r`，Windows 使用 `gmtime_s`，封装一个 `utcNowTm()`。

### 🔵 Low — `FileScanner` 使用 `std::tolower(char)` 可能触发未定义行为

**位置**：`cpp/src/fileScanner.cpp:15-18`

**问题**：`std::tolower` 要求参数是 `unsigned char` 可表示值或 EOF。文件名包含非 ASCII 高位字符时，直接传 `char` 可能 UB。

**修复方案**：

```cpp
auto lower = [](char ch) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
};
```

### 🔵 Low — `AppRunner::run()` 中 running 状态标记代码是无效代码

**位置**：`cpp/src/appRunner.cpp:92-100`

**问题**：代码读取 `state` 并设置 `state.rawConversionStatus = Running`，但没有写回 `JsonManager`，注释也说明跳过。实际 JSON 中不会出现任务运行中状态，崩溃恢复只能依赖之前状态。

**修复方案**：要么删除这段无效代码和注释；要么给 `JsonManager` 增加 mark-running API，在提交任务前保存。

### 🔵 Low — `RunOptions.resume` 被解析但没有实际改变行为

**位置**：`cpp/main.cpp:19-27`、`cpp/src/appRunner.cpp:58-64`

**问题**：命令行支持 `--resume`，但 `AppRunner::run()` 无条件 merge 现有 JSON 并回滚 running 状态，`resume` 值没有被使用。用户无法理解带或不带 `--resume` 的区别。

**修复方案**：如果永远支持断点续跑，删除 `--resume`；如果需要非 resume 模式，则在 `resume=false` 时重建 `.cache/analysis.json` 或清理失败状态。

### 🔵 Low — 测试文件写到固定 `/tmp` 文件名，重复/并发测试可能互相覆盖

**位置**：`cpp/tests/imageAnalyzerTests.cpp:27-31`、`cpp/tests/imageAnalyzerBackendTests.cpp:36-39`

**问题**：测试使用固定文件名如 `rawviewer-white.png`、`rawviewer-backend-metal.jpg`。并发运行或上次异常退出时可能复用旧文件。

**修复方案**：加入进程 ID、时间戳或使用测试临时目录；测试结束后清理。

---

## 优点记录

1. 数据结构分层清楚：`Task`、`Result`、`State` 分离，便于测试和断点续跑。
2. CPU 分析核心 `fillAnalyzeResultFromGray()` 简洁直接，拉普拉斯、直方图、曝光判断逻辑清晰。
3. RAW 转换和 JPG 分析都记录了阶段耗时，便于后续性能优化。
4. 线程池显式设置 8MB 栈，说明项目已经处理过 macOS worker 栈不足问题。
5. backend 调度层保留了 CPU fallback，方向正确；只需要先保证 Metal 数值正确再默认启用。

---

## 修复优先级建议

1. **先修 Metal/CPU 不一致问题或暂时禁用 `auto` 使用 Metal**：这是当前默认配置下会影响分析正确性的核心问题。
2. **修测试配置，让 CPU 单测强制使用 CPU，并补齐 Metal 对齐测试**：避免测试名义上测 CPU、实际走 GPU。
3. **处理配置语义不一致**：`raw_backend`、`worker_count`、`laplacianKernelSize` 在 Metal 路径中的行为要么实现，要么明确拒绝。

---

## 本次验证记录

执行命令：

```bash
cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
```

结果：

```text
Tests run: 13, failures: 2
FAIL imageAnalyzer.detectsOverexposedWhiteImage
FAIL imageAnalyzerBackend.metalBackendMatchesCpuDecisionsWhenAvailable
```
