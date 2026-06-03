## 代码审核报告 — RAW Metadata Duplicate Groups

### 总览

- 审核文件：7 个
  - `cpp/include/photoMetadataReader.h`
  - `cpp/src/photoMetadataReader.mm`
  - `cpp/include/jpgWriter.h`
  - `cpp/src/jpgWriter.mm`
  - `cpp/src/rawConverter.cpp`
  - `cpp/src/jsonManager.cpp`
  - `cpp/CMakeLists.txt`
- 发现问题：🔴 0 个 / 🟠 0 个 / 🟡 0 个 / 🔵 1 个
- 整体评价：实现已经覆盖设计文档核心要求：JSON 写入拍摄时间、3 秒规则 B 生成 `dup_00x`、覆盖 `review_group_id`、ImageIO 一次性写 JPG、无 OpenCV JPG fallback。审核中发现的两个高风险问题已在审核过程中修复。

---

### 已在审核中修复的问题

#### 🟠 已修复：临时 JPG rename 前删除最终文件存在数据丢失风险

**位置**: `cpp/src/jpgWriter.mm`，最终文件替换逻辑

**问题**: 初版逻辑在 `fs::rename(tmpPath, finalPath)` 前先 `fs::remove(finalPath)`。如果删除旧 JPG 成功但 rename 失败，会丢失原有 JPG。

**修复方案**: 删除显式 remove final 的逻辑，使用同目录临时文件 rename 覆盖。macOS/POSIX 下 rename 到已有路径可原子替换。

```cpp
std::error_code renameError;
fs::rename(tmpPath, finalPath, renameError);
if (renameError) {
    fs::remove(tmpPath);
    error = "failed to move temporary JPEG into place: " + renameError.message();
    return false;
}
```

#### 🟡 已修复：`std::localtime` / `std::gmtime` 非线程安全

**位置**: `cpp/src/jpgWriter.mm`、`cpp/src/photoMetadataReader.mm`

**问题**: RAW 转换在线程池中并发执行，`std::localtime` 和 `std::gmtime` 返回共享静态缓冲区，存在并发数据竞争风险。

**修复方案**: macOS 下改用 `localtime_r` 和 `gmtime_r`。

```cpp
std::tm localTime = {};
localtime_r(&timeValue, &localTime);
```

```cpp
std::tm tmUtc = {};
gmtime_r(&timeValue, &tmUtc);
```

#### 🟠 已修复：只用 `MDItemContentCreationDate` 会在复制文件后误读为复制时间

**位置**: `cpp/src/photoMetadataReader.mm`

**问题**: 临时烟测中，将 RAW 复制到 `/tmp` 后，`MDItemContentCreationDate` 返回复制时间，导致 JSON 的 `shooting_time` 错误。这个问题会直接破坏重复分组正确性。

**修复方案**: metadata reader 改为优先使用 ImageIO `CGImageSourceCopyPropertiesAtIndex` 读取文件内 EXIF/TIFF 时间：

1. EXIF `DateTimeOriginal`
2. EXIF `DateTimeDigitized`
3. TIFF `DateTime`
4. 失败后才用 `MDItemContentCreationDate` 兜底

临时烟测确认 `/tmp` 复制后的 `P1001124.RW2` 输出：

```text
shooting_time 2026-04-12T11:31:41Z
shooting_time_source raw
```

---

### 问题清单

#### 🔵 Low：`kUTTypeJPEG` 在 macOS 12 后被标记 deprecated

**位置**: `cpp/src/jpgWriter.mm`

**问题**: 编译会出现 warning：`kUTTypeJPEG` deprecated。当前不影响编译和功能，但后续如果项目提高 warning 策略，可能需要处理。

**修复方案**: 当前可接受。后续如果要消除 warning，可根据项目最低系统版本改用 UniformTypeIdentifiers 的 `UTTypeJPEG.identifier`，但这会增加一个新 framework/import 选择，当前不必扩大改动范围。

---

### 优点记录

- JSON 分组逻辑采用 `(shooting_time, photoId)` 排序，`dup_00x` 输出稳定。
- `template_photo_id` 未被自动清空，符合需求。
- ImageIO 写出失败会返回 RAW conversion failed，没有 OpenCV fallback。
- `writeJpgMs` 只记录 ImageIO 写出路径耗时，未做性能比较。
- 未创建 `cpp/tests` 或任何测试文件，符合用户限制。

---

### 修复优先级建议

1. 当前无必须立即修复的 Critical/High 问题。
2. `kUTTypeJPEG` deprecated warning 可留到后续统一处理 SDK deprecated warning 时再改。
3. 建议用户用真实目录进行实际验证：检查 `.cache/analysis.json` 的 `shooting_time`、`dup_00x`，以及转换 JPG 的 `sips` / `mdls` 元信息展示。
