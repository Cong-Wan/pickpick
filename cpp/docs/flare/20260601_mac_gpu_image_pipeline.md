# Mac GPU Image Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a measurable macOS Apple Silicon acceleration path for image analysis and RAW conversion while preserving the current CPU implementation as a compatibility fallback.

**Architecture:** Keep the existing `RawConverter` and `ImageAnalyzer` public interfaces stable. Add explicit backend configuration, phase-level timing, macOS capability detection, and Objective-C++ implementations that use Metal/Core Image/MPS where they are a good fit. The current LibRaw/OpenCV path remains the fallback for unsupported machines, unsupported RAW files, or GPU-path failures.

**Tech Stack:** C++17, Objective-C++ (`.mm`), CMake, LibRaw, OpenCV, Core Image, ImageIO, Core Graphics, Metal, MetalPerformanceShaders, XCTest-free lightweight C++ tests.

---

## Scope Check

This plan intentionally covers one pipeline rather than two separate products:

- JPG analysis acceleration is the primary target because grayscale conversion, Laplacian, min/max, mean/stddev, and histogram are regular image operations that can be moved to Metal/MPS or vectorized cleanly.
- RAW conversion acceleration is a guarded optional fast path because LibRaw's `dcraw_process()` is CPU-based and camera-format coverage is broader than Core Image RAW support.

The implementation must never remove the existing LibRaw/OpenCV behavior until the accelerated path has proven parity and performance.

## Assumptions

- Target platform is macOS on Apple Silicon.
- The project can add Objective-C++ source files and Apple frameworks to CMake.
- Existing output JSON schema must remain compatible.
- GPU acceleration means using Apple native GPU APIs (`Metal`, `Core Image` with Metal-backed `CIContext`, and `MetalPerformanceShaders`), not OpenCL. OpenCL is intentionally avoided because it is deprecated on macOS.
- Benchmarking requires a local sample folder containing representative RW2/CR2/JPG files. If no sample folder is available, only build and unit-style tests can be completed.

## File Structure

- `include/perfTimer.h` — small timing helpers used by conversion and analysis code.
- `include/gpuSupport.h` — backend enums and capability detection interface.
- `src/gpuSupport.mm` — Apple Silicon / Metal availability detection.
- `include/imageAnalyzer.h` — keeps current public analyzer entrypoint; may add private helper declarations only if needed.
- `src/imageAnalyzer.cpp` — existing CPU fallback plus backend dispatch.
- `src/macImageAnalyzer.mm` — macOS accelerated JPG analysis implementation.
- `include/rawConverter.h` — keeps current public converter entrypoint; may add private helper declarations only if needed.
- `src/rawConverter.cpp` — existing LibRaw/OpenCV fallback plus backend dispatch.
- `src/macRawConverter.mm` — Core Image RAW conversion fast path with strict fallback behavior.
- `include/taskState.h` — adds backend config fields and backend result metadata.
- `src/configLoader.cpp` — parses and validates backend config.
- `config.yaml` — exposes `image_processing.analysis_backend` and `image_processing.raw_backend`.
- `src/jsonManager.cpp` — persists backend metadata only if it does not break existing consumers.
- `CMakeLists.txt` — enables Objective-C++ and links Apple frameworks.
- `tests/` — lightweight test harness for config parsing, fallback decisions, and analyzer parity.
- `docs/perf/mac_gpu_pipeline_baseline.md` — benchmark notes and acceptance data.

---

## Task 0: Environment Setup

**Goal:** Establish a clean build baseline before implementation.

**Files touched:** None.

#### Step 1 — Prepare branch

```bash
$ git status --short
# Expected: review any existing user changes before editing. Do not revert unrelated changes.

$ git switch -c feature/mac-gpu-image-pipeline
# Expected: Switched to a new branch 'feature/mac-gpu-image-pipeline'
```

If the branch already exists, use:

```bash
$ git switch feature/mac-gpu-image-pipeline
# Expected: Switched to branch 'feature/mac-gpu-image-pipeline'
```

#### Step 2 — Confirm toolchain

```bash
$ xcodebuild -version
# Expected: Xcode version is printed.

$ cmake --version
# Expected: cmake version 3.16 or newer.
```

#### Step 3 — Build baseline

```bash
$ cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
# Expected: Configuring done, Generating done, Build files have been written to: .../cpp/build

$ cmake --build build -j
# Expected: rawViewer target builds successfully.
```

#### Step 4 — Run baseline on a sample folder

```bash
$ ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: command exits 0 and prints total photo summary.
```

If no representative sample folder exists, stop and create one before performance work. GPU optimization without a stable benchmark set is not meaningful.

✅ **Done when:** Release build succeeds and the current CPU pipeline can process the sample folder.

---

### Task 1: Add Phase-Level Timing

**Goal:** Every conversion and analysis result records enough timing data to identify whether RAW decode, JPG encode, image read, Laplacian, or histogram is the bottleneck.

**Files touched:**

- `include/perfTimer.h` — defines reusable elapsed-time helpers.
- `include/taskState.h` — adds timing fields to result structures.
- `src/rawConverter.cpp` — records RAW phase timings.
- `src/imageAnalyzer.cpp` — records analysis phase timings.
- `src/appRunner.cpp` — writes timings to `.cache/conversion.log`.
- `tests/perfTimerTests.cpp` — verifies timer monotonic behavior and result field defaults.

#### Step 1 — Implement

- Add `PerfTimer` with `elapsedMs()` using `std::chrono::steady_clock`.
- Add `RawConvertResult` fields: `openFileMs`, `unpackMs`, `processMs`, `makeImageMs`, `writeJpgMs`.
- Add `AnalyzeResult` fields: `readImageMs`, `grayMs`, `laplacianMs`, `statsMs`, `histogramMs`.
- Keep `elapsedMs` as the total wall time already used by `AppRunner`.
- Log all fields in `conversion.log` without changing success/failure semantics.

#### Step 2 — Write tests based on the plan goal

- Create lightweight tests that construct default result structs and verify all timing fields default to `0`.
- Verify `PerfTimer::elapsedMs()` returns a non-negative value after construction.

#### Step 3 — Run tests and confirm all pass

```bash
$ cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DRAWVIEWER_BUILD_TESTS=ON
# Expected: test target is configured.

$ cmake --build build -j
# Expected: rawViewer and rawViewerTests build successfully.

$ ./build/rawViewerTests --filter perfTimer
# Expected: all perfTimer tests pass.
```

#### Step 4 — Commit

```bash
git add include/perfTimer.h include/taskState.h src/rawConverter.cpp src/imageAnalyzer.cpp src/appRunner.cpp tests/perfTimerTests.cpp CMakeLists.txt
git commit -m "perf(image): add phase timing"
```

✅ **Done when:** Tests pass and a real sample run shows phase timing in `.cache/conversion.log`.

---

### Task 2: Add Backend Configuration And Capability Detection

**Goal:** The app can choose `auto`, `cpu`, or `metal` backends explicitly, and it falls back to CPU when Metal is unavailable.

**Files touched:**

- `include/gpuSupport.h` — declares backend enums and capability result.
- `src/gpuSupport.mm` — implements Metal device detection.
- `include/taskState.h` — adds `ImageProcessingConfig`.
- `src/configLoader.cpp` — validates backend config.
- `config.yaml` — documents backend options.
- `CMakeLists.txt` — enables Objective-C++ and links `Metal`.
- `tests/configLoaderTests.cpp` — verifies valid and invalid backend config.
- `tests/gpuSupportTests.cpp` — verifies CPU fallback behavior.

#### Step 1 — Implement

- Add `ImageBackend { Auto, Cpu, Metal }`.
- Add `ImageProcessingConfig { ImageBackend analysisBackend; ImageBackend rawBackend; bool logBackend; }`.
- Add YAML:

```yaml
image_processing:
  # auto: use Metal/Core Image when safe, otherwise CPU fallback.
  # cpu: force existing LibRaw/OpenCV path.
  # metal: require macOS GPU path where implemented; fail or fallback with explicit log depending on task.
  analysis_backend: auto
  raw_backend: auto
  log_backend: true
```

- Add `GpuSupport getGpuSupport()` returning `hasMetal`, `deviceName`, and `reason`.
- On non-Apple builds, return `hasMetal=false` and a clear reason.

#### Step 2 — Write tests based on the plan goal

- Valid values `auto`, `cpu`, `metal` parse successfully.
- Invalid value such as `opencl` throws `Invalid config field`.
- On every platform, `cpu` remains a valid backend even if `hasMetal=false`.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests --filter configLoader,gpuSupport
# Expected: backend config and gpuSupport tests pass.
```

#### Step 4 — Commit

```bash
git add include/gpuSupport.h src/gpuSupport.mm include/taskState.h src/configLoader.cpp config.yaml CMakeLists.txt tests/configLoaderTests.cpp tests/gpuSupportTests.cpp
git commit -m "feat(config): add image backend selection"
```

✅ **Done when:** Config parsing is covered and `auto` can resolve to a safe backend decision.

---

### Task 3: Optimize The CPU Analysis Fallback

**Goal:** The existing CPU JPG analysis path gets faster without changing output decisions.

**Files touched:**

- `src/imageAnalyzer.cpp` — replaces manual histogram loop with optimized OpenCV or Accelerate/vImage path.
- `tests/imageAnalyzerTests.cpp` — verifies blur/exposure decisions and histogram totals.
- `docs/perf/mac_gpu_pipeline_baseline.md` — records pre/post CPU fallback benchmark.

#### Step 1 — Implement

- Keep `cv::imread` and `cv::cvtColor` for the fallback path.
- Replace the nested `gray.at<uint8_t>` loop with row-pointer iteration at minimum.
- Prefer `cv::calcHist` if it produces identical 256-bin counts and simpler code.
- Keep threshold counts exact: `v > overexposePixelThreshold` and `v < underexposePixelThreshold`.
- Do not add abstractions beyond a small local helper if it makes tests easier.

#### Step 2 — Write tests based on the plan goal

- Synthetic all-black image: histogram bin 0 equals total pixels, underexposure ratio equals 1.0.
- Synthetic all-white image: histogram bin 255 equals total pixels, overexposure ratio equals 1.0.
- Mixed image: total histogram count equals `rows * cols`.
- Existing blur decision remains based on Laplacian variance.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests --filter imageAnalyzer
# Expected: imageAnalyzer tests pass.

$ ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: same summary counts as baseline, lower or equal analysis elapsed time in logs.
```

#### Step 4 — Commit

```bash
git add src/imageAnalyzer.cpp tests/imageAnalyzerTests.cpp docs/perf/mac_gpu_pipeline_baseline.md
git commit -m "perf(analysis): optimize cpu histogram"
```

✅ **Done when:** Analyzer tests pass and sample output decisions match baseline.

---

### Task 4: Add Metal-Backed JPG Analysis

**Goal:** On Apple Silicon with Metal available, JPG analysis can execute through the macOS GPU path and return the same `AnalyzeResult` contract as the CPU path.

**Files touched:**

- `src/macImageAnalyzer.mm` — implements accelerated read/gray/laplacian/stat/histogram path.
- `include/imageAnalyzer.h` — exposes no new public behavior unless absolutely required.
- `src/imageAnalyzer.cpp` — dispatches to GPU path based on config and fallback rules.
- `CMakeLists.txt` — links `CoreImage`, `ImageIO`, `CoreGraphics`, `Metal`, `MetalPerformanceShaders`.
- `tests/imageAnalyzerBackendTests.cpp` — verifies backend dispatch and fallback.
- `docs/perf/mac_gpu_pipeline_baseline.md` — records GPU analysis benchmark.

#### Step 1 — Implement

- Use `MTLCreateSystemDefaultDevice()` once per process.
- Use a Metal-backed `CIContext` to decode JPG into a GPU-friendly image.
- Use MPS or a small Metal compute kernel for grayscale and Laplacian.
- Use GPU reduction for min/max/mean/stddev where straightforward; if readback is faster and simpler for histogram at current image sizes, document and keep histogram on CPU after one readback.
- If any GPU step fails in `auto`, log the reason and re-run the existing CPU analyzer.
- If `analysis_backend: metal` is set and Metal is unavailable, return a failed `AnalyzeResult` with a clear error.

#### Step 2 — Write tests based on the plan goal

- `analysis_backend: cpu` never calls the Metal path.
- `analysis_backend: auto` falls back to CPU when `getGpuSupport().hasMetal == false`.
- For a fixed synthetic JPG, Metal and CPU analysis results stay within approved tolerances:
  - histogram bins: exact match if histogram is CPU readback, otherwise total count must match and exposure status must match.
  - Laplacian variance: relative difference under 1%.
  - blur and exposure decisions: exact match.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests --filter imageAnalyzerBackend
# Expected: backend dispatch and parity tests pass.

$ ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: summary matches CPU baseline and logs include selected_backend=metal for supported images.
```

Use Instruments after the command:

```bash
$ instruments -t "Metal System Trace" ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: Metal workload is visible during analysis phase.
```

#### Step 4 — Commit

```bash
git add src/macImageAnalyzer.mm include/imageAnalyzer.h src/imageAnalyzer.cpp CMakeLists.txt tests/imageAnalyzerBackendTests.cpp docs/perf/mac_gpu_pipeline_baseline.md
git commit -m "feat(analysis): add metal backend"
```

✅ **Done when:** GPU analysis passes parity tests and Instruments confirms Metal work during analysis.

---

### Task 5: Add Core Image RAW Conversion Fast Path

**Goal:** RAW conversion can use Core Image on supported macOS RAW formats while preserving LibRaw fallback for unsupported files or failed GPU conversion.

**Files touched:**

- `src/macRawConverter.mm` — implements Core Image RAW decode and JPEG encode fast path.
- `src/rawConverter.cpp` — dispatches between Core Image and LibRaw.
- `include/rawConverter.h` — exposes no new public behavior unless absolutely required.
- `tests/rawConverterBackendTests.cpp` — verifies dispatch/fallback behavior.
- `docs/perf/mac_gpu_pipeline_baseline.md` — records RAW conversion comparison.

#### Step 1 — Implement

- Use `CIRAWFilter` or Core Image RAW loading from file URL.
- Render with a Metal-backed `CIContext` when available.
- Encode JPEG using ImageIO with `jpg_quality`.
- In `auto`, fallback to LibRaw when Core Image cannot open the RAW, render, or encode.
- In `cpu`, always use current LibRaw/OpenCV path.
- In `metal`, fail clearly if Core Image RAW conversion is unavailable for the file.
- Preserve `RawConvertResult` fields: `photoId`, `rawPath`, `jpgPath`, `attempts`, `error`, `elapsedMs`.

#### Step 2 — Write tests based on the plan goal

- Missing RAW file still fails before backend work.
- `raw_backend: cpu` uses LibRaw path.
- `raw_backend: auto` falls back to LibRaw if the Core Image path reports unsupported format.
- If a real RAW fixture is available, generated JPG exists and is readable by OpenCV.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests --filter rawConverterBackend
# Expected: raw converter backend tests pass.

$ ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: conversion succeeds or falls back without losing files.
```

#### Step 4 — Commit

```bash
git add src/macRawConverter.mm src/rawConverter.cpp include/rawConverter.h tests/rawConverterBackendTests.cpp docs/perf/mac_gpu_pipeline_baseline.md
git commit -m "feat(raw): add core image conversion path"
```

✅ **Done when:** RAW conversion remains compatible and logs clearly show Core Image vs LibRaw usage.

---

### Task 6: Tune Worker Scheduling For GPU Work

**Goal:** Concurrent processing does not oversubscribe CPU workers and GPU command queues on Apple Silicon.

**Files touched:**

- `include/threadPool.h` — only if a backend-specific concurrency limit is required.
- `src/appRunner.cpp` — applies conservative task submission limits for GPU-heavy phases if needed.
- `config.yaml` — documents recommended worker count for GPU path.
- `tests/appRunnerBackendTests.cpp` — verifies the selected worker limit is applied.
- `docs/perf/mac_gpu_pipeline_baseline.md` — records throughput results for worker counts.

#### Step 1 — Implement

- Benchmark worker counts 1, 2, 3, 4 on the same sample set.
- If GPU backend performs worse with 4 concurrent jobs, add a separate `gpu_worker_count` config capped to a small number.
- Do not change the CPU path's existing fixed worker behavior unless benchmark data proves it is necessary.

#### Step 2 — Write tests based on the plan goal

- CPU backend keeps current effective worker count.
- GPU backend uses the configured GPU worker count.
- Invalid GPU worker count fails config validation.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests --filter appRunnerBackend
# Expected: worker selection tests pass.
```

#### Step 4 — Commit

```bash
git add include/threadPool.h src/appRunner.cpp config.yaml tests/appRunnerBackendTests.cpp docs/perf/mac_gpu_pipeline_baseline.md
git commit -m "perf(pipeline): tune gpu worker scheduling"
```

✅ **Done when:** Worker-count choice is backed by measured throughput, not guesswork.

---

### Task 7: Final Performance And Parity Validation

**Goal:** The accelerated pipeline is objectively faster on the representative sample set and produces compatible results.

**Files touched:**

- `docs/perf/mac_gpu_pipeline_baseline.md` — final benchmark table and decision.
- `docs/flare/20260601_mac_gpu_image_pipeline.md` — update checkboxes only if executing from this plan.

#### Step 1 — Implement

- Run CPU baseline with `analysis_backend: cpu` and `raw_backend: cpu`.
- Run accelerated mode with `analysis_backend: auto` and `raw_backend: auto`.
- Compare:
  - total wall time
  - RAW conversion p50/p95
  - analysis p50/p95
  - final blurry/overexposed/underexposed/normal counts
  - number of GPU fallbacks
- Accept the GPU path only if total time improves by at least 30% or analysis time improves by at least 40% without changing final classifications.

#### Step 2 — Write tests based on the plan goal

- Add a small regression script or test that compares CPU and accelerated JSON summaries for a fixture set.
- The test must fail if classification counts diverge.

#### Step 3 — Run tests and confirm all pass

```bash
$ ./build/rawViewerTests
# Expected: all tests pass.

$ cmake --build build -j
# Expected: rawViewer builds successfully.

$ ./build/rawViewer /path/to/sample_photos --config config.yaml --resume
# Expected: command exits 0 and logs backend usage.
```

#### Step 4 — Commit

```bash
git add docs/perf/mac_gpu_pipeline_baseline.md docs/flare/20260601_mac_gpu_image_pipeline.md tests
git commit -m "test(pipeline): validate mac gpu acceleration"
```

✅ **Done when:** Full tests pass, benchmark data is recorded, and the acceleration path meets the acceptance threshold.

---

## Acceptance Criteria

- The app builds on macOS Apple Silicon in Release mode.
- `analysis_backend: cpu` and `raw_backend: cpu` preserve current behavior.
- `analysis_backend: auto` uses Metal when available and falls back safely.
- `raw_backend: auto` uses Core Image only when supported and falls back to LibRaw safely.
- JSON consumers remain compatible.
- Benchmark data proves whether the GPU path is worth keeping enabled by default.

## Self-Review

- Spec coverage: The plan covers measurement, GPU analysis, RAW fast path, fallback behavior, worker tuning, and final performance validation.
- Placeholder scan: No task relies on `TBD`, hidden assumptions, or untestable "make it work" criteria.
- Type consistency: Backend names are consistently `auto`, `cpu`, and `metal`; config sits under `image_processing`.
- Test completeness: Each implementation task has a direct verification command and a concrete done condition.

## Execution Handoff

Plan complete and saved to `docs/flare/20260601_mac_gpu_image_pipeline.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.
