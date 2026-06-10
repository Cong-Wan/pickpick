# RAW→JPG 色彩发灰修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `cpp/src/rawConverter.cpp` 中 LibRaw 处理参数缺失导致的 RAW 转 JPG 画面发灰、色彩不准问题。

**Architecture:** 在 LibRaw `dcraw_process()` 调用前显式配置 gamma 曲线、相机色彩矩阵、亮度控制、去马赛克质量等参数；在 `dcraw_make_mem_image()` 后增加 bits 防御性校验。

**Tech Stack:** C++17, LibRaw 0.22.1, CMake, Xcode (macOS)

---

## 文件结构

| 文件 | 动作 | 职责 |
|------|------|------|
| `cpp/src/rawConverter.cpp` | **修改** | 添加 LibRaw 处理参数配置 + bits 校验 |
| `cpp/CMakeLists.txt` | 不修改 | 构建配置保持不变 |
| `cpp/include/rawConverter.h` | 不修改 | 接口保持不变 |
| `rawViewer.xcodeproj` | 不修改 | Xcode 项目自动包含修改后的 cpp 文件 |

---

## Task 1: 配置 LibRaw 处理参数与 bits 校验

**Goal:** `rawConverter.cpp` 中的 LibRaw 处理链路在 `dcraw_process()` 前显式配置所有色彩/亮度相关参数，并在内存图像生成后校验 bits 字段，确保输出为 8-bit。

**Files touched:**

- `cpp/src/rawConverter.cpp` — 添加 gamma、相机矩阵、亮度控制、去马赛克参数；添加 bits 校验

---

### Step 1 — Implement

修改 `cpp/src/rawConverter.cpp`，在现有参数配置区域（`rawProcessor.open_file` 之后、`rawProcessor.unpack()` 之前）添加新参数，在 `dcraw_make_mem_image` 之后添加 bits 校验。

```cpp
/*
 * Author: wilbur
 * Version: 1.5
 * Date: 2026-06-09
 * Description: 使用 LibRaw 解码 RW2/CR2，并通过 ImageIO 一次性写出带基础 TIFF/EXIF 元信息的 JPG；接入 jpgWriter 模块替代 OpenCV imwrite；修复 gamma、色彩矩阵、亮度、去马赛克参数缺失导致的画面发灰问题
 */

#include "rawConverter.h"
#include "perfTimer.h"
#include "jpgWriter.h"
#include <libraw.h>
#include <filesystem>
#include <fstream>

RawConvertResult RawConverter::convert(const RawConvertTask& task, const AppConfig& config) const {
    RawConvertResult result;
    result.photoId = task.photoId;
    result.rawPath = task.rawPath;
    result.jpgPath = task.outputJpgPath;

    if (!std::filesystem::exists(task.rawPath)) {
        result.success = false;
        result.error = "RAW file not found: " + task.rawPath;
        return result;
    }

    std::filesystem::path outDir = std::filesystem::path(task.outputJpgPath).parent_path();
    if (!outDir.empty() && !std::filesystem::exists(outDir)) {
        std::filesystem::create_directories(outDir);
    }

    LibRaw rawProcessor;
    PerfTimer phaseTimer;
    int ret = rawProcessor.open_file(task.rawPath.c_str());
    result.openFileMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw open failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    // --- 色彩/亮度参数配置（修复发灰问题）---
    rawProcessor.imgdata.params.use_camera_wb = 1;
    rawProcessor.imgdata.params.use_auto_wb = 0;
    rawProcessor.imgdata.params.output_color = 1;   // sRGB
    rawProcessor.imgdata.params.output_bps = 8;

    // gamma 曲线：sRGB-like，power=0.45，toe slope=4.5
    rawProcessor.imgdata.params.gamm[0] = 0.45;
    rawProcessor.imgdata.params.gamm[1] = 4.5;
    rawProcessor.imgdata.params.gamm[2] = 0.0;
    rawProcessor.imgdata.params.gamm[3] = 0.0;
    rawProcessor.imgdata.params.gamm[4] = 0.0;
    rawProcessor.imgdata.params.gamm[5] = 0.0;

    // 启用相机嵌入色彩矩阵，提升色彩准确度
    rawProcessor.imgdata.params.use_camera_matrix = 1;

    // 关闭自动亮度，固定亮度系数 1.0，避免高光压缩和画面发灰
    rawProcessor.imgdata.params.no_auto_bright = 1;
    rawProcessor.imgdata.params.bright = 1.0f;

    // 高质量去马赛克：AHD (Adaptive Homogeneity-Directed)
    rawProcessor.imgdata.params.user_qual = 3;

    phaseTimer.reset();
    ret = rawProcessor.unpack();
    result.unpackMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw unpack failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    ret = rawProcessor.dcraw_process();
    result.processMs = phaseTimer.elapsedMs();
    if (ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw process failed: " + std::string(rawProcessor.strerror(ret));
        return result;
    }

    phaseTimer.reset();
    libraw_processed_image_t* img = rawProcessor.dcraw_make_mem_image(&ret);
    result.makeImageMs = phaseTimer.elapsedMs();
    if (!img || ret != LIBRAW_SUCCESS) {
        result.success = false;
        result.error = "LibRaw make image failed";
        if (img) rawProcessor.dcraw_clear_mem(img);
        return result;
    }

    // --- 防御性校验：确保输出为 8-bit ---
    if (img->bits != 8) {
        result.success = false;
        result.error = "LibRaw output bits mismatch: expected 8, got " + std::to_string(img->bits);
        rawProcessor.dcraw_clear_mem(img);
        return result;
    }

    jpgMetadata metadata;
    metadata.quality = config.rawConversion.jpgQuality;
    metadata.timestamp = static_cast<int64_t>(rawProcessor.imgdata.other.timestamp);
    metadata.make = rawProcessor.imgdata.idata.make;
    metadata.model = rawProcessor.imgdata.idata.model;
    metadata.software = rawProcessor.imgdata.idata.software;
    metadata.isoSpeed = rawProcessor.imgdata.other.iso_speed;
    metadata.exposureTime = rawProcessor.imgdata.other.shutter;
    metadata.fNumber = rawProcessor.imgdata.other.aperture;
    metadata.focalLength = rawProcessor.imgdata.other.focal_len;
    metadata.lensModel = rawProcessor.imgdata.lens.Lens;
    if (rawProcessor.imgdata.lens.FocalLengthIn35mmFormat > 0) {
        metadata.focalLength35mm = rawProcessor.imgdata.lens.FocalLengthIn35mmFormat;
    } else if (rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0.0f) {
        metadata.focalLength35mm = static_cast<int>(rawProcessor.imgdata.lens.makernotes.FocalLengthIn35mmFormat + 0.5f);
    }
    if (rawProcessor.imgdata.shootinginfo.ExposureProgram > 0) {
        metadata.exposureProgram = rawProcessor.imgdata.shootinginfo.ExposureProgram;
    }
    metadata.flash = rawProcessor.imgdata.color.flash_used > 0.0f ? 1 : 0;
    metadata.hasFlash = true;

    std::string writeError;
    phaseTimer.reset();
    bool written = writeJpgWithImageIo(task.outputJpgPath, img->width, img->height, img->colors, img->data, metadata, writeError);
    result.writeJpgMs = phaseTimer.elapsedMs();
    rawProcessor.dcraw_clear_mem(img);

    if (!written) {
        result.success = false;
        result.error = "ImageIO write failed: " + writeError;
        return result;
    }

    result.success = true;
    return result;
}
```

**变更点速查**（相对于原代码新增的行）：

| 新增行范围 | 内容 |
|-----------|------|
| 参数区 | `gamm[0..5]` = `{0.45, 4.5, 0, 0, 0, 0}` |
| 参数区 | `use_camera_matrix = 1` |
| 参数区 | `no_auto_bright = 1` |
| 参数区 | `bright = 1.0f` |
| 参数区 | `user_qual = 3` |
| bits 校验 | `if (img->bits != 8)` 返回错误 |

---

### Step 2 — 编译验证

**CMake 路径验证：**

```bash
$ cd /Users/wilbur/project/rawViewer/cpp/build
$ cmake .. && make -j$(sysctl -n hw.ncpu)
```

**预期输出：**
```
[  5%] Building CXX object CMakeFiles/rawViewer.dir/src/rawConverter.cpp.o
[100%] Linking CXX executable rawViewer
[100%] Built target rawViewer
```

**Xcode 路径验证（备选）：**

```bash
$ cd /Users/wilbur/project/rawViewer
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Release -quiet
```

**预期输出：**
```
** BUILD SUCCEEDED **
```

---

### Step 3 — 运行验证

**验证步骤：**

1. 准备一张已知的 RAW 文件（如 `.RW2` 或 `.CR2`）
2. 用修改前的版本转换一次，保存为 `before.jpg`
3. 用修改后的版本转换一次，保存为 `after.jpg`
4. 视觉对比 + 文件大小对比

**运行命令（示例）：**

```bash
$ cd /Users/wilbur/project/rawViewer
$ ./cpp/build/rawViewer --folder /path/to/test_raws --config ./cpp/config.yaml
```

**验证清单：**

- [ ] 程序不崩溃，正常退出
- [ ] 转换日志中 `success=true`，无 bits mismatch 错误
- [ ] `after.jpg` 相比 `before.jpg`：
  - [ ] 中间调不再发灰，对比度提升
  - [ ] 色彩饱和度更接近相机直出 JPG
  - [ ] 高光更自然，不再被保守压缩
  - [ ] 暗部细节保留良好
- [ ] 若故意将 `output_bps` 改为 16 再编译运行，应触发 bits mismatch 错误路径（可选防御性测试）

---

✅ **Done when:** CMake 编译通过，且运行后转换出的 JPG 在视觉上对比原版本有明确的对比度和色彩饱和度提升。bits mismatch 错误路径可通过临时修改 `output_bps = 16` 验证。

---

## Self-Review Checklist

| 检查项 | 状态 |
|--------|------|
| Spec coverage: gamma、camera matrix、brightness、demosaic、bits 校验全部覆盖 | ✅ |
| 无 TBD/TODO/占位符 | ✅ |
| 类型一致性：所有参数类型与 LibRaw `libraw_output_params_t` 定义一致 | ✅ |
| 代码风格：小驼峰命名，含文件头，版本号 1.5 | ✅ |
| 测试验证：编译 + 运行 + 视觉对比，bits 路径可手动验证 | ✅ |
| 不修改无关文件 | ✅ |
