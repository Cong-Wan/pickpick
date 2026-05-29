# Photo Analyzer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Photo Analyzer 技术方案落地为一个可在 macOS/Xcode 中构建、可断点续跑、可并发处理 RAW/JPG、并把分析结果即时持久化到 JSON 的 C++ 工具。

**Architecture:** 程序入口只做参数解析和流程调度；业务逻辑按模块放入 `cpp/include/` 与 `cpp/src/`。运行流程为：读取 `config.yaml` → 扫描顶层目录 → 合并/恢复 `.cache/analysis.json` → 固定 4 worker 执行 RAW 转 JPG → 固定 4 worker 执行 JPG 分析 → 主线程逐条即时原子写 JSON。

**Tech Stack:** C++17、Xcode、OpenCV、LibRaw、yaml-cpp、JSON C++ 库、`std::filesystem`、`std::thread`、`std::mutex`、`std::condition_variable`。

---

## 非协商约束

- 不包含任何版本控制相关命令或步骤。
- 不包含第三方库下载、安装、编译步骤；只引用项目根目录现有 `3rdPart/` 内容。
- 不新增 `CMakeLists.txt`、`build_deps.sh` 或其他脱离 Xcode 的构建入口。
- `cpp/main.cpp` 必须保留在 `cpp/` 根目录。
- 模块头文件必须放入 `cpp/include/`。
- 模块实现文件必须放入 `cpp/src/`。
- 配置必须使用 `config.yaml`，读取逻辑必须使用 yaml-cpp。
- 结果持久化必须使用 `<输入文件夹>/.cache/analysis.json`。
- RAW 转换和图像分析阶段都必须使用固定 4 个 worker 的共享队列模型，不允许按 4 张一批等待。
- worker 线程不得直接写 JSON；JSON 只能由主线程串行更新并原子保存。
- 每个转换或分析结果完成后必须立即保存 JSON，不允许等全部任务结束后统一保存。
- 失败任务必须在 worker 内立即重试一次，最多尝试 2 次。
- 上次遗留的 `running` 状态必须在启动恢复时当作 `pending` 重新处理。

---

## 文件结构总览

### 新建或修改的运行代码

| 路径 | 责任 |
| --- | --- |
| `config.yaml` | 运行参数配置，包含虚焦、曝光、RAW 输出质量和 worker 可见配置项，使用 YAML 注释解释参数意义。 |
| `cpp/main.cpp` | 程序入口；解析命令行；调用 `AppRunner`；输出摘要；不写业务细节。 |
| `cpp/include/taskState.h` | 定义状态枚举、照片状态、配置结构、任务结构、结果结构、字符串转换函数。 |
| `cpp/src/taskState.cpp` | 实现枚举和状态结构的字符串转换、默认值构造、状态归一化。 |
| `cpp/include/configLoader.h` | 声明 YAML 配置读取与校验接口。 |
| `cpp/src/configLoader.cpp` | 使用 yaml-cpp 读取 `config.yaml`，缺字段或非法值时抛出明确错误。 |
| `cpp/include/fileScanner.h` | 声明顶层目录扫描接口和 `PhotoPair` 结构。 |
| `cpp/src/fileScanner.cpp` | 扫描顶层 JPG/RW2/CR2，按 stem 配对，不递归。 |
| `cpp/include/jsonManager.h` | 声明 JSON 初始化、读取、合并、更新、summary 计算、原子保存接口。 |
| `cpp/src/jsonManager.cpp` | 实现 `.cache/analysis.json` 的完整读写和临时文件 rename 覆盖。 |
| `cpp/include/resumePlanner.h` | 声明基于 JSON 状态生成 RAW 转换队列和 JPG 分析队列的接口。 |
| `cpp/src/resumePlanner.cpp` | 实现断点续跑、失败重试、running 回滚、缺 JPG 标记失败的规划逻辑。 |
| `cpp/include/threadPool.h` | 实现模板化固定 4 worker 共享队列线程池；模板逻辑全部在头文件。 |
| `cpp/src/threadPool.cpp` | 保留文件头与非模板辅助函数；Xcode target 中加入该文件以保持模块结构一致。 |
| `cpp/include/rawConverter.h` | 声明 RAW 转 JPG 转换接口、转换任务和转换结果。 |
| `cpp/src/rawConverter.cpp` | 使用 LibRaw + OpenCV 将 RW2/CR2 转 JPG；worker 调用重试封装。 |
| `cpp/include/imageAnalyzer.h` | 声明 JPG 分析接口、拉普拉斯统计、直方图统计、分析结果结构。 |
| `cpp/src/imageAnalyzer.cpp` | 使用 OpenCV 读取 JPG，计算拉普拉斯统计和 256-bin 灰度直方图，生成配置快照。 |
| `cpp/include/appRunner.h` | 声明端到端流程编排器，允许测试注入 fake converter/analyzer。 |
| `cpp/src/appRunner.cpp` | 实现扫描、JSON 合并、两阶段线程池执行、即时 JSON 保存、最终摘要输出。 |

### 新建测试代码

| 路径 | 责任 |
| --- | --- |
| `cpp/tests/testMain.cpp` | 简单测试入口；执行所有测试用例并返回非 0 表示失败。 |
| `cpp/tests/testAssert.h` | 轻量断言宏，避免引入新测试框架。 |
| `cpp/tests/testUtils.h` | 临时目录、文件写入、JSON 读取、测试图像生成等工具。 |
| `cpp/tests/taskStateTests.cpp` | 状态字符串转换、默认状态、running 回滚测试。 |
| `cpp/tests/configLoaderTests.cpp` | YAML 成功读取、缺字段失败、非法范围失败测试。 |
| `cpp/tests/fileScannerTests.cpp` | 顶层扫描、大小写后缀、配对、不递归测试。 |
| `cpp/tests/jsonManagerTests.cpp` | JSON 创建、合并、状态更新、原子保存、summary 测试。 |
| `cpp/tests/resumePlannerTests.cpp` | RAW 转换队列、分析队列、failed/running 续跑规则测试。 |
| `cpp/tests/threadPoolTests.cpp` | 固定 4 worker、共享队列补位、不批处理、结果完整性测试。 |
| `cpp/tests/imageAnalyzerTests.cpp` | 清晰/模糊图、过曝/欠曝图、256-bin 直方图和配置快照测试。 |
| `cpp/tests/rawConverterTests.cpp` | 非法 RAW 失败、缺文件失败、可选真实 RAW 集成转换测试。 |
| `cpp/tests/appRunnerTests.cpp` | fake 转换/分析下的端到端流程、即时 JSON 写入、失败重试测试。 |

---

## Task 0: Environment Setup

**Goal:** 在已有项目根目录中确认 Xcode、目录、第三方库和基线构建状态可用；本任务不改业务代码，不执行任何版本控制操作。

**Files touched:** 无业务文件。允许创建缺失的空目录：`cpp/include/`、`cpp/src/`、`cpp/tests/`、`docs/flare/`。

### Step 1 — Verify workspace location

在项目根目录执行：

```bash
$ pwd
# Expected: 输出当前项目根目录的绝对路径

$ test -d rawViewer.xcodeproj && echo "OK rawViewer.xcodeproj"
# Expected: OK rawViewer.xcodeproj

$ test -d 3rdPart/json && echo "OK json"
# Expected: OK json

$ test -d 3rdPart/yaml && echo "OK yaml"
# Expected: OK yaml

$ test -d 3rdPart/opencv && echo "OK opencv"
# Expected: OK opencv

$ test -d 3rdPart/libraw && echo "OK libraw"
# Expected: OK libraw
```

如果任一命令没有输出对应 `OK ...`，停止执行计划，先补齐已有工程目录或第三方库目录。

### Step 2 — Verify Xcode CLI

```bash
$ xcodebuild -version
# Expected: 输出 Xcode 版本和 Build version
```

如果系统提示未安装命令行工具或 license 未接受，先在本机完成 Xcode CLI 配置，再继续。

### Step 3 — Create required source directories

```bash
$ mkdir -p cpp/include cpp/src cpp/tests docs/flare
# Expected: 无输出

$ test -d cpp/include && test -d cpp/src && test -d cpp/tests && test -d docs/flare && echo "OK directories"
# Expected: OK directories
```

### Step 4 — Baseline build

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

如果现有工程在未改代码前无法构建，停止执行计划，先修复工程基线构建问题。

✅ **Done when:** 目录检查、Xcode CLI 检查、目录创建和 Debug baseline build 全部通过。

---

## Task 1: Create config and module skeleton

**Goal:** 项目中存在完整的配置文件和模块文件骨架，且每个源文件位置符合目录规范。

**Files touched:**

- `config.yaml` — 写入可调参 YAML 配置。
- `cpp/main.cpp` — 保留入口骨架。
- `cpp/include/*.h` — 写入模块头文件骨架。
- `cpp/src/*.cpp` — 写入模块实现骨架。
- `cpp/tests/testMain.cpp` — 写入测试入口骨架。
- `cpp/tests/testAssert.h` — 写入轻量断言工具。

### Step 1 — Implement

1. 创建 `config.yaml`，内容必须包含以下字段和注释：
   - `blur_detection.laplacian_threshold: 100.0`
   - `blur_detection.laplacian_kernel_size: 3`
   - `exposure_detection.overexpose_pixel_threshold: 245`
   - `exposure_detection.underexpose_pixel_threshold: 10`
   - `exposure_detection.overexpose_ratio_limit: 0.05`
   - `exposure_detection.underexpose_ratio_limit: 0.05`
   - `raw_conversion.jpg_quality: 95`
   - `thread_pool.worker_count: 4`
2. 创建所有 `cpp/include/` 和 `cpp/src/` 文件，文件头统一为：

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: <替换为本文件实际职责，必须是一段中文描述>
 */
```

3. `cpp/main.cpp` 只包含：
   - `int main(int argc, char* argv[])`
   - 参数数量检查
   - `--config` 可选参数识别
   - 调用 `AppRunner` 的占位接口调用位置
   - 捕获 `std::exception` 并输出错误到 `std::cerr`
4. `cpp/tests/testAssert.h` 必须定义以下断言宏：
   - `TEST_ASSERT_TRUE(expr)`
   - `TEST_ASSERT_FALSE(expr)`
   - `TEST_ASSERT_EQ(a, b)`
   - `TEST_ASSERT_NE(a, b)`
   - `TEST_ASSERT_THROW(statement)`
5. `cpp/tests/testMain.cpp` 必须声明并调用后续测试函数名：
   - `runTaskStateTests()`
   - `runConfigLoaderTests()`
   - `runFileScannerTests()`
   - `runJsonManagerTests()`
   - `runResumePlannerTests()`
   - `runThreadPoolTests()`
   - `runImageAnalyzerTests()`
   - `runRawConverterTests()`
   - `runAppRunnerTests()`

### Step 2 — Write tests based on the plan goal

本任务只验证文件存在和配置字段存在；使用 shell 检查，不新增 C++ 单测。

```bash
$ test -f config.yaml && test -f cpp/main.cpp && test -f cpp/include/taskState.h && test -f cpp/src/taskState.cpp && echo "OK skeleton files"
# Expected: OK skeleton files

$ grep -q "laplacian_threshold: 100.0" config.yaml && grep -q "worker_count: 4" config.yaml && echo "OK config fields"
# Expected: OK config fields

$ test -f cpp/tests/testAssert.h && test -f cpp/tests/testMain.cpp && echo "OK test skeleton"
# Expected: OK test skeleton
```

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

如果构建失败，只修复本任务新增的骨架文件和 include 问题，不进入下一任务。

✅ **Done when:** skeleton 文件检查通过，配置字段检查通过，Xcode Debug 构建通过。

---

## Task 2: Implement persistent task state model

**Goal:** 程序能够稳定地在 C++ 状态枚举、字符串状态和默认照片状态之间转换，并能把遗留 `running` 归一化为 `pending`。

**Files touched:**

- `cpp/include/taskState.h` — 定义枚举、结构体和转换函数声明。
- `cpp/src/taskState.cpp` — 实现转换和默认值逻辑。
- `cpp/tests/taskStateTests.cpp` — 验证状态模型行为。

### Step 1 — Implement

`taskState` 必须包含：

1. 枚举：
   - `StageStatus { Pending, Running, Success, Failed, Skipped }`
   - `FailedStep { None, RawConversion, Analysis }`
2. 配置结构：
   - `BlurDetectionConfig`
   - `ExposureDetectionConfig`
   - `RawConversionConfig`
   - `ThreadPoolConfig`
   - `AppConfig`
3. 照片状态结构 `PhotoTaskState`，字段必须覆盖：
   - photo/file/raw 路径字段
   - raw conversion 状态、analysis 状态、failed step
   - attempts/error 字段
   - `isBlurry`、`exposureStatus`
   - 拉普拉斯统计字段
   - 256-bin 直方图原始计数字段
   - 曝光像素计数、比例、阈值字段
   - `createdAt`、`updatedAt`
4. 任务和结果结构：
   - `RawConvertTask`
   - `RawConvertResult`
   - `AnalyzeTask`
   - `AnalyzeResult`
5. 函数：
   - `std::string toString(StageStatus status)`
   - `std::string toString(FailedStep step)`
   - `StageStatus stageStatusFromString(const std::string& value)`
   - `FailedStep failedStepFromString(const std::string& value)`
   - `StageStatus normalizeForResume(StageStatus status)`
   - `PhotoTaskState makeDefaultPhotoState(const std::string& photoId)`

转换规则必须固定如下：

| C++ 枚举 | JSON 字符串 |
| --- | --- |
| `StageStatus::Pending` | `pending` |
| `StageStatus::Running` | `running` |
| `StageStatus::Success` | `success` |
| `StageStatus::Failed` | `failed` |
| `StageStatus::Skipped` | `skipped` |
| `FailedStep::None` | `none` |
| `FailedStep::RawConversion` | `raw_conversion` |
| `FailedStep::Analysis` | `analysis` |

非法字符串必须抛出 `std::invalid_argument`，错误消息包含非法原值。

### Step 2 — Write tests based on the plan goal

`cpp/tests/taskStateTests.cpp` 必须覆盖：

1. 所有枚举到字符串的转换。
2. 所有字符串到枚举的转换。
3. 非法 `StageStatus` 字符串抛异常。
4. 非法 `FailedStep` 字符串抛异常。
5. `normalizeForResume(StageStatus::Running)` 返回 `Pending`。
6. `normalizeForResume` 对 `Success`、`Failed`、`Skipped` 不改变。
7. `makeDefaultPhotoState("IMG_0001")` 生成：
   - `photoId == "IMG_0001"`
   - `rawConversionStatus == Pending`
   - `analysisStatus == Pending`
   - `failedStep == None`
   - attempts 为 `0`
   - error 字段为空
   - histogram bins 长度为 `256`

### Step 3 — Run tests and confirm all pass

将 `cpp/tests/taskStateTests.cpp` 加入测试 target 后运行：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/taskStateTests
# Expected: ** TEST SUCCEEDED **
```

如果工程暂时没有测试 scheme，先在 Xcode 新建 `rawViewerTests` Unit Test target，将 `cpp/tests/*.cpp` 和被测 `cpp/src/*.cpp` 加入该 target，再执行同一命令。

✅ **Done when:** `taskStateTests` 全部通过，且主程序 Debug 构建仍通过。

---

## Task 3: Implement YAML config loader

**Goal:** 程序启动时能够从 `config.yaml` 读取所有运行参数，缺字段或非法范围时立即报错退出，不使用隐藏默认值。

**Files touched:**

- `cpp/include/configLoader.h` — 声明 `ConfigLoader`。
- `cpp/src/configLoader.cpp` — 实现 yaml-cpp 读取与校验。
- `cpp/tests/configLoaderTests.cpp` — 验证成功和失败配置。

### Step 1 — Implement

`ConfigLoader` 必须提供：

```cpp
class ConfigLoader {
public:
    AppConfig loadFromFile(const std::string& configPath) const;
};
```

校验规则：

| 字段 | 合法值 |
| --- | --- |
| `blur_detection.laplacian_threshold` | number，必须 `> 0` |
| `blur_detection.laplacian_kernel_size` | int，必须为正奇数 |
| `exposure_detection.overexpose_pixel_threshold` | int，必须在 `0..255` |
| `exposure_detection.underexpose_pixel_threshold` | int，必须在 `0..255` |
| `exposure_detection.overexpose_ratio_limit` | number，必须在 `[0, 1]` |
| `exposure_detection.underexpose_ratio_limit` | number，必须在 `[0, 1]` |
| `raw_conversion.jpg_quality` | int，必须在 `0..100` |
| `thread_pool.worker_count` | int，必须存在；运行层固定用 4，即使配置不是 4 也要在日志中提示，并在 `AppConfig.effectiveWorkerCount` 写入 4 |

错误消息必须包含字段路径，例如 `Missing config field: blur_detection.laplacian_threshold` 或 `Invalid config field: raw_conversion.jpg_quality`。

### Step 2 — Write tests based on the plan goal

`cpp/tests/configLoaderTests.cpp` 必须创建临时 YAML 文件并覆盖：

1. 完整合法配置读取成功，字段值准确。
2. 缺少 `blur_detection.laplacian_threshold` 抛异常。
3. `laplacian_kernel_size: 4` 抛异常。
4. `overexpose_pixel_threshold: 300` 抛异常。
5. `underexpose_ratio_limit: 1.5` 抛异常。
6. `thread_pool.worker_count: 8` 不抛异常，但 `effectiveWorkerCount == 4`。
7. 配置路径不存在时抛异常，错误消息包含路径。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/configLoaderTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 合法配置、缺字段、非法范围、worker 固定 4 的测试全部通过。

---

## Task 4: Implement top-level file scanner

**Goal:** 程序能够只扫描输入目录顶层，将 `.jpg/.JPG/.rw2/.RW2/.cr2/.CR2` 按 stem 精确配对，并忽略子目录内容。

**Files touched:**

- `cpp/include/fileScanner.h` — 声明 `PhotoPair` 和 `FileScanner`。
- `cpp/src/fileScanner.cpp` — 实现扫描配对逻辑。
- `cpp/tests/fileScannerTests.cpp` — 验证扫描结果。

### Step 1 — Implement

`FileScanner` 必须提供：

```cpp
class FileScanner {
public:
    std::vector<PhotoPair> scanTopLevel(const std::string& folderPath) const;
};
```

实现规则：

1. 只使用 `std::filesystem::directory_iterator`，不得使用递归 iterator。
2. 支持 JPG 后缀：`.jpg`、`.JPG`、`.jpeg`、`.JPEG`。
3. 支持 RAW 后缀：`.rw2`、`.RW2`、`.cr2`、`.CR2`。
4. `photoId` 使用文件 stem，保持原始大小写。
5. 若同一 stem 有 JPG 和 RAW：`hasJpg=true`、`hasRaw=true`。
6. 若只有 JPG：`hasJpg=true`、`hasRaw=false`。
7. 若只有 RAW：`hasJpg=false`、`hasRaw=true`，`jpgPath` 为空。
8. 非图片文件必须忽略。
9. 输入目录不存在或不是目录时抛 `std::runtime_error`。
10. 输出按 `photoId` 升序排序，保证测试和 JSON 写入稳定。

### Step 2 — Write tests based on the plan goal

`cpp/tests/fileScannerTests.cpp` 必须用临时目录覆盖：

1. `IMG_0001.JPG + IMG_0001.CR2` 产生一个 paired 记录。
2. `IMG_0002.jpg` 产生 jpg-only 记录。
3. `IMG_0003.RW2` 产生 raw-only 记录。
4. `notes.txt` 被忽略。
5. `sub/IMG_9999.JPG` 被忽略。
6. 不存在目录抛异常。
7. 输出按 `photoId` 排序。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/fileScannerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** scanner 单测全部通过，且不存在任何递归扫描行为。

---

## Task 5: Implement JSON manager and atomic persistence

**Goal:** 程序能够读取或创建 `.cache/analysis.json`，合并扫描结果，更新照片状态，并通过临时文件 + rename 方式原子保存完整 JSON。

**Files touched:**

- `cpp/include/jsonManager.h` — 声明 `JsonManager`。
- `cpp/src/jsonManager.cpp` — 实现 JSON 读写、合并、更新、summary。
- `cpp/tests/jsonManagerTests.cpp` — 验证 JSON 行为。

### Step 1 — Implement

`JsonManager` 必须提供：

```cpp
class JsonManager {
public:
    void init(const std::string& folderPath, const std::string& configPath);
    void mergeScannedPairs(const std::vector<PhotoPair>& pairs);
    void markRunningAsPending();
    void updateRawConversionResult(const RawConvertResult& result);
    void updateAnalysisResult(const AnalyzeResult& result);
    std::vector<PhotoTaskState> getAllPhotoStates() const;
    PhotoTaskState getPhotoState(const std::string& photoId) const;
    void atomicSave();
    std::string jsonPath() const;
};
```

JSON 顶层必须写入：

- `schema_version: "1.3"`
- `folder_path`
- `config_path`
- `created_at`
- `updated_at`
- `max_workers: 4`
- `summary`
- `photos`

合并规则：

1. 新照片创建记录。
2. 已存在照片保留已有状态和分析结果。
3. 已存在照片的路径变化时更新路径字段。
4. 有原始 JPG 的照片 `raw_conversion_status` 必须为 `skipped`。
5. 只有 RAW 的照片初始 `raw_conversion_status` 为 `pending`、`analysis_status` 为 `pending`。
6. `photos` 必须以 `photo_id` 为 key，不使用数组。

原子保存规则：

1. 确保 `<folder>/.cache/` 存在。
2. 写入 `<folder>/.cache/analysis.json.tmp`。
3. flush 并关闭临时文件。
4. 使用 `std::filesystem::rename(tmp, final)` 覆盖正式文件。
5. 保存完成后不得留下 `.tmp` 文件。

结果更新规则：

- RAW 成功：
  - `raw_conversion_status = "success"`
  - `raw_converted = true`
  - `file_path` 指向转换后 JPG
  - `failed_step = "none"`
  - `raw_conversion_error = null`
  - `raw_conversion_attempts` 写入实际次数
- RAW 失败：
  - `raw_conversion_status = "failed"`
  - `failed_step = "raw_conversion"`
  - `raw_conversion_attempts = 2`
  - `raw_conversion_error` 写入错误
- 分析成功：
  - `analysis_status = "success"`
  - `failed_step = "none"`
  - 写入 `is_blurry`
  - 写入 `exposure_status`
  - 写入 `analysis_config_snapshot`
  - 写入 `analysis_raw_data.laplacian`
  - 写入 `analysis_raw_data.histogram.bins`，长度必须为 256
- 分析失败：
  - `analysis_status = "failed"`
  - `failed_step = "analysis"`
  - `analysis_attempts = 2`
  - `analysis_error` 写入错误

### Step 2 — Write tests based on the plan goal

`cpp/tests/jsonManagerTests.cpp` 必须覆盖：

1. 不存在 JSON 时自动创建 `.cache/analysis.json`。
2. 新扫描结果合并后 `photos` 使用 stem 作为 key。
3. 原始 JPG 记录的 `raw_conversion_status == skipped`。
4. RAW-only 记录的 `raw_conversion_status == pending`。
5. 已有成功分析记录再次 merge 不丢失 `analysis_raw_data`。
6. `markRunningAsPending()` 将 raw 和 analysis 的 `running` 改为 `pending`。
7. RAW 成功更新后立即保存，重新读取文件能看到 success。
8. 分析成功写入 256 个 histogram bins。
9. `.cache/analysis.json.tmp` 不残留。
10. summary 中 `total_photos`、`analysis_success`、`raw_conversion_failed`、`blurry`、`normal` 数量正确。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/jsonManagerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** JSON 创建、合并、更新、原子保存、summary 测试全部通过。

---

## Task 6: Implement resume planner

**Goal:** 程序能够根据当前 JSON 状态生成本次 RAW 转换队列和 JPG 分析队列，准确跳过 success/skipped，并重新处理 pending/failed/running。

**Files touched:**

- `cpp/include/resumePlanner.h` — 声明规划接口。
- `cpp/src/resumePlanner.cpp` — 实现规划逻辑。
- `cpp/tests/resumePlannerTests.cpp` — 验证规划规则。

### Step 1 — Implement

`ResumePlanner` 必须提供：

```cpp
struct PlannedTasks {
    std::vector<RawConvertTask> rawConvertTasks;
    std::vector<AnalyzeTask> analyzeTasks;
};

class ResumePlanner {
public:
    PlannedTasks plan(const std::vector<PhotoTaskState>& states, const AppConfig& config) const;
};
```

RAW 转换队列规则：

| 条件 | 是否进入 RAW 转换队列 |
| --- | --- |
| 有原始 JPG | 否 |
| 无 RAW | 否 |
| `rawConversionStatus == Success` | 否 |
| `rawConversionStatus == Skipped` | 否 |
| `rawConversionStatus == Pending` | 是 |
| `rawConversionStatus == Running` | 是 |
| `rawConversionStatus == Failed` | 是 |

分析队列规则：

| 条件 | 是否进入分析队列 |
| --- | --- |
| `analysisStatus == Success` | 否 |
| `analysisStatus == Pending` | 是，前提是 JPG 路径存在 |
| `analysisStatus == Running` | 是，前提是 JPG 路径存在 |
| `analysisStatus == Failed` | 是，前提是 JPG 路径存在 |
| RAW 转换失败且没有 JPG | 否 |
| `jpgPath` 为空 | 否 |

转换后 JPG 输出路径规则：

```text
<输入文件夹>/.cache/converted/<photoId>.JPG
```

### Step 2 — Write tests based on the plan goal

`cpp/tests/resumePlannerTests.cpp` 必须覆盖：

1. 原始 JPG 的照片不进入 RAW 队列，但进入分析队列。
2. RAW-only pending 进入 RAW 队列，不进入分析队列。
3. RAW success 且有转换 JPG 进入分析队列。
4. analysis success 不进入分析队列。
5. failed raw conversion 重新进入 RAW 队列。
6. running analysis 且 JPG 存在重新进入分析队列。
7. RAW 失败且没有 JPG 不进入分析队列。
8. 转换输出路径固定到 `.cache/converted/<photoId>.JPG`。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/resumePlannerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 所有断点续跑队列规划测试通过。

---

## Task 7: Implement fixed four-worker thread pool

**Goal:** 线程池在每个阶段始终使用固定 4 个 worker 从共享队列持续取任务，任意 worker 完成后立即处理下一项，不按批次等待。

**Files touched:**

- `cpp/include/threadPool.h` — 实现模板线程池。
- `cpp/src/threadPool.cpp` — 保留模块实现文件。
- `cpp/tests/threadPoolTests.cpp` — 验证并发模型。

### Step 1 — Implement

`ThreadPool<Task, Result>` 必须提供：

```cpp
template <typename Task, typename Result>
class ThreadPool {
public:
    using TaskHandler = std::function<Result(const Task&)>;

    explicit ThreadPool(TaskHandler handler);
    ~ThreadPool();

    void pushTask(const Task& task);
    bool tryPopResult(Result& result);
    Result waitPopResult();
    void waitUntilFinished();
    void stop();
};
```

实现规则：

1. 构造函数固定创建 4 个 worker 线程。
2. worker 从同一个 `std::queue<Task>` 取任务。
3. worker 完成任务后把 `Result` 推入结果队列。
4. worker 完成当前任务后立即回到任务队列取下一项。
5. 不允许按固定批次切分任务。
6. `waitUntilFinished()` 必须等待所有已提交任务完成。
7. `stop()` 必须通知所有 worker 退出并 join。
8. 析构函数必须调用 `stop()`，且可重复调用不崩溃。
9. handler 抛异常时，线程池不得崩溃；Result 类型必须支持在 handler 内部捕获异常后返回失败结果。本线程池不吞异常，不直接构造失败结果。
10. 线程池不写 JSON，不感知业务状态。

### Step 2 — Write tests based on the plan goal

`cpp/tests/threadPoolTests.cpp` 必须覆盖：

1. 提交 10 个任务，最终拿到 10 个结果。
2. 同时活跃任务数量最大值不超过 4。
3. 通过任务耗时设计证明不是批处理：
   - 任务 1 耗时 200ms
   - 任务 2、3、4 耗时 20ms
   - 任务 5 耗时 20ms
   - 若共享队列正常，任务 5 应在任务 1 完成前开始
4. `stop()` 调用两次不崩溃。
5. 任务数量少于 4 时也能正常完成。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/threadPoolTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 并发数量、共享队列补位和结果完整性测试全部通过。

---

## Task 8: Implement image analyzer

**Goal:** 程序能够读取 JPG，基于 config 计算虚焦和曝光状态，并返回配置快照、拉普拉斯统计和完整 256-bin 灰度直方图。

**Files touched:**

- `cpp/include/imageAnalyzer.h` — 声明分析接口和统计结构。
- `cpp/src/imageAnalyzer.cpp` — 实现 OpenCV 分析逻辑。
- `cpp/tests/imageAnalyzerTests.cpp` — 验证图像分析结果。

### Step 1 — Implement

`ImageAnalyzer` 必须提供：

```cpp
class ImageAnalyzer {
public:
    AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) const;
};
```

计算规则：

1. 使用 `cv::imread(jpgPath, cv::IMREAD_COLOR)` 读取 JPG。
2. 读取失败时返回失败结果，`attempts` 由重试封装写入。
3. 使用 `cv::cvtColor` 转灰度。
4. 使用 `cv::Laplacian(gray, laplacian, CV_64F, laplacianKernelSize)` 计算拉普拉斯。
5. 使用 `cv::meanStdDev` 得到 mean/stddev。
6. 使用 `cv::minMaxLoc` 得到 min/max。
7. `variance = stddev * stddev`。
8. `isBlurry = variance < config.blurDetection.laplacianThreshold`。
9. 使用 OpenCV 或手写循环计算 256-bin 灰度直方图；bin 索引必须是亮度值 `0..255`。
10. `overexposePixelCount` 统计 `gray > overexpose_pixel_threshold`。
11. `underexposePixelCount` 统计 `gray < underexpose_pixel_threshold`。
12. `overexposeRatio = overexposePixelCount / totalPixels`。
13. `underexposeRatio = underexposePixelCount / totalPixels`。
14. 曝光判断优先级固定：
    - 如果 `overexposeRatio > overexposeRatioLimit`，返回 `overexposed`
    - 否则如果 `underexposeRatio > underexposeRatioLimit`，返回 `underexposed`
    - 否则返回 `normal`
15. 成功结果必须包含：
    - `analysis_config_snapshot`
    - `analysis_raw_data.laplacian.variance/mean/stddev/min/max/kernel_size`
    - `analysis_raw_data.histogram.bin_count = 256`
    - `analysis_raw_data.histogram.bins` 长度 256
    - `total_pixels`
    - 过曝/欠曝像素数量和比例

### Step 2 — Write tests based on the plan goal

`cpp/tests/imageAnalyzerTests.cpp` 必须生成临时 JPG 并覆盖：

1. 全白图：`exposure_status == overexposed`。
2. 全黑图：`exposure_status == underexposed`。
3. 中灰图：`exposure_status == normal`。
4. 人工边缘图的拉普拉斯方差高于纯灰图。
5. histogram bins 长度为 256。
6. histogram bins 总和等于 `total_pixels`。
7. config snapshot 中阈值等于传入配置。
8. 不存在 JPG 返回失败结果，错误消息包含路径。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/imageAnalyzerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 虚焦、曝光、直方图、配置快照和失败路径测试全部通过。

---

## Task 9: Implement RAW converter

**Goal:** 程序能够使用 LibRaw 读取 `.RW2/.CR2` 并用 OpenCV 保存 JPG，失败时返回明确错误，不直接写 JSON。

**Files touched:**

- `cpp/include/rawConverter.h` — 声明转换接口。
- `cpp/src/rawConverter.cpp` — 实现 LibRaw + OpenCV 转换。
- `cpp/tests/rawConverterTests.cpp` — 验证转换失败和可选真实 RAW 成功路径。

### Step 1 — Implement

`RawConverter` 必须提供：

```cpp
class RawConverter {
public:
    RawConvertResult convert(const RawConvertTask& task, const AppConfig& config) const;
};
```

实现规则：

1. 每次 `convert` 调用内部独立创建 `LibRaw rawProcessor;`。
2. 输入 RAW 文件不存在时返回失败结果，不抛出未捕获异常。
3. 输出目录不存在时先创建目录。
4. 使用 LibRaw 打开、解包、处理图像。
5. 把 LibRaw 输出转换为 OpenCV `cv::Mat`。
6. 使用 `cv::imwrite(outputJpgPath, mat, {cv::IMWRITE_JPEG_QUALITY, jpgQuality})` 保存 JPG。
7. 成功时返回：
   - `success = true`
   - `photoId`
   - `rawPath`
   - `jpgPath`
   - `attempts = 1`，由外层重试封装最终修正
   - `error` 为空
8. 失败时返回：
   - `success = false`
   - `attempts = 1`，由外层重试封装最终修正
   - `error` 包含 LibRaw 或 OpenCV 失败原因
9. `RawConverter` 不知道 JSON，不写 `.cache/analysis.json`。

### Step 2 — Write tests based on the plan goal

`cpp/tests/rawConverterTests.cpp` 必须覆盖：

1. 不存在 RAW 文件返回失败，错误消息包含路径。
2. 损坏 RAW 文件返回失败，不生成 JPG。
3. 输出目录不存在时，转换前创建目录；该用例可用损坏 RAW 验证目录创建。
4. 如果本机存在 `cpp/tests/fixtures/raw/sample_valid.RW2` 或 `cpp/tests/fixtures/raw/sample_valid.CR2`，执行真实转换并断言输出 JPG 存在且 `cv::imread` 可读取。
5. 如果真实 RAW fixture 不存在，真实转换用例打印 `SKIP real RAW fixture`，但前三个失败路径测试必须通过。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/rawConverterTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 缺文件、损坏文件、输出目录创建测试通过；若存在真实 RAW fixture，真实转换测试也必须通过。

---

## Task 10: Implement retry wrappers

**Goal:** RAW 转换和图像分析失败时会在 worker 内立即重试一次，最终结果准确记录 attempts 和最后一次错误。

**Files touched:**

- `cpp/include/appRunner.h` — 声明重试辅助函数或 runner 私有方法。
- `cpp/src/appRunner.cpp` — 实现 RAW 和分析的最多 2 次重试。
- `cpp/tests/appRunnerTests.cpp` — 增加重试行为测试。

### Step 1 — Implement

在 `AppRunner` 中实现两个 helper：

```cpp
RawConvertResult convertWithRetry(const RawConvertTask& task, const AppConfig& config);
AnalyzeResult analyzeWithRetry(const AnalyzeTask& task, const AppConfig& config);
```

规则：

1. 第一次成功：返回 success，`attempts = 1`。
2. 第一次失败、第二次成功：返回 success，`attempts = 2`，error 为空。
3. 两次失败：返回 failed，`attempts = 2`，error 使用第二次失败错误。
4. 重试发生在 worker 内部，不回到主线程再重新入队。
5. 重试 helper 不写 JSON。

为了可测性，`AppRunner` 构造函数必须允许注入 fake converter 和 fake analyzer：

```cpp
using RawConvertFn = std::function<RawConvertResult(const RawConvertTask&, const AppConfig&)>;
using AnalyzeFn = std::function<AnalyzeResult(const AnalyzeTask&, const AppConfig&)>;
```

默认构造使用真实 `RawConverter` 和 `ImageAnalyzer`。

### Step 2 — Write tests based on the plan goal

`cpp/tests/appRunnerTests.cpp` 中必须新增：

1. fake converter 第一次失败第二次成功，最终 `success=true`、`attempts=2`。
2. fake converter 两次失败，最终 `success=false`、`attempts=2`、error 等于第二次错误。
3. fake analyzer 第一次成功，最终 `attempts=1`。
4. fake analyzer 两次失败，最终 `success=false`、`attempts=2`。
5. 验证 fake 调用次数最多为 2。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/appRunnerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** RAW 和分析重试行为全部通过，且失败结果保留第二次错误。

---

## Task 11: Implement AppRunner orchestration and immediate JSON writes

**Goal:** 程序能够端到端执行扫描、恢复、RAW 转换、图像分析和 summary 输出，并在每个任务完成后由主线程立即保存 JSON。

**Files touched:**

- `cpp/include/appRunner.h` — 声明 `AppRunner::run`。
- `cpp/src/appRunner.cpp` — 实现端到端流程。
- `cpp/main.cpp` — 调用 `AppRunner::run`。
- `cpp/tests/appRunnerTests.cpp` — 验证流程编排。

### Step 1 — Implement

`AppRunner` 必须提供：

```cpp
struct RunOptions {
    std::string folderPath;
    std::string configPath;
    bool resume;
};

struct RunSummary {
    int totalPhotos;
    int rawConversionSuccess;
    int rawConversionFailed;
    int analysisSuccess;
    int analysisFailed;
    int pending;
    int blurry;
    int overexposed;
    int underexposed;
    int normal;
};

class AppRunner {
public:
    RunSummary run(const RunOptions& options);
};
```

执行顺序必须固定：

1. `ConfigLoader.loadFromFile(configPath)`。
2. `FileScanner.scanTopLevel(folderPath)`。
3. `JsonManager.init(folderPath, configPath)`。
4. `JsonManager.mergeScannedPairs(pairs)`。
5. `JsonManager.markRunningAsPending()`。
6. `JsonManager.atomicSave()`。
7. `ResumePlanner.plan(states, config)` 生成 RAW 队列。
8. RAW 队列非空时：
   - 主线程把每个任务状态标记为 `running` 并保存。
   - 创建固定 4 worker `ThreadPool<RawConvertTask, RawConvertResult>`。
   - worker 执行 `convertWithRetry`。
   - 主线程每收到一个结果，立即调用 `JsonManager.updateRawConversionResult(result)` 并 `atomicSave()`。
9. RAW 阶段结束后重新读取内存状态并再次 `ResumePlanner.plan` 生成分析队列。
10. 分析队列非空时：
    - 主线程把每个任务状态标记为 `running` 并保存。
    - 创建固定 4 worker `ThreadPool<AnalyzeTask, AnalyzeResult>`。
    - worker 执行 `analyzeWithRetry`。
    - 主线程每收到一个结果，立即调用 `JsonManager.updateAnalysisResult(result)` 并 `atomicSave()`。
11. 更新 summary 并最后保存一次 JSON。
12. 返回 `RunSummary` 并由 `main.cpp` 打印。

命令行规则：

```bash
./rawViewer /path/to/photos
./rawViewer /path/to/photos --config /path/to/config.yaml
./rawViewer /path/to/photos --resume
```

`--resume` 是默认行为；传入或不传入都执行断点续跑。

### Step 2 — Write tests based on the plan goal

`cpp/tests/appRunnerTests.cpp` 必须覆盖：

1. 临时目录内 1 张 JPG，fake analyzer 成功，运行后 JSON 中 `analysis_status == success`。
2. 临时目录内 1 个 RAW-only，fake converter 成功后 fake analyzer 成功，运行后 JSON 同时有 RAW success 和 analysis success。
3. fake converter 两次失败，JSON 中 `failed_step == raw_conversion`。
4. fake analyzer 两次失败，JSON 中 `failed_step == analysis`。
5. 每个任务完成后立即保存：在 fake converter/analyzer 内记录主线程保存计数，断言保存次数不少于任务完成次数。
6. 已成功完成的 JSON 记录再次运行时被跳过，fake analyzer 调用次数为 0。
7. 上次 JSON 中 `analysis_status == running` 时，再次运行会重新分析。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test -only-testing:rawViewerTests/appRunnerTests
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 端到端 fake 流程、失败写入、即时保存、跳过 success、重跑 running 测试全部通过。

---

## Task 12: Xcode target integration

**Goal:** Xcode 主 target 和测试 target 都能引用新增 C++ 文件、头文件路径和现有第三方库，Debug 构建与测试全部通过。

**Files touched:**

- `rawViewer.xcodeproj` — 只通过 Xcode UI 或 `xcodebuild` 可识别的 project 设置加入文件、搜索路径和库引用。

### Step 1 — Implement

在 Xcode 中完成以下设置：

1. 主 target 加入：
   - `cpp/main.cpp`
   - `cpp/src/taskState.cpp`
   - `cpp/src/configLoader.cpp`
   - `cpp/src/fileScanner.cpp`
   - `cpp/src/jsonManager.cpp`
   - `cpp/src/resumePlanner.cpp`
   - `cpp/src/threadPool.cpp`
   - `cpp/src/rawConverter.cpp`
   - `cpp/src/imageAnalyzer.cpp`
   - `cpp/src/appRunner.cpp`
2. 测试 target 加入：
   - 所有 `cpp/src/*.cpp`，但不加入 `cpp/main.cpp`
   - 所有 `cpp/tests/*.cpp`
3. Header Search Paths 加入：
   - `$(PROJECT_DIR)/cpp/include`
   - `$(PROJECT_DIR)/3rdPart/json/**`
   - `$(PROJECT_DIR)/3rdPart/yaml/**`
   - `$(PROJECT_DIR)/3rdPart/opencv/**`
   - `$(PROJECT_DIR)/3rdPart/libraw/**`
4. Library Search Paths 加入：
   - `$(PROJECT_DIR)/3rdPart/yaml/**`
   - `$(PROJECT_DIR)/3rdPart/opencv/**`
   - `$(PROJECT_DIR)/3rdPart/libraw/**`
5. Link Binary With Libraries 加入现有 `3rdPart` 下的 yaml-cpp、OpenCV、LibRaw 产物。
6. C++ Language Dialect 设置为 C++17 或更高。
7. 如果主 target 原来是 App target，确保新增 command-line 入口不会与已有 App 入口冲突；冲突时创建单独 `PhotoAnalyzerCLI` target，并把本计划中所有命令的 scheme 替换为 `PhotoAnalyzerCLI`。

### Step 2 — Write tests based on the plan goal

本任务测试为构建和全量测试命令。

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **

$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test
# Expected: ** TEST SUCCEEDED **
```

如果实际使用单独 CLI scheme，则执行：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme PhotoAnalyzerCLI -configuration Debug build
# Expected: ** BUILD SUCCEEDED **

$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test
# Expected: ** TEST SUCCEEDED **
```

✅ **Done when:** 主 target 构建成功，测试 target 全部测试成功。

---

## Task 13: Manual end-to-end verification

**Goal:** 使用真实命令在临时照片目录上验证扫描、JSON 创建、断点续跑、即时保存和输出摘要。

**Files touched:** 无源码文件。创建临时测试目录和测试图片。

### Step 1 — Implement

准备临时目录：

```bash
$ mkdir -p /tmp/photo-analyzer-e2e
# Expected: 无输出
```

放入至少以下文件：

```text
/tmp/photo-analyzer-e2e/IMG_0001.JPG
/tmp/photo-analyzer-e2e/IMG_0002.JPG
```

若有真实 RAW 样本，再放入：

```text
/tmp/photo-analyzer-e2e/IMG_0003.RW2
```

### Step 2 — Write tests based on the plan goal

执行程序：

```bash
$ ./rawViewer /tmp/photo-analyzer-e2e --config config.yaml
# Expected: 输出 Scan、JSON、Resume、Convert 或 Analyze、Summary 信息
```

验证 JSON：

```bash
$ test -f /tmp/photo-analyzer-e2e/.cache/analysis.json && echo "OK analysis json"
# Expected: OK analysis json

$ python3 -m json.tool /tmp/photo-analyzer-e2e/.cache/analysis.json >/tmp/photo-analyzer-e2e/analysis.pretty.json && echo "OK valid json"
# Expected: OK valid json

$ grep -q '"schema_version": "1.3"' /tmp/photo-analyzer-e2e/analysis.pretty.json && echo "OK schema"
# Expected: OK schema

$ grep -q '"analysis_raw_data"' /tmp/photo-analyzer-e2e/analysis.pretty.json && echo "OK raw analysis data"
# Expected: OK raw analysis data
```

再次执行断点续跑：

```bash
$ ./rawViewer /tmp/photo-analyzer-e2e --config config.yaml --resume
# Expected: 已成功完成的照片显示为 skip，不重复分析成功项
```

### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build && xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test
# Expected: ** BUILD SUCCEEDED ** 且 ** TEST SUCCEEDED **
```

✅ **Done when:** 临时目录运行成功，JSON 合法，包含配置快照和原始分析数据，第二次运行会跳过成功项。

---

## Task 14: Final acceptance checklist

**Goal:** 对照技术方案完成最终验收，确认没有遗漏核心要求。

**Files touched:** 无源码文件。

### Step 1 — Implement

逐项检查并记录结果：

| 验收项 | 必须结果 |
| --- | --- |
| 顶层扫描 | 只扫描输入目录顶层，不递归。 |
| 格式支持 | 支持 JPG/JPEG、RW2、CR2，大小写后缀均可。 |
| 配置读取 | 虚焦、曝光、RAW JPG 质量来自 `config.yaml`。 |
| 配置校验 | 缺字段或非法值直接报错。 |
| JSON 路径 | 固定为 `<输入文件夹>/.cache/analysis.json`。 |
| JSON 原始数据 | 每张分析成功照片写入拉普拉斯统计和 256-bin 直方图。 |
| 配置快照 | 每张分析成功照片写入本次使用的 config 参数。 |
| 断点续跑 | success 跳过，failed/pending/running 继续处理。 |
| RAW 重试 | 失败后立即重试一次，最终失败写 `raw_conversion`。 |
| 分析重试 | 失败后立即重试一次，最终失败写 `analysis`。 |
| 线程池 | RAW 和分析阶段均固定 4 worker。 |
| 线程模型 | 共享队列持续消费，不按批次等待。 |
| JSON 写入线程 | 只有主线程写 JSON。 |
| JSON 写入时机 | 每个任务完成后立即原子保存。 |
| JSON 原子性 | 使用 `.tmp` 文件和 rename 覆盖。 |
| 源码位置 | `main.cpp` 在 `cpp/`，头文件在 `cpp/include/`，实现文件在 `cpp/src/`。 |
| 构建 | Debug 构建成功。 |
| 测试 | 全量测试成功。 |
| 禁止项 | 未增加第三方下载/安装/编译步骤，未增加 CMake/build 脚本，未执行版本控制操作。 |

### Step 2 — Write tests based on the plan goal

执行全量构建和测试：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **

$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewerTests -configuration Debug test
# Expected: ** TEST SUCCEEDED **
```

### Step 3 — Run tests and confirm all pass

保留以下验收记录到项目文档或 issue 说明中：

```text
Build: PASS
Tests: PASS
Manual E2E: PASS
JSON valid: PASS
Resume behavior: PASS
Fixed 4-worker shared queue: PASS
Immediate atomic JSON save: PASS
```

✅ **Done when:** 验收表全部为 PASS，且没有任何禁止项被引入。

---

## 执行顺序硬性要求

1. 必须从 Task 0 开始。
2. 每个任务必须先实现，再写测试，再运行该任务测试。
3. 当前任务测试未通过时，不得进入下一任务。
4. 不得删除或削弱测试来让任务通过。
5. 出现构建失败时，只修复当前任务范围内引入的问题。
6. 所有任务完成后必须执行 Task 14 的最终验收。

