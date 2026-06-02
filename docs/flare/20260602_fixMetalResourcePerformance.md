# Metal Resource Lifecycle and Performance Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 macOS Metal/CoreImage 分析路径的资源生命周期、计时误导和无运行反馈问题，让 `Context leak detected` 消失或可被定位，并让日志能真实解释 GPU 阶段耗时。

**Architecture:** 不把 4 worker 当作当前根因；本计划保持现有 worker 数不变，优先修复每张图重复创建 Metal/CoreImage 上下文、非 ARC/无 autoreleasepool、GPU wait 未计时、CLI 无阶段反馈这几个已确认问题。Metal 设备、CIContext、command queue、library、pipeline 会进程级缓存复用；每张图只创建必要的 image/texture/buffer/commandBuffer。

**Tech Stack:** C++17、Objective-C++、Metal、CoreImage、LibRaw、OpenCV、CMake、项目现有轻量测试框架。

---

## Scope and Non-Goals

### 本计划确认修复

1. Objective-C++ 资源生命周期：开启 ARC，并在 Metal 分析入口加入 `@autoreleasepool`。
2. Metal/CoreImage 初始化开销：缓存 `MTLDevice`、`MTLCommandQueue`、`CIContext`、`MTLLibrary`、`MTLComputePipelineState`。
3. 性能日志误导：新增 GPU wait / total wall timing，避免继续出现 `laplacian=0ms stats=0ms histogram=0ms` 但无法解释 GPU 使用率的情况。
4. CLI 静默：增加简洁阶段进度输出，让 RAW conversion 和 analysis 阶段有可见反馈。
5. 验证手段：增加自动测试和手动验证命令。

### 本计划明确不做

1. 不把 `ThreadPool::kWorkerCount = 4` 改小。
2. 不把 RAW 转换迁移到 GPU。
3. 不重写 LibRaw/OpenCV 转换链路。
4. 不引入大型测试框架。
5. 不做复杂配置系统重构。

---

## File Structure

### 修改文件

- `cpp/CMakeLists.txt` — 为 Objective-C++ 打开 ARC；给测试目标加入诊断宏；注册新增测试源文件。
- `cpp/include/taskState.h` — 给 `AnalyzeResult` 增加可靠耗时字段。
- `cpp/src/macImageAnalyzer.mm` — 增加 `@autoreleasepool`；缓存 Metal/CoreImage 上下文；记录 GPU wait 和 total wall timing；暴露测试诊断函数。
- `cpp/include/macImageAnalyzer.h` — 在测试诊断宏下声明 Metal context 创建次数查询函数。
- `cpp/src/appRunner.cpp` — analysis log 使用新的 `totalWallMs`，输出 GPU wait / render / encode timing。
- `cpp/main.cpp` — 为 CLI 配置简洁进度回调。
- `cpp/tests/imageAnalyzerTests.cpp` — 增加 timing 字段与 context 复用测试。
- `cpp/tests/testMain.cpp` — 注册 Objective-C runtime/ARC 测试。

### 新增文件

- `cpp/tests/objcRuntimeTests.mm` — 编译期验证测试目标已启用 ARC，并运行一个最小 autoreleasepool 测试。
- `docs/perf/20260602_metalResourceValidation.md` — 记录本次修复后的手动验证命令和预期现象。

---

## Task 0: Environment Setup

**Goal:** 建立干净 baseline，确保修复前后的构建、测试、运行日志可对比。

**Files touched:** 无。

### Step 1 — 创建分支并确认工作区

```bash
$ git status --short
# Expected: 如果存在用户未提交改动，先停止并确认；不要覆盖用户改动。

$ git checkout -b fix/metal-resource-performance
# Expected: Switched to a new branch 'fix/metal-resource-performance'
```

### Step 2 — 配置并构建测试目标

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
# Expected: Configuring done / Generating done / Build files have been written to: .../cpp/build

$ cmake --build cpp/build --target rawViewer rawViewerTests -j
# Expected: rawViewer 和 rawViewerTests 构建成功，无编译错误。
```

### Step 3 — 运行 baseline 测试

```bash
$ ./cpp/build/rawViewerTests
# Expected: Tests run: <N>, failures: 0
```

如果 baseline 测试失败，先停止并修复环境，不进入 Task 1。

### Step 4 — 保存当前日志样本

```bash
$ mkdir -p docs/perf/baseline
$ cp /Users/wilbur/Downloads/LUMIX_Backup/.cache/conversion.log docs/perf/baseline/conversion_20260602_before.log
$ cp /Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.log docs/perf/baseline/analysis_20260602_before.log
# Expected: 两个 baseline 日志文件存在。
```

---

## Task 1: Fix Analysis Timing Model

**Goal:** analysis 日志能报告真实 wall time 和 GPU wait time，不再只记录 CPU command encoding 时间。

**Files touched:**

- `cpp/include/taskState.h` — 增加 `AnalyzeResult` timing 字段。
- `cpp/src/macImageAnalyzer.mm` — 填充新 timing 字段。
- `cpp/src/appRunner.cpp` — 写入新 timing 字段到 `analysis.log`。
- `cpp/tests/imageAnalyzerTests.cpp` — 验证 timing 字段存在且数值合理。

---

#### Step 1 — Implement

1. 在 `cpp/include/taskState.h` 的 `AnalyzeResult` 中，保留已有字段，新增：

```cpp
int64_t renderImageMs = 0;
int64_t gpuEncodeMs = 0;
int64_t gpuWaitMs = 0;
int64_t totalWallMs = 0;
```

放在现有字段后面：

```cpp
int64_t readImageMs = 0;
int64_t grayMs = 0;
int64_t laplacianMs = 0;
int64_t statsMs = 0;
int64_t histogramMs = 0;
int64_t renderImageMs = 0;
int64_t gpuEncodeMs = 0;
int64_t gpuWaitMs = 0;
int64_t totalWallMs = 0;
```

2. 在 `cpp/src/macImageAnalyzer.mm` 的 `analyzeWithMacMetal()` 开头增加总耗时计时器：

```objc
PerfTimer totalTimer;
```

位置：`AnalyzeResult result;` 后面。

3. 将 CoreImage render 阶段从复用 `grayMs` 改为独立字段。

当前逻辑类似：

```objc
phaseTimer.reset();
CGColorSpaceRef rgbaColorSpace = CGColorSpaceCreateDeviceRGB();
[ciContext render:ciImage
    toMTLTexture:rgbaTexture
   commandBuffer:commandBuffer
         bounds:CGRectMake(extent.origin.x, extent.origin.y, width, height)
     colorSpace:rgbaColorSpace];
CGColorSpaceRelease(rgbaColorSpace);
result.grayMs = phaseTimer.elapsedMs();
```

改为：

```objc
phaseTimer.reset();
CGColorSpaceRef rgbaColorSpace = CGColorSpaceCreateDeviceRGB();
[ciContext render:ciImage
    toMTLTexture:rgbaTexture
   commandBuffer:commandBuffer
         bounds:CGRectMake(extent.origin.x, extent.origin.y, width, height)
     colorSpace:rgbaColorSpace];
CGColorSpaceRelease(rgbaColorSpace);
result.renderImageMs = phaseTimer.elapsedMs();
```

4. 在四个 compute encoder 的外层统计 CPU encode 总耗时。最小改法：定义一个累加变量。

在 dispatch 前添加：

```objc
int64_t encodeMs = 0;
```

每个 encoder 阶段保留原字段，并累加：

```objc
phaseTimer.reset();
id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
if (encoder == nil) {
    fillError(result, "Failed to create rgbToGray encoder");
    result.totalWallMs = totalTimer.elapsedMs();
    return result;
}
[encoder setComputePipelineState:rgbToGrayPipeline];
[encoder setTexture:rgbaTexture atIndex:0];
[encoder setBuffer:grayBuffer offset:0 atIndex:0];
[encoder setBuffer:configBuffer offset:0 atIndex:1];
[encoder dispatchThreadgroups:groups2d threadsPerThreadgroup:threads2d];
[encoder endEncoding];
result.grayMs = phaseTimer.elapsedMs();
encodeMs += result.grayMs;
```

laplacian / histogram / reduce 阶段同样 `encodeMs += result.<field>`。

5. 记录 GPU wait：

当前：

```objc
[commandBuffer commit];
[commandBuffer waitUntilCompleted];
```

改为：

```objc
result.gpuEncodeMs = encodeMs;
[commandBuffer commit];
phaseTimer.reset();
[commandBuffer waitUntilCompleted];
result.gpuWaitMs = phaseTimer.elapsedMs();
```

6. 所有失败 return 前尽量填充：

```cpp
result.totalWallMs = totalTimer.elapsedMs();
```

成功 return 前填充：

```cpp
result.totalWallMs = totalTimer.elapsedMs();
```

7. 在 `cpp/src/appRunner.cpp` analysis log 中替换 elapsed 计算。

当前：

```cpp
int64_t elapsedMs = anaResult.readImageMs + anaResult.grayMs + anaResult.laplacianMs +
                    anaResult.statsMs + anaResult.histogramMs;
```

改为：

```cpp
int64_t elapsedMs = anaResult.totalWallMs > 0
    ? anaResult.totalWallMs
    : anaResult.readImageMs + anaResult.renderImageMs + anaResult.grayMs + anaResult.laplacianMs +
      anaResult.statsMs + anaResult.histogramMs + anaResult.gpuWaitMs;
```

并把日志字段扩展为：

```cpp
logFile << "[" << tsBuf << "] photo=" << anaResult.photoId
        << " elapsed=" << elapsedMs << "ms"
        << " backend=" << anaResult.backendUsed
        << " read_image=" << anaResult.readImageMs << "ms"
        << " render_image=" << anaResult.renderImageMs << "ms"
        << " gray=" << anaResult.grayMs << "ms"
        << " laplacian=" << anaResult.laplacianMs << "ms"
        << " stats=" << anaResult.statsMs << "ms"
        << " histogram=" << anaResult.histogramMs << "ms"
        << " gpu_encode=" << anaResult.gpuEncodeMs << "ms"
        << " gpu_wait=" << anaResult.gpuWaitMs << "ms"
        << " total_wall=" << anaResult.totalWallMs << "ms"
        << " attempts=" << anaResult.attempts
        << " success=" << (anaResult.success ? "true" : "false");
```

---

#### Step 2 — Write tests based on the plan goal

在 `cpp/tests/imageAnalyzerTests.cpp` 增加测试函数：

```cpp
static bool imageAnalyzerGpuReportsTimingFields() {
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(32, 32, CV_8UC3, cv::Scalar(32, 64, 128));
    std::string path = writeImage("rawviewer-gpu-timing.png", image);
    AnalyzeResult result = ImageAnalyzer().analyze(makeTask("timing", path), config);

    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.totalWallMs >= 0);
    TEST_REQUIRE(result.readImageMs >= 0);
    TEST_REQUIRE(result.renderImageMs >= 0);
    TEST_REQUIRE(result.grayMs >= 0);
    TEST_REQUIRE(result.laplacianMs >= 0);
    TEST_REQUIRE(result.statsMs >= 0);
    TEST_REQUIRE(result.histogramMs >= 0);
    TEST_REQUIRE(result.gpuEncodeMs >= 0);
    TEST_REQUIRE(result.gpuWaitMs >= 0);
    TEST_REQUIRE(result.totalWallMs >= result.readImageMs);
    return true;
}
```

注册到 `makeImageAnalyzerTests()`：

```cpp
{"imageAnalyzer.gpuReportsTimingFields", imageAnalyzerGpuReportsTimingFields},
```

---

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests -j
# Expected: rawViewerTests 构建成功。

$ ./cpp/build/rawViewerTests --filter imageAnalyzer.gpuReportsTimingFields
# Expected:
#   PASS imageAnalyzer.gpuReportsTimingFields
#   Tests run: 1, failures: 0
```

✅ **Done when:** timing 测试通过，并且 `analysis.log` 代码已包含 `gpu_wait`、`gpu_encode`、`total_wall` 字段。

---

## Task 2: Enable ARC and Add Autorelease Pool

**Goal:** Objective-C++ Metal/CoreImage 路径在 ARC 下编译，并且每次分析任务结束时释放 autoreleased 临时对象，降低 context leak 触发概率。

**Files touched:**

- `cpp/CMakeLists.txt` — 打开 Objective-C++ ARC；注册新增测试文件。
- `cpp/src/macImageAnalyzer.mm` — 用 `@autoreleasepool` 包住分析实现。
- `cpp/tests/objcRuntimeTests.mm` — 新增 ARC 编译期测试。
- `cpp/tests/testMain.cpp` — 注册新增测试。

---

#### Step 1 — Implement

1. 修改 `cpp/CMakeLists.txt`，在 `add_executable(rawViewer ${SOURCES})` 和 `target_include_directories(rawViewer PRIVATE ...)` 之间或之后加入：

```cmake
target_compile_options(rawViewer PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)
```

2. 在 `RAWVIEWER_BUILD_TESTS` 分支里，给 `rawViewerTests` 也加入：

```cmake
target_compile_options(rawViewerTests PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)
```

3. 把新测试源加入 `rawViewerTests`：

```cmake
tests/objcRuntimeTests.mm
```

放在 `tests/testMain.cpp` 附近即可。

4. 修改 `cpp/src/macImageAnalyzer.mm`，把 macOS 分支的主体包进 `@autoreleasepool`。

当前结构：

```objc
#else
    GpuSupport support = getGpuSupport();
    ...
    @try {
        ...
    } @catch (NSException* ex) {
        ...
    }
#endif
```

改为：

```objc
#else
    @autoreleasepool {
        GpuSupport support = getGpuSupport();
        if (!support.hasMetal) {
            result.success = false;
            result.error = support.reason;
            result.totalWallMs = totalTimer.elapsedMs();
            return result;
        }

        @try {
            // 原有 Metal/CoreImage 分析主体保持在这里。
        } @catch (NSException* ex) {
            NSString* reason = ex.reason ?: @"unknown";
            result.success = false;
            result.error = std::string("Metal analysis threw: ") + [reason UTF8String];
            result.totalWallMs = totalTimer.elapsedMs();
            return result;
        }
    }
#endif
```

注意：Task 1 已经引入 `totalTimer`，失败路径也要设置 `totalWallMs`。

5. 新增 `cpp/tests/objcRuntimeTests.mm`：

```objc
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 验证 Objective-C++ 测试目标启用 ARC，并确认 autoreleasepool 可正常执行
 */

#include "testAssert.h"
#include <Foundation/Foundation.h>
#include <vector>

#if !__has_feature(objc_arc)
#error "Objective-C ARC must be enabled for rawViewer Objective-C++ sources"
#endif

static bool objcRuntimeArcIsEnabled() {
    @autoreleasepool {
        NSString* value = [NSString stringWithFormat:@"%@", @"arc-enabled"];
        TEST_REQUIRE(value != nil);
        TEST_REQUIRE([[value description] isEqualToString:@"arc-enabled"]);
    }
    return true;
}

std::vector<TestCase> makeObjcRuntimeTests() {
    return {
        {"objcRuntime.arcIsEnabled", objcRuntimeArcIsEnabled},
    };
}
```

6. 修改 `cpp/tests/testMain.cpp`。

增加声明：

```cpp
std::vector<TestCase> makeObjcRuntimeTests();
```

在测试注册列表中加入：

```cpp
auto objcRuntimeTests = makeObjcRuntimeTests();
tests.insert(tests.end(), objcRuntimeTests.begin(), objcRuntimeTests.end());
```

建议放在 `gpuSupportTests` 后、`imageAnalyzerTests` 前。

---

#### Step 2 — Write tests based on the plan goal

本任务测试文件已在 Step 1 完整新增：`cpp/tests/objcRuntimeTests.mm`。它通过编译期 `#error` 确认 ARC 开启，通过运行期 `@autoreleasepool` 确认基础 Objective-C runtime 行为可用。

---

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
# Expected: Configuring done / Generating done

$ cmake --build cpp/build --target rawViewerTests -j
# Expected: objcRuntimeTests.mm 成功编译；如果 ARC 未启用，会在编译期失败。

$ ./cpp/build/rawViewerTests --filter objcRuntime.arcIsEnabled
# Expected:
#   PASS objcRuntime.arcIsEnabled
#   Tests run: 1, failures: 0
```

✅ **Done when:** ARC 测试通过，且 `macImageAnalyzer.mm` 的 macOS 分析主体被 `@autoreleasepool` 包住。

---

## Task 3: Reuse Metal and CoreImage Context

**Goal:** 多张图片分析时只初始化一次 Metal/CoreImage 静态上下文，不再每张图重复创建 device、command queue、CIContext、library、pipeline。

**Files touched:**

- `cpp/include/macImageAnalyzer.h` — 测试诊断函数声明。
- `cpp/src/macImageAnalyzer.mm` — 新增 context cache 并改造 analyzer 使用缓存对象。
- `cpp/CMakeLists.txt` — 给测试目标启用诊断宏。
- `cpp/tests/imageAnalyzerTests.cpp` — 验证连续分析复用同一个 context。

---

#### Step 1 — Implement

1. 修改 `cpp/include/macImageAnalyzer.h`，在现有 `AnalyzeResult analyzeWithMacMetal(...)` 后增加测试诊断声明：

```cpp
#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
int rawViewerMetalAnalyzerContextCreateCountForTests();
#endif
```

2. 修改 `cpp/CMakeLists.txt`，在 `rawViewerTests` 的 target 设置里加入：

```cmake
target_compile_definitions(rawViewerTests PRIVATE RAWVIEWER_ENABLE_METAL_DIAGNOSTICS=1)
```

3. 在 `cpp/src/macImageAnalyzer.mm` 的 `#if defined(__APPLE__)` 区域新增静态计数：

```objc
#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
static std::atomic<int> gMetalAnalyzerContextCreateCount{0};
#endif
```

需要增加头文件：

```cpp
#include <atomic>
#include <mutex>
```

4. 在匿名 namespace 的 Apple 区域定义 Objective-C context 类：

```objc
@interface RawViewerMetalAnalyzerContext : NSObject
@property(nonatomic, strong, readonly) id<MTLDevice> device;
@property(nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong, readonly) CIContext* ciContext;
@property(nonatomic, strong, readonly) id<MTLLibrary> library;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> rgbToGrayPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> laplacianPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> histogramPipeline;
@property(nonatomic, strong, readonly) id<MTLComputePipelineState> reducePipeline;
- (instancetype)initWithError:(NSString**)errorMessage;
@end

@implementation RawViewerMetalAnalyzerContext

- (instancetype)initWithError:(NSString**)errorMessage {
    self = [super init];
    if (self == nil) return nil;

    _device = MTLCreateSystemDefaultDevice();
    if (_device == nil) {
        if (errorMessage != nil) *errorMessage = @"MTLCreateSystemDefaultDevice returned nil";
        return nil;
    }

    _commandQueue = [_device newCommandQueue];
    if (_commandQueue == nil) {
        if (errorMessage != nil) *errorMessage = @"Failed to create MTLCommandQueue";
        return nil;
    }

    _ciContext = [CIContext contextWithMTLDevice:_device options:nil];
    if (_ciContext == nil) {
        if (errorMessage != nil) *errorMessage = @"Failed to create Metal-backed CIContext";
        return nil;
    }

    NSError* sourceError = nil;
    NSString* sourcePath = shaderPath();
    NSString* source = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&sourceError];
    if (source == nil) {
        if (errorMessage != nil) {
            *errorMessage = [NSString stringWithFormat:@"Failed to read gpuImageKernels.metal: %@", sourceError.localizedDescription ?: @"unknown"];
        }
        return nil;
    }

    NSError* libraryError = nil;
    _library = [_device newLibraryWithSource:source options:nil error:&libraryError];
    if (_library == nil) {
        if (errorMessage != nil) {
            *errorMessage = [NSString stringWithFormat:@"Failed to compile gpuImageKernels.metal: %@", libraryError.localizedDescription ?: @"unknown"];
        }
        return nil;
    }

    std::string pipelineError;
    _rgbToGrayPipeline = makePipeline(_device, _library, @"rgbToGrayKernel", pipelineError);
    if (_rgbToGrayPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _laplacianPipeline = makePipeline(_device, _library, @"laplacianKernel", pipelineError);
    if (_laplacianPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _histogramPipeline = makePipeline(_device, _library, @"histogramKernel", pipelineError);
    if (_histogramPipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

    _reducePipeline = makePipeline(_device, _library, @"reduceLaplacianKernel", pipelineError);
    if (_reducePipeline == nil) {
        if (errorMessage != nil) *errorMessage = [NSString stringWithUTF8String:pipelineError.c_str()];
        return nil;
    }

#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
    gMetalAnalyzerContextCreateCount.fetch_add(1, std::memory_order_relaxed);
#endif
    return self;
}

@end
```

5. 新增共享 context helper：

```objc
static RawViewerMetalAnalyzerContext* sharedMetalAnalyzerContext(std::string& error) {
    static std::mutex mutex;
    static RawViewerMetalAnalyzerContext* context = nil;
    static std::string cachedError;

    std::lock_guard<std::mutex> lock(mutex);
    if (context != nil) {
        return context;
    }
    if (!cachedError.empty()) {
        error = cachedError;
        return nil;
    }

    NSString* errorMessage = nil;
    context = [[RawViewerMetalAnalyzerContext alloc] initWithError:&errorMessage];
    if (context == nil) {
        cachedError = errorMessage != nil ? std::string([errorMessage UTF8String]) : "Failed to create Metal analyzer context";
        error = cachedError;
        return nil;
    }
    return context;
}
```

6. 改造 `analyzeWithMacMetal()`：删除每张图创建 `device`、`commandQueue`、`ciContext`、`source`、`library`、pipeline 的代码，替换为：

```objc
std::string contextError;
RawViewerMetalAnalyzerContext* context = sharedMetalAnalyzerContext(contextError);
if (context == nil) {
    fillError(result, contextError);
    result.totalWallMs = totalTimer.elapsedMs();
    return result;
}

id<MTLDevice> device = context.device;
id<MTLCommandQueue> commandQueue = context.commandQueue;
CIContext* ciContext = context.ciContext;
id<MTLComputePipelineState> rgbToGrayPipeline = context.rgbToGrayPipeline;
id<MTLComputePipelineState> laplacianPipeline = context.laplacianPipeline;
id<MTLComputePipelineState> histogramPipeline = context.histogramPipeline;
id<MTLComputePipelineState> reducePipeline = context.reducePipeline;
```

7. 在 `cpp/src/macImageAnalyzer.mm` 文件末尾 Apple 分支下增加诊断函数实现：

```cpp
#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
int rawViewerMetalAnalyzerContextCreateCountForTests() {
#if defined(__APPLE__)
    return gMetalAnalyzerContextCreateCount.load(std::memory_order_relaxed);
#else
    return 0;
#endif
}
#endif
```

---

#### Step 2 — Write tests based on the plan goal

在 `cpp/tests/imageAnalyzerTests.cpp` 顶部加入：

```cpp
#include "macImageAnalyzer.h"
```

新增测试：

```cpp
static bool imageAnalyzerGpuReusesMetalContextAcrossCalls() {
#ifdef RAWVIEWER_ENABLE_METAL_DIAGNOSTICS
    AppConfig config = makeAnalyzerConfig();
    cv::Mat image(16, 16, CV_8UC3, cv::Scalar(20, 40, 60));
    std::string path = writeImage("rawviewer-gpu-context-reuse.png", image);

    int before = rawViewerMetalAnalyzerContextCreateCountForTests();
    AnalyzeResult first = ImageAnalyzer().analyze(makeTask("reuse1", path), config);
    AnalyzeResult second = ImageAnalyzer().analyze(makeTask("reuse2", path), config);
    AnalyzeResult third = ImageAnalyzer().analyze(makeTask("reuse3", path), config);
    int after = rawViewerMetalAnalyzerContextCreateCountForTests();

    TEST_REQUIRE(first.success);
    TEST_REQUIRE(second.success);
    TEST_REQUIRE(third.success);
    TEST_REQUIRE(after >= before);
    TEST_REQUIRE((after - before) <= 1);
    return true;
#else
    return true;
#endif
}
```

注册：

```cpp
{"imageAnalyzer.gpuReusesMetalContextAcrossCalls", imageAnalyzerGpuReusesMetalContextAcrossCalls},
```

---

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
# Expected: 配置成功。

$ cmake --build cpp/build --target rawViewerTests -j
# Expected: 构建成功。

$ ./cpp/build/rawViewerTests --filter imageAnalyzer.gpuReusesMetalContextAcrossCalls,imageAnalyzer.gpuMatchesReferenceForGradientImage
# Expected:
#   PASS imageAnalyzer.gpuReusesMetalContextAcrossCalls
#   PASS imageAnalyzer.gpuMatchesReferenceForGradientImage
#   Tests run: 2, failures: 0
```

✅ **Done when:** 连续 3 次分析最多只新增 1 次 context 创建，且原有 reference correctness 测试仍通过。

---

## Task 4: Add Minimal CLI Progress Output

**Goal:** CLI 运行时能看到扫描、RAW 转换、分析和完成阶段进度，不再长时间静默。

**Files touched:**

- `cpp/main.cpp` — 设置 `RunOptions::progressCallback`。

---

#### Step 1 — Implement

在 `cpp/main.cpp` 中增加 include：

```cpp
#include <iomanip>
```

在 `main()` 中，解析参数之后、`try` 之前，设置回调：

```cpp
options.progressCallback = [](const RunProgress& progress) {
    const char* phaseName = "unknown";
    switch (progress.phase) {
        case RunPhase::Scanning: phaseName = "scanning"; break;
        case RunPhase::RawConversion: phaseName = "raw_conversion"; break;
        case RunPhase::Analysis: phaseName = "analysis"; break;
        case RunPhase::Organizing: phaseName = "organizing"; break;
        case RunPhase::Completed: phaseName = "completed"; break;
    }

    int percent = static_cast<int>(progress.overallProgress * 100.0 + 0.5);
    if (progress.totalCount > 0) {
        std::cout << "[" << phaseName << "] "
                  << progress.completedCount << "/" << progress.totalCount
                  << " overall=" << percent << "%" << std::endl;
    } else {
        std::cout << "[" << phaseName << "] overall=" << percent << "%" << std::endl;
    }
};
```

如果 `#include <iomanip>` 未使用，删除它，保持最小改动。

---

#### Step 2 — Write tests based on the plan goal

本任务不新增单元测试，因为 `main.cpp` 当前没有被测试目标链接，且引入 CLI 子进程测试会显著扩大测试复杂度。验证通过 Task 4 的手动运行命令完成。

---

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewer -j
# Expected: rawViewer 构建成功。

$ ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume
# Expected: 运行期间能看到类似：
#   [scanning] 158/158 overall=10%
#   [raw_conversion] 0/158 overall=10%
#   [analysis] 1/158 overall=45%
#   [completed] 158/158 overall=100%
```

✅ **Done when:** CLI 不再静默，阶段进度能实时输出。

---

## Task 5: Add Validation Runbook

**Goal:** 留下一份可重复执行的验证文档，用来确认 leak 输出、GPU timing 和卡顿现象是否改善。

**Files touched:**

- `docs/perf/20260602_metalResourceValidation.md` — 新增验证文档。

---

#### Step 1 — Implement

新增 `docs/perf/20260602_metalResourceValidation.md`：

```markdown
# Metal Resource Validation — 2026-06-02

## Goal

验证 rawViewer 的 Metal/CoreImage 资源生命周期修复是否生效，并确认 analysis 日志能解释 GPU 阶段耗时。

## Build

```bash
cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build --target rawViewer rawViewerTests -j
./cpp/build/rawViewerTests
```

Expected:

```text
Tests run: <N>, failures: 0
```

## Functional Run

```bash
./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume 2>&1 | tee docs/perf/20260602_after_run.log
```

Expected:

- CLI prints phase progress.
- Summary still reports successful RAW conversion and successful analysis.
- `Context leak detected, CoreAnalytics returned false` should not appear. If it still appears, record exact count and timestamp.

## Analysis Log Check

```bash
python3 - <<'PY'
import pathlib, re, statistics
path = pathlib.Path('/Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.log')
rows = []
for line in path.read_text().splitlines():
    if not line.startswith('['):
        continue
    item = {}
    for key, value in re.findall(r'(\w+)=([^\s]+)', line):
        if value.endswith('ms'):
            item[key] = int(value[:-2])
        else:
            item[key] = value
    rows.append(item)
print('count', len(rows))
for key in ['elapsed', 'read_image', 'render_image', 'gray', 'laplacian', 'stats', 'histogram', 'gpu_encode', 'gpu_wait', 'total_wall']:
    values = [r[key] for r in rows if key in r]
    if values:
        print(key, 'avg', round(statistics.mean(values), 2), 'max', max(values), 'sum', sum(values))
PY
```

Expected:

- Output includes `gpu_wait` and `total_wall`.
- `elapsed` uses `total_wall` instead of synthetic CPU-only sum.
- The log can explain periods of GPU activity.

## Leak Smoke Check

```bash
MallocStackLogging=1 ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume 2>&1 | tee docs/perf/20260602_leak_smoke.log
```

Expected:

- No repeated `Context leak detected` lines.
- If macOS still prints one-off framework diagnostics, compare count against baseline and inspect with Instruments if needed.
```

---

#### Step 2 — Write tests based on the plan goal

本任务是文档任务，不新增自动测试。验证是文档中的命令可被复制执行，并且预期输出明确。

---

#### Step 3 — Run tests and confirm all pass

```bash
$ test -f docs/perf/20260602_metalResourceValidation.md
# Expected: exit code 0

$ rg -n "gpu_wait|Context leak detected|rawViewerTests" docs/perf/20260602_metalResourceValidation.md
# Expected: 至少匹配这三个验证点。
```

✅ **Done when:** 验证文档存在，且包含构建、功能运行、analysis log 检查、leak smoke check 四部分。

---

## Final Verification

全部任务完成后运行：

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
$ cmake --build cpp/build --target rawViewer rawViewerTests -j
$ ./cpp/build/rawViewerTests
# Expected: Tests run: <N>, failures: 0
```

再运行真实数据：

```bash
$ ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume 2>&1 | tee docs/perf/20260602_final_run.log
```

成功标准：

1. 无构建错误。
2. 测试全绿。
3. CLI 有阶段进度输出。
4. `analysis.log` 包含 `gpu_wait`、`gpu_encode`、`total_wall`。
5. 相同数据集结果 summary 与修复前一致，至少 `RAW conversion success=158`、`Analysis success=158` 不退化。
6. `Context leak detected, CoreAnalytics returned false` 不再出现；如果仍出现，出现次数必须记录并用 Instruments 继续定位。

---

## Self-Review

### Spec coverage

- leak 原因修复：Task 2、Task 3。
- GPU 慢但日志无法解释：Task 1、Task 3。
- 电脑卡顿中已确认的资源压力因素：Task 2、Task 3 降低重复创建和资源积累；不改 worker 数。
- 开始无打印：Task 4。
- 可重复验证：Task 5。

### Placeholder scan

本计划不使用 TBD/TODO/implement later。Task 3 的 Objective-C context 初始化给出完整结构和错误路径；Task 4 明确不新增单元测试并给出手动验证命令。

### Type consistency

- 新增字段统一命名为 `renderImageMs`、`gpuEncodeMs`、`gpuWaitMs`、`totalWallMs`。
- 诊断函数统一命名为 `rawViewerMetalAnalyzerContextCreateCountForTests()`。
- 诊断宏统一命名为 `RAWVIEWER_ENABLE_METAL_DIAGNOSTICS`。

### Test completeness

- Task 1 测试 timing 字段。
- Task 2 测试 ARC 编译与 autoreleasepool runtime。
- Task 3 测试 context 复用。
- Task 4 为 CLI 主程序行为，采用手动运行验证，避免引入子进程测试复杂度。
- Task 5 为文档任务，采用文件存在与关键验证点匹配检查。
