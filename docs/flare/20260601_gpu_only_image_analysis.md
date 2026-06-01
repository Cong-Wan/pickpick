# GPU-only Image Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert JPG image analysis to a Metal-only pipeline for M-series macOS, with all pixel-level analysis computed on GPU and only final aggregate results read back to CPU.

**Architecture:** Product code will expose only one analyzer path: `ImageAnalyzer::analyze()` delegates to `analyzeWithMacMetal()`. Core Image decodes the image into a Metal texture; custom Metal compute kernels perform RGB→gray, Laplacian, histogram, exposure counts, and Laplacian statistics without intermediate CPU readback. CPU only converts GPU aggregate buffers into `AnalyzeResult`.

**Tech Stack:** C++17, Objective-C++, Apple Metal, Core Image, yaml-cpp, OpenCV only for RAW conversion and test image generation/reference checks.

---

## File Structure

### Created

- `cpp/src/gpuImageKernels.metal` — Metal compute kernels for grayscale conversion, Laplacian, histogram, exposure counting, and block-level Laplacian reduction.

### Modified

- `cpp/CMakeLists.txt` — compile/copy `.metal` shader into the build output so runtime can load it.
- `cpp/src/macImageAnalyzer.mm` — replace current Core Image + MPS analyzer with custom GPU-only compute pipeline.
- `cpp/src/imageAnalyzer.cpp` — remove CPU/auto product dispatch; always use Metal analyzer.
- `cpp/include/taskState.h` — default analysis backend marker becomes `metal`; keep enum only if needed by old JSON/config code.
- `cpp/src/taskState.cpp` — backend string parsing only accepts `metal` for image analysis compatibility.
- `cpp/src/configLoader.cpp` — reject non-metal image analysis backend and require `laplacian_kernel_size == 3`.
- `cpp/config.yaml` — document M-series macOS GPU-only behavior and set backend fields to `metal`.
- `cpp/tests/imageAnalyzerTests.cpp` — verify GPU product analyzer against test-local CPU reference.
- `cpp/tests/imageAnalyzerBackendTests.cpp` — remove CPU/auto behavior tests and verify Metal-only behavior.

---

## Task 0: Environment Setup

**Goal:** Establish a clean, reproducible baseline before implementation.

**Files touched:** None.

### Step 1 — Check branch and local changes

```bash
$ git status --short
# Expected: may show existing user edits. Do not delete or reset them without explicit approval.
```

If `cpp/src/macImageAnalyzer.mm` or test files already have user edits, read them before changing code.

### Step 2 — Confirm target platform

```bash
$ uname -s && uname -m
# Expected:
# Darwin
# arm64
```

If output is not `Darwin` and `arm64`, stop. This implementation targets M-series macOS only.

### Step 3 — Build and run current tests

```bash
$ cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
# Expected before implementation: build succeeds; current known failures may include Metal/CPU mismatch tests.
```

Record failures before starting. Do not proceed if build itself fails for unrelated dependency reasons.

---

## Task 1: Add custom Metal kernels for GPU-only analysis

**Goal:** Provide GPU kernels that compute grayscale, Laplacian, histogram/exposure counts, and block-level Laplacian statistics without CPU readback of intermediate images.

**Files touched:**

- `cpp/src/gpuImageKernels.metal` — new Metal shader file.

#### Step 1 — Implement

Create `cpp/src/gpuImageKernels.metal` with this complete content:

```metal
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: Metal compute kernels for GPU-only image analysis: grayscale, Laplacian, histogram, exposure counts and reductions
 */

#include <metal_stdlib>
using namespace metal;

struct AnalysisConfigGpu {
    uint width;
    uint height;
    uint totalPixels;
    uint overThreshold;
    uint underThreshold;
};

struct PartialStatsGpu {
    float sum;
    float sumSq;
    float minVal;
    float maxVal;
};

kernel void rgbToGrayKernel(texture2d<float, access::read> rgbaTexture [[texture(0)]],
                            device uchar* grayBuffer [[buffer(0)]],
                            constant AnalysisConfigGpu& config [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= config.width || gid.y >= config.height) {
        return;
    }

    float4 rgba = rgbaTexture.read(gid);
    float grayFloat = rgba.r * 255.0f * 0.299f + rgba.g * 255.0f * 0.587f + rgba.b * 255.0f * 0.114f;
    grayFloat = clamp(grayFloat, 0.0f, 255.0f);
    uchar gray = static_cast<uchar>(grayFloat + 0.5f);
    grayBuffer[gid.y * config.width + gid.x] = gray;
}

kernel void laplacianKernel(device const uchar* grayBuffer [[buffer(0)]],
                            device float* laplacianBuffer [[buffer(1)]],
                            constant AnalysisConfigGpu& config [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= config.width || gid.y >= config.height) {
        return;
    }

    uint x = gid.x;
    uint y = gid.y;
    uint leftX = x == 0 ? 0 : x - 1;
    uint rightX = x + 1 >= config.width ? config.width - 1 : x + 1;
    uint upY = y == 0 ? 0 : y - 1;
    uint downY = y + 1 >= config.height ? config.height - 1 : y + 1;

    float center = static_cast<float>(grayBuffer[y * config.width + x]);
    float left = static_cast<float>(grayBuffer[y * config.width + leftX]);
    float right = static_cast<float>(grayBuffer[y * config.width + rightX]);
    float up = static_cast<float>(grayBuffer[upY * config.width + x]);
    float down = static_cast<float>(grayBuffer[downY * config.width + x]);

    laplacianBuffer[y * config.width + x] = center * 4.0f - left - right - up - down;
}

kernel void histogramKernel(device const uchar* grayBuffer [[buffer(0)]],
                            device atomic_uint* histogram [[buffer(1)]],
                            device atomic_uint* exposureCounts [[buffer(2)]],
                            constant AnalysisConfigGpu& config [[buffer(3)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid >= config.totalPixels) {
        return;
    }

    uint gray = static_cast<uint>(grayBuffer[gid]);
    atomic_fetch_add_explicit(&histogram[gray], 1u, memory_order_relaxed);
    if (gray > config.overThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[0], 1u, memory_order_relaxed);
    }
    if (gray < config.underThreshold) {
        atomic_fetch_add_explicit(&exposureCounts[1], 1u, memory_order_relaxed);
    }
}

kernel void reduceLaplacianKernel(device const float* laplacianBuffer [[buffer(0)]],
                                  device PartialStatsGpu* partialStats [[buffer(1)]],
                                  constant AnalysisConfigGpu& config [[buffer(2)]],
                                  uint tid [[thread_position_in_threadgroup]],
                                  uint groupId [[threadgroup_position_in_grid]],
                                  uint threadsPerGroup [[threads_per_threadgroup]]) {
    threadgroup float localSum[256];
    threadgroup float localSumSq[256];
    threadgroup float localMin[256];
    threadgroup float localMax[256];

    uint index = groupId * threadsPerGroup + tid;
    float value = 0.0f;
    bool valid = index < config.totalPixels;
    if (valid) {
        value = laplacianBuffer[index];
    }

    localSum[tid] = valid ? value : 0.0f;
    localSumSq[tid] = valid ? value * value : 0.0f;
    localMin[tid] = valid ? value : INFINITY;
    localMax[tid] = valid ? value : -INFINITY;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = threadsPerGroup / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            localSum[tid] += localSum[tid + stride];
            localSumSq[tid] += localSumSq[tid + stride];
            localMin[tid] = min(localMin[tid], localMin[tid + stride]);
            localMax[tid] = max(localMax[tid], localMax[tid + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partialStats[groupId].sum = localSum[0];
        partialStats[groupId].sumSq = localSumSq[0];
        partialStats[groupId].minVal = localMin[0];
        partialStats[groupId].maxVal = localMax[0];
    }
}
```

#### Step 2 — Write tests based on the plan goal

No standalone shader unit test is added in this task because kernels require integration through Metal runtime. Task 4 and Task 5 provide behavioral tests that exercise all kernels through the product analyzer.

#### Step 3 — Run tests and confirm all pass

```bash
$ test -f cpp/src/gpuImageKernels.metal && rg -n "rgbToGrayKernel|laplacianKernel|histogramKernel|reduceLaplacianKernel" cpp/src/gpuImageKernels.metal
# Expected output includes all four kernel names.
```

✅ **Done when:** The shader file exists and contains all four kernels.

---

## Task 2: Wire shader resource into CMake build output

**Goal:** Ensure the executable and tests can load `gpuImageKernels.metal` from the build directory at runtime.

**Files touched:**

- `cpp/CMakeLists.txt` — copy Metal shader beside built executables.

#### Step 1 — Implement

Edit `cpp/CMakeLists.txt` by adding this block after `add_executable(rawViewer ${SOURCES})`:

```cmake
set(GPU_IMAGE_KERNELS ${CMAKE_CURRENT_SOURCE_DIR}/src/gpuImageKernels.metal)
add_custom_command(TARGET rawViewer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${GPU_IMAGE_KERNELS}
        $<TARGET_FILE_DIR:rawViewer>/gpuImageKernels.metal
)
```

Inside the `if(RAWVIEWER_BUILD_TESTS)` block, add this block immediately after `add_executable(rawViewerTests ...)`:

```cmake
add_custom_command(TARGET rawViewerTests POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${GPU_IMAGE_KERNELS}
        $<TARGET_FILE_DIR:rawViewerTests>/gpuImageKernels.metal
)
```

#### Step 2 — Write tests based on the plan goal

No C++ test is needed for file copying. Use a build-output assertion.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests && test -f cpp/build/gpuImageKernels.metal
# Expected: build succeeds and test command exits 0.
```

✅ **Done when:** `cpp/build/gpuImageKernels.metal` exists after building `rawViewerTests`.

---

## Task 3: Replace analyzer dispatch with Metal-only product path and reject unsupported config

**Goal:** Product image analysis has no CPU/auto path, and config rejects non-metal analysis backend plus non-3x3 Laplacian.

**Files touched:**

- `cpp/src/imageAnalyzer.cpp` — always delegate to Metal analyzer.
- `cpp/src/configLoader.cpp` — enforce GPU-only analysis config.
- `cpp/config.yaml` — set and document metal-only config.
- `cpp/include/taskState.h` — default backend marker is metal.
- `cpp/src/taskState.cpp` — parsing remains compatible but non-metal should not be accepted by config loader.

#### Step 1 — Implement

Replace `cpp/src/imageAnalyzer.cpp` with:

```cpp
/*
 * Author: wilbur
 * Version: 2.0
 * Date: 2026-06-01
 * Description: 使用 macOS Metal GPU-only 路径分析 JPG，不再提供 CPU 或 auto fallback
 */

#include "imageAnalyzer.h"
#include "macImageAnalyzer.h"

AnalyzeResult ImageAnalyzer::analyze(const AnalyzeTask& task, const AppConfig& config) const {
    return analyzeWithMacMetal(task, config);
}
```

In `cpp/include/taskState.h`, change defaults:

```cpp
struct ImageProcessingConfig {
    ImageBackend analysisBackend = ImageBackend::Metal;
    ImageBackend rawBackend = ImageBackend::Metal;
    bool logBackend = true;
};

struct AnalyzeResult {
    bool success = false;
    std::string photoId;
    std::string jpgPath;
    int attempts = 0;
    std::string error;
    std::string backendUsed = "metal";
```

In `cpp/src/configLoader.cpp`, after reading `kernelSize`, replace the old odd-size acceptance with:

```cpp
    if (kernelSize != 3) {
        throw std::runtime_error("Invalid config field: blur_detection.laplacian_kernel_size; GPU analyzer supports 3 only");
    }
    config.blurDetection.laplacianKernelSize = kernelSize;
```

After parsing `imageProcessing`, enforce metal:

```cpp
    config.imageProcessing.analysisBackend = readImageBackend(
        imageProcessing["analysis_backend"], "image_processing.analysis_backend");
    if (config.imageProcessing.analysisBackend != ImageBackend::Metal) {
        throw std::runtime_error("Invalid config field: image_processing.analysis_backend; only metal is supported");
    }
    config.imageProcessing.rawBackend = readImageBackend(
        imageProcessing["raw_backend"], "image_processing.raw_backend");
    if (config.imageProcessing.rawBackend != ImageBackend::Metal) {
        throw std::runtime_error("Invalid config field: image_processing.raw_backend; only metal is supported by configuration");
    }
```

Update `cpp/config.yaml` image processing block to:

```yaml
image_processing:
  # M-series macOS only. Image analysis uses Metal GPU exclusively.
  # CPU / auto fallback is intentionally not supported.
  analysis_backend: metal
  raw_backend: metal
  log_backend: true
```

#### Step 2 — Write tests based on the plan goal

Update `cpp/tests/configLoaderTests.cpp` so valid backend tests only use metal and invalid backend tests verify cpu/auto rejection. The complete relevant behavior must include:

```cpp
static bool configLoaderAcceptsMetalOnlyBackends() {
    std::string path = writeTempConfig(makeConfigText("metal", "metal"));
    AppConfig config = ConfigLoader().loadFromFile(path);
    TEST_REQUIRE(config.imageProcessing.analysisBackend == ImageBackend::Metal);
    TEST_REQUIRE(config.imageProcessing.rawBackend == ImageBackend::Metal);
    return true;
}

static bool configLoaderRejectsCpuAnalysisBackend() {
    std::string path = writeTempConfig(makeConfigText("cpu", "metal"));
    try {
        (void)ConfigLoader().loadFromFile(path);
    } catch (const std::runtime_error& err) {
        TEST_REQUIRE(std::string(err.what()).find("only metal is supported") != std::string::npos);
        return true;
    }
    TEST_REQUIRE(false);
    return false;
}

static bool configLoaderRejectsAutoAnalysisBackend() {
    std::string path = writeTempConfig(makeConfigText("auto", "metal"));
    try {
        (void)ConfigLoader().loadFromFile(path);
    } catch (const std::runtime_error& err) {
        TEST_REQUIRE(std::string(err.what()).find("only metal is supported") != std::string::npos);
        return true;
    }
    TEST_REQUIRE(false);
    return false;
}
```

Add these tests to the returned test list and remove tests that expect `cpu` or `auto` to be valid.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
# Expected at this task: config backend tests pass. Analyzer tests may still fail until Task 4 is complete.
```

✅ **Done when:** Config rejects CPU/auto analysis backend and product dispatch no longer contains CPU fallback code.

---

## Task 4: Implement custom Metal GPU-only analyzer

**Goal:** `analyzeWithMacMetal()` performs all pixel-level analysis on GPU, reads back only histogram and aggregate stats, and returns a complete `AnalyzeResult`.

**Files touched:**

- `cpp/src/macImageAnalyzer.mm` — replace MPS-based implementation with custom compute pipeline.

#### Step 1 — Implement

Replace the current MPS operations in `cpp/src/macImageAnalyzer.mm` with this implementation structure:

```objective-c++
/*
 * Author: wilbur
 * Version: 3.0
 * Date: 2026-06-01
 * Description: 使用自定义 Metal compute shader 完成 GPU-only JPG 分析；中间灰度和拉普拉斯数据不回传 CPU
 */
```

The implementation must include these exact C++/Objective-C++ units:

```objective-c++
struct AnalysisConfigGpu {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t totalPixels = 0;
    uint32_t overThreshold = 0;
    uint32_t underThreshold = 0;
};

struct PartialStatsGpu {
    float sum = 0.0f;
    float sumSq = 0.0f;
    float minVal = 0.0f;
    float maxVal = 0.0f;
};
```

Runtime shader loading must search these paths in order:

```objective-c++
static NSString* shaderPath() {
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* bundled = [bundle pathForResource:@"gpuImageKernels" ofType:@"metal"];
    if (bundled != nil) return bundled;
    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString* cwdPath = [cwd stringByAppendingPathComponent:@"gpuImageKernels.metal"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cwdPath]) return cwdPath;
    NSString* exeDir = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString* exePath = [exeDir stringByAppendingPathComponent:@"gpuImageKernels.metal"];
    return exePath;
}
```

The analyzer must:

1. Create `MTLDevice`, `MTLCommandQueue`, and `CIContext`.
2. Load `gpuImageKernels.metal` with `newLibraryWithSource:options:error:`.
3. Create compute pipelines for `rgbToGrayKernel`, `laplacianKernel`, `histogramKernel`, `reduceLaplacianKernel`.
4. Decode with Core Image and render to `MTLPixelFormatRGBA8Unorm` texture.
5. Allocate:
   - `grayBuffer`: `width * height` bytes.
   - `laplacianBuffer`: `width * height * sizeof(float)`.
   - `histogramBuffer`: `256 * sizeof(uint32_t)`.
   - `exposureCountsBuffer`: `2 * sizeof(uint32_t)`.
   - `partialStatsBuffer`: `groupCount * sizeof(PartialStatsGpu)`.
   - `configBuffer`: `sizeof(AnalysisConfigGpu)`.
6. Zero `histogramBuffer` and `exposureCountsBuffer` before dispatch.
7. Dispatch kernels in this order in one command buffer:
   - RGB to gray.
   - Laplacian.
   - Histogram/exposure.
   - Laplacian reduction.
8. Commit and wait.
9. Read back only histogram, exposure counts, and partial stats.
10. Combine partial stats on CPU into `sum`, `sumSq`, `min`, `max`.
11. Fill `AnalyzeResult` with backend `metal`.

Use these dispatch constants:

```objective-c++
constexpr NSUInteger kThreadsPerGroup1d = 256;
MTLSize threads1d = MTLSizeMake(kThreadsPerGroup1d, 1, 1);
MTLSize groups1d = MTLSizeMake((totalPixels + kThreadsPerGroup1d - 1) / kThreadsPerGroup1d, 1, 1);

MTLSize threads2d = MTLSizeMake(16, 16, 1);
MTLSize groups2d = MTLSizeMake((width + 15) / 16, (height + 15) / 16, 1);
```

CPU aggregation must be:

```cpp
double sum = 0.0;
double sumSq = 0.0;
double minVal = std::numeric_limits<double>::infinity();
double maxVal = -std::numeric_limits<double>::infinity();
for (NSUInteger i = 0; i < groupCount; ++i) {
    const PartialStatsGpu& s = partialStats[i];
    sum += s.sum;
    sumSq += s.sumSq;
    minVal = std::min(minVal, static_cast<double>(s.minVal));
    maxVal = std::max(maxVal, static_cast<double>(s.maxVal));
}
double mean = totalPixels > 0 ? sum / static_cast<double>(totalPixels) : 0.0;
double variance = totalPixels > 0 ? sumSq / static_cast<double>(totalPixels) - mean * mean : 0.0;
variance = std::max(0.0, variance);
```

Do not call `getBytes` on gray or laplacian buffers. Only use `[histogramBuffer contents]`, `[exposureCountsBuffer contents]`, and `[partialStatsBuffer contents]` after command completion.

#### Step 2 — Write tests based on the plan goal

Integration tests are written in Task 5. In this task, add no separate test file.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests
# Expected: rawViewerTests builds successfully with the new Objective-C++ analyzer.
```

✅ **Done when:** Build succeeds and `macImageAnalyzer.mm` contains no MPS analyzer calls for core pixel analysis.

---

## Task 5: Replace analyzer tests with GPU-only product tests and CPU reference checks

**Goal:** Tests prove the GPU-only product analyzer matches a test-local CPU reference for histogram, exposure, Laplacian stats, and final decisions.

**Files touched:**

- `cpp/tests/imageAnalyzerTests.cpp` — GPU analyzer behavioral tests.
- `cpp/tests/imageAnalyzerBackendTests.cpp` — Metal-only backend tests.

#### Step 1 — Implement

In `cpp/tests/imageAnalyzerTests.cpp`, keep test image creation but add a local CPU reference helper using OpenCV directly. The helper must not call `ImageAnalyzer` with a CPU backend.

Required helper behavior:

```cpp
struct ReferenceAnalysis {
    std::vector<int64_t> bins;
    int64_t totalPixels = 0;
    int64_t overCount = 0;
    int64_t underCount = 0;
    double overRatio = 0.0;
    double underRatio = 0.0;
    std::string exposureStatus = "normal";
    double mean = 0.0;
    double variance = 0.0;
    double stddev = 0.0;
    double minVal = 0.0;
    double maxVal = 0.0;
    bool isBlurry = false;
};
```

Reference must use the same explicit math as the shader:

```cpp
int gray = static_cast<int>(std::floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5));
gray = std::clamp(gray, 0, 255);
```

Reference Laplacian must use clamp-to-edge with kernel:

```text
center * 4 - left - right - up - down
```

Add tests:

- `imageAnalyzer.gpuDetectsUnderexposedBlackImage`
- `imageAnalyzer.gpuDetectsOverexposedWhiteImage`
- `imageAnalyzer.gpuMatchesReferenceForCheckerImage`
- `imageAnalyzer.gpuMatchesReferenceForGradientImage`

Each test must assert:

```cpp
TEST_REQUIRE(result.success);
TEST_REQUIRE(result.backendUsed == "metal");
TEST_REQUIRE(result.histogramData.totalPixels == ref.totalPixels);
TEST_REQUIRE(result.histogramData.bins == ref.bins);
TEST_REQUIRE(result.histogramData.overexposePixelCount == ref.overCount);
TEST_REQUIRE(result.histogramData.underexposePixelCount == ref.underCount);
TEST_REQUIRE(result.exposureStatus == ref.exposureStatus);
TEST_REQUIRE(result.isBlurry == ref.isBlurry);
TEST_REQUIRE(std::abs(result.laplacianData.variance - ref.variance) <= std::max(1.0, ref.variance) * 0.001);
```

In `cpp/tests/imageAnalyzerBackendTests.cpp`, remove CPU/auto tests and keep only:

```cpp
static bool imageAnalyzerAlwaysUsesMetalBackend() {
    std::string path = writeBackendImage("rawviewer-backend-metal-only.jpg");
    AnalyzeResult result = ImageAnalyzer().analyze(makeBackendTask(path), makeBackendConfig(ImageBackend::Metal));
    TEST_REQUIRE(result.success);
    TEST_REQUIRE(result.backendUsed == "metal");
    return true;
}
```

The returned test list must contain only Metal-only backend behavior tests.

#### Step 2 — Write tests based on the plan goal

The tests are part of Step 1 and must be committed with implementation.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
# Expected output:
# PASS configLoader.acceptsMetalOnlyBackends
# PASS configLoader.rejectsCpuAnalysisBackend
# PASS configLoader.rejectsAutoAnalysisBackend
# PASS gpuSupport.returnsUsableResult
# PASS gpuSupport.cpuBackendIsAlwaysValidFallback
# PASS imageAnalyzer.gpuDetectsUnderexposedBlackImage
# PASS imageAnalyzer.gpuDetectsOverexposedWhiteImage
# PASS imageAnalyzer.gpuMatchesReferenceForCheckerImage
# PASS imageAnalyzer.gpuMatchesReferenceForGradientImage
# PASS imageAnalyzerBackend.alwaysUsesMetalBackend
# PASS perfTimer.elapsedIsNonNegative
# PASS perfTimer.rawConvertTimingDefaultsAreZero
# PASS perfTimer.analyzeTimingDefaultsAreZero
# Tests run: 13, failures: 0
```

If test names differ because old config tests are removed or renamed, the required condition is still: all rawViewerTests pass with zero failures.

✅ **Done when:** All analyzer tests pass and no test uses product CPU backend.

---

## Task 6: Save backend provenance in JSON and verify logs still show Metal

**Goal:** Analysis outputs persist `metal` backend information so users can audit that GPU-only analysis was used.

**Files touched:**

- `cpp/src/jsonManager.cpp` — save backend marker in analysis result JSON.
- `cpp/tests` if an existing JSON manager test exists; otherwise validate through integration/manual command.

#### Step 1 — Implement

In `JsonManager::updateAnalysisResult`, success branch, add:

```cpp
        p["analysis_backend"] = result.backendUsed;
```

In failure branch, add:

```cpp
        p["analysis_backend"] = result.backendUsed;
```

Do not change existing analysis raw data structure.

#### Step 2 — Write tests based on the plan goal

If no JsonManager test harness exists, use a lightweight integration validation after running the app on a temp folder containing one generated JPG. If adding a test is practical, add a test that calls `updateAnalysisResult` and asserts JSON contains `analysis_backend: metal`.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
# Expected: all tests pass with zero failures.
```

✅ **Done when:** JSON writes `analysis_backend: metal` for both success and failure analysis results, and all tests remain green.

---

## Task 7: Final GPU-only audit

**Goal:** Confirm product code has no CPU/auto image analysis path and no intermediate GPU image readback.

**Files touched:** None unless audit finds missed code.

#### Step 1 — Implement

Run these audits:

```bash
$ rg -n "analyzeWithCpu|ImageBackend::Cpu|ImageBackend::Auto|analysis_backend: auto|analysis_backend: cpu" cpp
# Expected: no product path matches. Test-only CPU reference code may appear but must not call ImageAnalyzer CPU backend.
```

```bash
$ rg -n "getBytes|contents\]" cpp/src/macImageAnalyzer.mm
# Expected: only histogramBuffer, exposureCountsBuffer and partialStatsBuffer are read back. No grayBuffer/laplacianBuffer readback.
```

```bash
$ rg -n "MPSImage|MPSImageHistogram|MPSImageConvolution|CIColorMonochrome" cpp/src/macImageAnalyzer.mm
# Expected: no matches.
```

#### Step 2 — Write tests based on the plan goal

No new tests. This is an audit task backed by full test suite.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake --build cpp/build --target rawViewerTests && ./cpp/build/rawViewerTests
# Expected: all tests pass with zero failures.
```

✅ **Done when:** Audits pass and full tests are green.

---

## Self-Review

### Spec coverage

- GPU-only product path: Task 3, Task 4, Task 7.
- No CPU/auto option: Task 3, Task 5, Task 7.
- Fix GPU/CPU mismatch: Task 4, Task 5.
- Avoid intermediate readbacks: Task 4, Task 7.
- Read back only aggregate results: Task 4, Task 7.
- CPU reference only in tests: Task 5.
- M-series macOS only: Task 0, Task 4 error handling.
- RAW conversion not GPU scope: documented in recipe; no task modifies RAW conversion.

### Placeholder scan

No `TBD`, no `TODO`, no ellipsis. Task 4 intentionally specifies required implementation structure rather than a full 400-line file because it must preserve surrounding Objective-C++ error handling and existing task metadata; all required behavior and code units are specified.

### Type consistency

- `AnalysisConfigGpu` and `PartialStatsGpu` match Metal shader structs.
- `backendUsed` remains string `metal`.
- `ImageBackend::Metal` remains available for config compatibility.

### Test completeness

- Config behavior tested for success and invalid CPU/auto cases.
- Analyzer behavior tested on black, white, checker, gradient images.
- Backend behavior tested for Metal-only product result.
- Audit verifies absence of old CPU/auto paths and absence of intermediate readbacks.
