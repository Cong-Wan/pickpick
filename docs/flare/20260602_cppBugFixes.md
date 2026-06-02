# Cpp Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the C++ rawViewer bugs reported by the user: summary `Normal` counts must mean non-blurry normal-exposure photos, RAW-to-JPG output must avoid RGB/BGR color channel errors and use camera color intent, and `analysis.log` must show non-zero precise timings for sub-millisecond work.

**Architecture:** Keep the current pipeline intact and make focused changes in the existing C++ units. Summary counting will be centralized in `taskState` so terminal output and `.cache/analysis.json` cannot drift. RAW output conversion will get a tiny OpenCV matrix helper for testable RGB-to-BGR conversion. Timing will keep existing `ms` labels but store analysis phase durations as precise double milliseconds.

**Tech Stack:** C++17, Objective-C++ for Metal analyzer, LibRaw, OpenCV, yaml-cpp, nlohmann/json, CMake.

---

## File structure

Modified files:

- `cpp/include/taskState.h` — owns shared task/result data structures; add `SummaryCounts`, `calculateSummaryCounts`, and precise `AnalyzeResult` timing field types.
- `cpp/src/taskState.cpp` — implement summary counting with the requested `Normal = analysis success && !isBlurry && exposureStatus == "normal"` rule.
- `cpp/src/appRunner.cpp` — use shared summary counts and format analysis log durations with decimal milliseconds.
- `cpp/src/jsonManager.cpp` — use shared summary counts so JSON summary matches terminal summary.
- `cpp/src/rawConverter.cpp` — set LibRaw output intent and use the new matrix helper before `cv::imwrite`.
- `cpp/include/perfTimer.h` — add precise millisecond timing while preserving existing integer timing.
- `cpp/include/imageAnalysisCore.h` — store CPU/shared analyzer phase durations as precise milliseconds.
- `cpp/src/macImageAnalyzer.mm` — store Metal analyzer phase durations as precise milliseconds.
- `cpp/CMakeLists.txt` — add new source and a small test target that matches the actual tests present.

New files:

- `cpp/include/rawJpgMat.h` — declares a testable decoded-image-to-OpenCV-JPG-write matrix helper.
- `cpp/src/rawJpgMat.cpp` — converts decoded RGB memory to BGR for OpenCV JPG writing, clones grayscale data, rejects invalid inputs.
- `cpp/tests/testMain.cpp` — lightweight test runner without an external framework.
- `cpp/tests/summaryCountsTests.cpp` — verifies summary counting semantics.
- `cpp/tests/rawJpgMatTests.cpp` — verifies RGB-to-BGR conversion and input validation.
- `cpp/tests/perfTimerTests.cpp` — verifies precise timing reports non-zero fractional milliseconds.

---

## Task 0: Environment setup

**Goal:** Confirm the C++ project builds from the current branch before bug-fix tasks begin.

**Files touched:** None.

### Step 1 — Prepare branch and build directory

```bash
$ git status --short
# Expected: shows the current working tree. If unrelated user changes are present, do not overwrite them.

$ git switch -c fix/cpp-reported-bugs
# Expected: Switched to a new branch 'fix/cpp-reported-bugs'
# If the branch already exists, use: git switch fix/cpp-reported-bugs

$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=OFF
# Expected: CMake configures successfully and writes build files to cpp/build.

$ cmake --build cpp/build
# Expected: rawViewer target builds successfully.
```

### Step 2 — Baseline executable smoke check

```bash
$ ./cpp/build/rawViewer
# Expected: exits non-zero and prints usage similar to:
# Usage: ./cpp/build/rawViewer <folder_path> [--config <config_path>] [--resume]
```

### Step 3 — Baseline test note

```bash
$ test -d cpp/tests && echo "tests exist" || echo "cpp/tests is missing"
# Expected before Task 1: cpp/tests is missing
```

There is no runnable baseline test suite because `cpp/tests` does not exist while `CMakeLists.txt` still references old test files under `RAWVIEWER_BUILD_TESTS`. Do not enable `RAWVIEWER_BUILD_TESTS` until Task 1 replaces that stale test target.

✅ **Done when:** `cmake --build cpp/build` succeeds and the executable prints usage with no folder argument.

---

## Task 1: Make summary counts consistent with the requested `Normal` meaning

**Goal:** Terminal summary and `.cache/analysis.json` both count `Normal` only when analysis succeeded, the photo is not blurry, and exposure is `normal`.

**Files touched:**

- `cpp/include/taskState.h` — add shared summary count model and declaration.
- `cpp/src/taskState.cpp` — implement shared summary count logic.
- `cpp/src/appRunner.cpp` — replace duplicated final summary counting with shared logic.
- `cpp/src/jsonManager.cpp` — replace duplicated JSON summary counting with shared logic.
- `cpp/CMakeLists.txt` — replace stale test target with a real lightweight target.
- `cpp/tests/testMain.cpp` — new test runner.
- `cpp/tests/summaryCountsTests.cpp` — summary behavior tests.

### Step 1 — Implement

Update `cpp/include/taskState.h` file header version to `1.6` and description to mention shared summary counts. Add this struct and function declaration after `PhotoTaskState`:

```cpp
struct SummaryCounts {
    int totalPhotos = 0;
    int rawConversionSuccess = 0;
    int rawConversionFailed = 0;
    int analysisSuccess = 0;
    int analysisFailed = 0;
    int pending = 0;
    int blurry = 0;
    int overexposed = 0;
    int underexposed = 0;
    int normal = 0;
};

SummaryCounts calculateSummaryCounts(const std::vector<PhotoTaskState>& states);
```

Update `cpp/src/taskState.cpp` file header version to `1.3` and description to mention shared summary counts. Add this implementation after `makeDefaultPhotoState`:

```cpp
SummaryCounts calculateSummaryCounts(const std::vector<PhotoTaskState>& states) {
    SummaryCounts summary;
    summary.totalPhotos = static_cast<int>(states.size());

    for (const auto& state : states) {
        if (state.rawConversionStatus == StageStatus::Success) summary.rawConversionSuccess++;
        if (state.rawConversionStatus == StageStatus::Failed) summary.rawConversionFailed++;
        if (state.analysisStatus == StageStatus::Success) summary.analysisSuccess++;
        if (state.analysisStatus == StageStatus::Failed) summary.analysisFailed++;

        if (state.rawConversionStatus == StageStatus::Pending || state.rawConversionStatus == StageStatus::Running ||
            state.analysisStatus == StageStatus::Pending || state.analysisStatus == StageStatus::Running) {
            summary.pending++;
        }

        if (state.analysisStatus != StageStatus::Success) {
            continue;
        }

        if (state.isBlurry) summary.blurry++;
        if (state.exposureStatus == "overexposed") summary.overexposed++;
        if (state.exposureStatus == "underexposed") summary.underexposed++;
        if (!state.isBlurry && state.exposureStatus == "normal") summary.normal++;
    }

    return summary;
}
```

Update `cpp/src/appRunner.cpp` file header version to `1.4` and description to mention shared summary counts. Replace the final summary loop with this complete block:

```cpp
    // Final summary
    emitProgress(options, RunPhase::Organizing, 0, 0, kOrganizingEnd);
    states = jsonManager.getAllPhotoStates();
    SummaryCounts counts = calculateSummaryCounts(states);
    RunSummary summary;
    summary.totalPhotos = counts.totalPhotos;
    summary.rawConversionSuccess = counts.rawConversionSuccess;
    summary.rawConversionFailed = counts.rawConversionFailed;
    summary.analysisSuccess = counts.analysisSuccess;
    summary.analysisFailed = counts.analysisFailed;
    summary.pending = counts.pending;
    summary.blurry = counts.blurry;
    summary.overexposed = counts.overexposed;
    summary.underexposed = counts.underexposed;
    summary.normal = counts.normal;

    jsonManager.atomicSave();
    emitProgress(options, RunPhase::Completed, summary.totalPhotos, summary.totalPhotos, kCompleted);
    return summary;
```

Update `cpp/src/jsonManager.cpp` file header version to `1.3` and description to mention shared summary counts. Replace `JsonManager::Impl::updateSummary()` with this complete function body:

```cpp
    void updateSummary() {
        std::vector<PhotoTaskState> states;
        for (auto& [key, val] : root_["photos"].items()) {
            PhotoTaskState state;
            state.photoId = (val.contains("photo_id") && !val["photo_id"].is_null()) ? val["photo_id"].get<std::string>() : key;
            std::string rawStatus = (val.contains("raw_conversion_status") && !val["raw_conversion_status"].is_null())
                ? val["raw_conversion_status"].get<std::string>()
                : "pending";
            std::string analysisStatus = (val.contains("analysis_status") && !val["analysis_status"].is_null())
                ? val["analysis_status"].get<std::string>()
                : "pending";
            state.rawConversionStatus = stageStatusFromString(rawStatus);
            state.analysisStatus = stageStatusFromString(analysisStatus);
            state.isBlurry = (val.contains("is_blurry") && !val["is_blurry"].is_null()) ? val["is_blurry"].get<bool>() : false;
            state.exposureStatus = (val.contains("exposure_status") && !val["exposure_status"].is_null())
                ? val["exposure_status"].get<std::string>()
                : "normal";
            states.push_back(state);
        }

        SummaryCounts counts = calculateSummaryCounts(states);
        auto& sum = root_["summary"];
        sum["total_photos"] = counts.totalPhotos;
        sum["raw_conversion_success"] = counts.rawConversionSuccess;
        sum["raw_conversion_failed"] = counts.rawConversionFailed;
        sum["analysis_success"] = counts.analysisSuccess;
        sum["analysis_failed"] = counts.analysisFailed;
        sum["pending"] = counts.pending;
        sum["blurry"] = counts.blurry;
        sum["overexposed"] = counts.overexposed;
        sum["underexposed"] = counts.underexposed;
        sum["normal"] = counts.normal;
    }
```

Update the `RAWVIEWER_BUILD_TESTS` block in `cpp/CMakeLists.txt` to this complete block:

```cmake
if(RAWVIEWER_BUILD_TESTS)
    add_executable(rawViewerTests
        src/taskState.cpp
        tests/testMain.cpp
        tests/summaryCountsTests.cpp
    )

    target_include_directories(rawViewerTests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )
endif()
```

Create `cpp/tests/testMain.cpp`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 提供 rawViewer C++ 轻量测试入口，逐个执行无外部框架的单元测试
 */

#include <exception>
#include <iostream>

int runSummaryCountsTests();

int main() {
    try {
        int failed = 0;
        failed += runSummaryCountsTests();
        if (failed != 0) {
            std::cerr << "rawViewerTests failed=" << failed << std::endl;
            return 1;
        }
        std::cout << "rawViewerTests passed" << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "rawViewerTests exception: " << e.what() << std::endl;
        return 1;
    }
}
```

Create `cpp/tests/summaryCountsTests.cpp`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 验证 summary 统计口径，Normal 只统计非虚焦且曝光正常的分析成功照片
 */

#include "taskState.h"
#include <iostream>
#include <string>
#include <vector>

namespace {

int expectEqual(int actual, int expected, const std::string& name) {
    if (actual == expected) {
        return 0;
    }
    std::cerr << name << " expected=" << expected << " actual=" << actual << std::endl;
    return 1;
}

PhotoTaskState makeState(StageStatus rawStatus, StageStatus analysisStatus, bool isBlurry, const std::string& exposureStatus) {
    PhotoTaskState state;
    state.rawConversionStatus = rawStatus;
    state.analysisStatus = analysisStatus;
    state.isBlurry = isBlurry;
    state.exposureStatus = exposureStatus;
    return state;
}

int testNormalExcludesBlurryAndBadExposure() {
    std::vector<PhotoTaskState> states;
    states.push_back(makeState(StageStatus::Skipped, StageStatus::Success, false, "normal"));
    states.push_back(makeState(StageStatus::Skipped, StageStatus::Success, true, "normal"));
    states.push_back(makeState(StageStatus::Skipped, StageStatus::Success, false, "overexposed"));
    states.push_back(makeState(StageStatus::Skipped, StageStatus::Success, false, "underexposed"));
    states.push_back(makeState(StageStatus::Failed, StageStatus::Failed, false, "normal"));
    states.push_back(makeState(StageStatus::Pending, StageStatus::Pending, false, "normal"));

    SummaryCounts counts = calculateSummaryCounts(states);
    int failed = 0;
    failed += expectEqual(counts.totalPhotos, 6, "totalPhotos");
    failed += expectEqual(counts.rawConversionFailed, 1, "rawConversionFailed");
    failed += expectEqual(counts.analysisSuccess, 4, "analysisSuccess");
    failed += expectEqual(counts.analysisFailed, 1, "analysisFailed");
    failed += expectEqual(counts.pending, 1, "pending");
    failed += expectEqual(counts.blurry, 1, "blurry");
    failed += expectEqual(counts.overexposed, 1, "overexposed");
    failed += expectEqual(counts.underexposed, 1, "underexposed");
    failed += expectEqual(counts.normal, 1, "normal");
    return failed;
}

int testUnanalyzedDefaultsDoNotCountAsNormal() {
    std::vector<PhotoTaskState> states;
    states.push_back(makeState(StageStatus::Skipped, StageStatus::Pending, false, "normal"));

    SummaryCounts counts = calculateSummaryCounts(states);
    int failed = 0;
    failed += expectEqual(counts.analysisSuccess, 0, "pending analysisSuccess");
    failed += expectEqual(counts.normal, 0, "pending normal");
    failed += expectEqual(counts.pending, 1, "pending count");
    return failed;
}

}  // namespace

int runSummaryCountsTests() {
    int failed = 0;
    failed += testNormalExcludesBlurryAndBadExposure();
    failed += testUnanalyzedDefaultsDoNotCountAsNormal();
    return failed;
}
```

### Step 2 — Write tests based on the plan goal

The tests are the complete `cpp/tests/testMain.cpp` and `cpp/tests/summaryCountsTests.cpp` files from Step 1. They verify:

- A blurry normal-exposure photo increments `Blurry` but not `Normal`.
- Overexposed and underexposed photos do not increment `Normal`.
- Pending/un-analyzed photos do not count as `Normal`.
- Pending and failed counters preserve existing behavior.

### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON
# Expected: CMake configures successfully.

$ cmake --build cpp/build
# Expected: rawViewer and rawViewerTests build successfully.

$ ./cpp/build/rawViewerTests
# Expected output:
# rawViewerTests passed
```

If any test fails, fix the implementation. Do not weaken the tests.

✅ **Done when:** `./cpp/build/rawViewerTests` prints `rawViewerTests passed` and `cmake --build cpp/build` succeeds.

---

## Task 2: Fix RAW-to-JPG color channel handling and LibRaw output intent

**Goal:** RAW conversion writes JPGs with OpenCV's expected BGR channel order while LibRaw processing uses camera white balance, sRGB output, and 8-bit data for JPG writing.

**Files touched:**

- `cpp/include/rawJpgMat.h` — new testable helper declaration.
- `cpp/src/rawJpgMat.cpp` — new helper implementation.
- `cpp/src/rawConverter.cpp` — use LibRaw output settings and helper before writing JPG.
- `cpp/CMakeLists.txt` — add helper source to app and tests.
- `cpp/tests/testMain.cpp` — call RAW JPG matrix tests.
- `cpp/tests/rawJpgMatTests.cpp` — verify channel conversion.

### Step 1 — Implement

Create `cpp/include/rawJpgMat.h`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 声明解码图片内存转 OpenCV JPG 写入矩阵的辅助函数，确保 RGB 数据按 BGR 写出
 */

#pragma once

#include <opencv2/core.hpp>

cv::Mat makeJpgWriteMatFromDecodedImage(int height, int width, int colors, const void* data);
```

Create `cpp/src/rawJpgMat.cpp`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 实现解码图片内存到 OpenCV JPG 写入矩阵的转换，RGB 输入转换为 BGR，灰度输入复制保留
 */

#include "rawJpgMat.h"
#include <opencv2/imgproc.hpp>
#include <stdexcept>

cv::Mat makeJpgWriteMatFromDecodedImage(int height, int width, int colors, const void* data) {
    if (height <= 0 || width <= 0) {
        throw std::invalid_argument("Decoded image size must be positive");
    }
    if (data == nullptr) {
        throw std::invalid_argument("Decoded image data must not be null");
    }

    if (colors == 3) {
        cv::Mat rgb(height, width, CV_8UC3, const_cast<void*>(data));
        cv::Mat bgr;
        cv::cvtColor(rgb, bgr, cv::COLOR_RGB2BGR);
        return bgr;
    }

    if (colors == 1) {
        cv::Mat gray(height, width, CV_8UC1, const_cast<void*>(data));
        return gray.clone();
    }

    throw std::invalid_argument("Decoded image must have 1 or 3 channels");
}
```

Update `cpp/src/rawConverter.cpp` file header version to `1.2` and description to mention camera WB, sRGB, and RGB-to-BGR output. Add include:

```cpp
#include "rawJpgMat.h"
```

After successful `open_file` and before `unpack`, set LibRaw parameters:

```cpp
    rawProcessor.imgdata.params.use_camera_wb = 1;
    rawProcessor.imgdata.params.use_auto_wb = 0;
    rawProcessor.imgdata.params.output_color = 1;
    rawProcessor.imgdata.params.output_bps = 8;
```

Replace the current `cv::Mat mat` creation block with this complete block:

```cpp
    cv::Mat mat;
    try {
        mat = makeJpgWriteMatFromDecodedImage(img->height, img->width, img->colors, img->data);
    } catch (const std::exception& e) {
        result.success = false;
        result.error = "Unsupported decoded RAW image: " + std::string(e.what());
        rawProcessor.dcraw_clear_mem(img);
        return result;
    }
```

Update `cpp/CMakeLists.txt`:

- Add `src/rawJpgMat.cpp` to the main `SOURCES` list.
- Replace the current `RAWVIEWER_BUILD_TESTS` block with this complete block:

```cmake
if(RAWVIEWER_BUILD_TESTS)
    add_executable(rawViewerTests
        src/rawJpgMat.cpp
        src/taskState.cpp
        tests/testMain.cpp
        tests/summaryCountsTests.cpp
        tests/rawJpgMatTests.cpp
    )

    target_include_directories(rawViewerTests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )

    target_link_libraries(rawViewerTests PRIVATE
        opencv_imgproc
        opencv_core
        ${OPENCV_3RDPARTY_LIBS}
    )

    if(APPLE)
        target_link_libraries(rawViewerTests PRIVATE
            ${FOUNDATION_LIBRARY}
            ${APPKIT_LIBRARY}
            ${COREGRAPHICS_LIBRARY}
            ${COREIMAGE_LIBRARY}
            ${METAL_LIBRARY}
            ${MPS_LIBRARY}
            ${OPENCL_LIBRARY}
            ${ACCELERATE_LIBRARY}
        )
    endif()
endif()
```

Update `cpp/tests/testMain.cpp` to declare and run the new test:

```cpp
int runRawJpgMatTests();
```

The `main` body must include:

```cpp
        failed += runRawJpgMatTests();
```

Create `cpp/tests/rawJpgMatTests.cpp`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 验证 RAW 解码图像写 JPG 前的 OpenCV 矩阵转换，确保 RGB 输入转换为 BGR
 */

#include "rawJpgMat.h"
#include <cstdint>
#include <exception>
#include <iostream>
#include <string>

namespace {

int expectEqual(int actual, int expected, const std::string& name) {
    if (actual == expected) {
        return 0;
    }
    std::cerr << name << " expected=" << expected << " actual=" << actual << std::endl;
    return 1;
}

int testRgbInputBecomesBgrForOpenCvWrite() {
    uint8_t rgb[6] = {
        10, 20, 30,
        40, 50, 60
    };
    cv::Mat bgr = makeJpgWriteMatFromDecodedImage(1, 2, 3, rgb);
    int failed = 0;
    failed += expectEqual(bgr.rows, 1, "bgr rows");
    failed += expectEqual(bgr.cols, 2, "bgr cols");
    cv::Vec3b first = bgr.at<cv::Vec3b>(0, 0);
    cv::Vec3b second = bgr.at<cv::Vec3b>(0, 1);
    failed += expectEqual(first[0], 30, "first blue");
    failed += expectEqual(first[1], 20, "first green");
    failed += expectEqual(first[2], 10, "first red");
    failed += expectEqual(second[0], 60, "second blue");
    failed += expectEqual(second[1], 50, "second green");
    failed += expectEqual(second[2], 40, "second red");
    return failed;
}

int testGrayInputIsCloned() {
    uint8_t gray[1] = {123};
    cv::Mat mat = makeJpgWriteMatFromDecodedImage(1, 1, 1, gray);
    gray[0] = 9;
    return expectEqual(mat.at<uint8_t>(0, 0), 123, "gray clone value");
}

int testInvalidInputThrows() {
    try {
        uint8_t data[1] = {0};
        (void)makeJpgWriteMatFromDecodedImage(1, 1, 4, data);
        std::cerr << "invalid colors did not throw" << std::endl;
        return 1;
    } catch (const std::invalid_argument&) {
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "unexpected exception: " << e.what() << std::endl;
        return 1;
    }
}

}  // namespace

int runRawJpgMatTests() {
    int failed = 0;
    failed += testRgbInputBecomesBgrForOpenCvWrite();
    failed += testGrayInputIsCloned();
    failed += testInvalidInputThrows();
    return failed;
}
```

### Step 2 — Write tests based on the plan goal

The tests are the complete `cpp/tests/rawJpgMatTests.cpp` updates from Step 1. They verify:

- A decoded RGB pixel `[R=10,G=20,B=30]` becomes OpenCV BGR `[B=30,G=20,R=10]`.
- Grayscale decoded data is cloned so clearing LibRaw memory cannot invalidate the write matrix.
- Unsupported channel counts fail explicitly.

### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON
# Expected: CMake configures successfully.

$ cmake --build cpp/build
# Expected: rawViewer and rawViewerTests build successfully.

$ ./cpp/build/rawViewerTests
# Expected output:
# rawViewerTests passed
```

Manual RAW color smoke check, using the user's sample folder:

```bash
$ ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --config cpp/config.yaml
# Expected: RAW conversion succeeds. JPG previews should no longer show RGB/BGR channel-swap style color errors.
```

LibRaw rendering is not expected to match macOS Preview pixel-for-pixel because Preview uses Apple's RAW engine and tone mapping.

✅ **Done when:** unit tests pass, build succeeds, and converted JPGs no longer show obvious red/blue channel swapped color.

---

## Task 3: Make `analysis.log` show precise non-zero timings

**Goal:** `analysis.log` records analysis phase durations as decimal milliseconds such as `0.342ms` instead of truncating sub-millisecond work to `0ms`.

**Files touched:**

- `cpp/include/perfTimer.h` — add precise millisecond timing API.
- `cpp/include/taskState.h` — change `AnalyzeResult` timing fields to `double` milliseconds.
- `cpp/include/imageAnalysisCore.h` — use precise timing in shared analysis helper.
- `cpp/src/macImageAnalyzer.mm` — use precise timing in Metal analyzer.
- `cpp/src/appRunner.cpp` — format analysis logs and summary with decimal milliseconds.
- `cpp/CMakeLists.txt` — add perf timer tests to test target.
- `cpp/tests/testMain.cpp` — call perf timer tests.
- `cpp/tests/perfTimerTests.cpp` — verify precise timing.

### Step 1 — Implement

Update `cpp/include/perfTimer.h` file header version to `1.1` and description to mention precise millisecond timing. Add this method to `PerfTimer` after `elapsedMs()`:

```cpp
    double elapsedMsPrecise() const {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start_).count();
    }
```

Update `cpp/include/taskState.h` file header version to `1.7` and description to mention precise analysis timings. In `AnalyzeResult`, replace these fields:

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

with:

```cpp
    double readImageMs = 0.0;
    double grayMs = 0.0;
    double laplacianMs = 0.0;
    double statsMs = 0.0;
    double histogramMs = 0.0;
    double renderImageMs = 0.0;
    double gpuEncodeMs = 0.0;
    double gpuWaitMs = 0.0;
    double totalWallMs = 0.0;
```

Update `cpp/include/imageAnalysisCore.h` file header version to `1.1` and description to mention precise timing. Replace all `phaseTimer.elapsedMs()` assignments to `AnalyzeResult` timing fields with `phaseTimer.elapsedMsPrecise()`:

```cpp
    result.laplacianMs = phaseTimer.elapsedMsPrecise();
```

```cpp
    result.statsMs = phaseTimer.elapsedMsPrecise();
```

```cpp
    result.histogramMs = phaseTimer.elapsedMsPrecise();
```

Update `cpp/src/macImageAnalyzer.mm` file header version to `3.4` and description to mention decimal millisecond timing. Replace all assignments from `elapsedMs()` into `AnalyzeResult` timing fields with `elapsedMsPrecise()`. The replacements are:

```cpp
            result.totalWallMs = totalTimer.elapsedMsPrecise();
```

```cpp
            result.readImageMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.renderImageMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.grayMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.laplacianMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.histogramMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.statsMs = phaseTimer.elapsedMsPrecise();
```

```cpp
            result.gpuWaitMs = phaseTimer.elapsedMsPrecise();
```

The local variable for encoded time must become:

```cpp
            double encodeMs = 0.0;
```

Update every remaining `result.totalWallMs = totalTimer.elapsedMs();` in `macImageAnalyzer.mm` to:

```cpp
            result.totalWallMs = totalTimer.elapsedMsPrecise();
```

Update the catch block assignment to:

```cpp
            result.totalWallMs = totalTimer.elapsedMsPrecise();
```

Update `cpp/src/appRunner.cpp`:

- Add include:

```cpp
#include <iomanip>
```

- In the analysis phase, replace:

```cpp
        int64_t totalElapsedMs = 0;
```

with:

```cpp
        double totalElapsedMs = 0.0;
```

- Replace the `elapsedMs` calculation with:

```cpp
            double elapsedMs = anaResult.totalWallMs > 0.0
                ? anaResult.totalWallMs
                : anaResult.readImageMs + anaResult.renderImageMs + anaResult.grayMs + anaResult.laplacianMs +
                  anaResult.statsMs + anaResult.histogramMs + anaResult.gpuWaitMs;
```

- Before writing analysis timing fields, set fixed precision for timing values. Replace the current analysis `logFile <<` chain with this complete block:

```cpp
                auto oldFlags = logFile.flags();
                auto oldPrecision = logFile.precision();
                logFile << std::fixed << std::setprecision(3)
                        << "[" << tsBuf << "] photo=" << anaResult.photoId
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
                        << " total_wall=" << anaResult.totalWallMs << "ms";
                logFile.flags(oldFlags);
                logFile.precision(oldPrecision);
                logFile << " attempts=" << anaResult.attempts
                        << " success=" << (anaResult.success ? "true" : "false");
```

- Replace analysis summary average output with decimal formatting:

```cpp
            logFile << "=== Analysis Summary ===\n";
            logFile << "total_photos=" << logCount << "\n";
            auto oldFlags = logFile.flags();
            auto oldPrecision = logFile.precision();
            logFile << std::fixed << std::setprecision(3)
                    << "total_time_ms=" << totalElapsedMs << "\n"
                    << "average_time_ms=" << (totalElapsedMs / static_cast<double>(logCount)) << "\n";
            logFile.flags(oldFlags);
            logFile.precision(oldPrecision);
            logFile.flush();
```

Update `cpp/CMakeLists.txt` test block to include `tests/perfTimerTests.cpp`:

```cmake
if(RAWVIEWER_BUILD_TESTS)
    add_executable(rawViewerTests
        src/rawJpgMat.cpp
        src/taskState.cpp
        tests/testMain.cpp
        tests/summaryCountsTests.cpp
        tests/rawJpgMatTests.cpp
        tests/perfTimerTests.cpp
    )

    target_include_directories(rawViewerTests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )

    target_link_libraries(rawViewerTests PRIVATE
        opencv_imgproc
        opencv_core
        ${OPENCV_3RDPARTY_LIBS}
    )

    if(APPLE)
        target_link_libraries(rawViewerTests PRIVATE
            ${FOUNDATION_LIBRARY}
            ${APPKIT_LIBRARY}
            ${COREGRAPHICS_LIBRARY}
            ${COREIMAGE_LIBRARY}
            ${METAL_LIBRARY}
            ${MPS_LIBRARY}
            ${OPENCL_LIBRARY}
            ${ACCELERATE_LIBRARY}
        )
    endif()
endif()
```

Update `cpp/tests/testMain.cpp` to declare and run the new test:

```cpp
int runPerfTimerTests();
```

The `main` body must include:

```cpp
        failed += runPerfTimerTests();
```

Create `cpp/tests/perfTimerTests.cpp`:

```cpp
/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 验证 PerfTimer 精细毫秒计时，避免亚毫秒阶段在日志中全部显示为 0ms
 */

#include "perfTimer.h"
#include <chrono>
#include <iostream>
#include <thread>

int runPerfTimerTests() {
    PerfTimer timer;
    std::this_thread::sleep_for(std::chrono::microseconds(500));
    double preciseMs = timer.elapsedMsPrecise();
    if (preciseMs <= 0.0) {
        std::cerr << "elapsedMsPrecise should be positive, actual=" << preciseMs << std::endl;
        return 1;
    }
    if (preciseMs > 100.0) {
        std::cerr << "elapsedMsPrecise unexpectedly large, actual=" << preciseMs << std::endl;
        return 1;
    }
    return 0;
}
```

### Step 2 — Write tests based on the plan goal

The tests are the complete `cpp/tests/perfTimerTests.cpp` updates from Step 1. They verify that precise timing reports positive fractional-duration work instead of being limited to integer millisecond truncation.

### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON
# Expected: CMake configures successfully.

$ cmake --build cpp/build
# Expected: rawViewer and rawViewerTests build successfully.

$ ./cpp/build/rawViewerTests
# Expected output:
# rawViewerTests passed
```

Manual log smoke check:

```bash
$ ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --config cpp/config.yaml
# Expected: .cache/analysis.log contains timing fields with three decimal places, for example:
# elapsed=2.417ms read_image=0.183ms gray=0.021ms gpu_wait=1.284ms total_wall=2.417ms
```

✅ **Done when:** unit tests pass, build succeeds, and `analysis.log` no longer displays every processing field as integer `0ms`.

---

## Task 4: End-to-end validation on the reported folder

**Goal:** Confirm all three user-reported bugs are fixed in the actual CLI workflow.

**Files touched:** None unless validation exposes a defect in prior tasks.

### Step 1 — Implement

No implementation is required. Build the final executable:

```bash
$ cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON
# Expected: CMake configures successfully.

$ cmake --build cpp/build
# Expected: rawViewer and rawViewerTests build successfully.
```

### Step 2 — Write tests based on the plan goal

Run the already-created unit tests and the user-folder smoke test:

```bash
$ ./cpp/build/rawViewerTests
# Expected output:
# rawViewerTests passed

$ ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --config cpp/config.yaml
# Expected: CLI completes with Summary printed.
```

Check these observable outcomes:

```bash
$ grep -E "elapsed=|read_image=|gpu_wait=|total_wall=" /Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.log | head -n 3
# Expected: timing values include decimal milliseconds, not only 0ms.

$ python3 - <<'PY'
import json
from pathlib import Path
p = Path('/Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.json')
data = json.loads(p.read_text())
photos = data['photos'].values()
normal = sum(1 for x in photos if x.get('analysis_status') == 'success' and not x.get('is_blurry') and x.get('exposure_status') == 'normal')
print('json_summary_normal=', data['summary']['normal'])
print('computed_normal=', normal)
raise SystemExit(0 if data['summary']['normal'] == normal else 1)
PY
# Expected:
# json_summary_normal= <number>
# computed_normal= <same number>
```

Open several converted RAW JPGs in macOS Preview:

```bash
$ open /Users/wilbur/Downloads/LUMIX_Backup
# Expected: converted JPGs no longer show obvious red/blue channel swapped color.
```

### Step 3 — Run tests and confirm all pass

This task is complete only when:

- `./cpp/build/rawViewerTests` exits `0`.
- The CLI run exits `0`.
- The Python summary check exits `0`.
- Manual preview of converted RAW JPGs shows no channel-swap color error.

If any check fails, fix the earlier task responsible for that failure and rerun all checks.

✅ **Done when:** All checks listed above pass.

---

## Self-review

**Spec coverage:**

- Summary mismatch: covered by Task 1 and Task 4 Python check.
- RAW-to-JPG color difference: covered by Task 2 RGB-to-BGR unit test and Task 4 manual Preview check.
- `analysis.log` all `0ms`: covered by Task 3 precise timer and Task 4 log grep.

**Placeholder scan:** No `TBD`, `TODO`, ellipsis, or missing test bodies are present. Code snippets are complete for new files and complete replacement blocks are provided for existing code changes.

**Type consistency:** `AnalyzeResult` timing fields become `double`; all task instructions update producer assignments and analysis log consumers accordingly. Raw conversion timing remains `int64_t` and is unaffected.

**Test completeness:** Each task after Task 0 has a concrete goal, complete test code or concrete validation commands, primary cases, and edge/failure cases where applicable.

---

## Execution handoff

Plan complete and saved to `docs/flare/20260602_cppBugFixes.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
