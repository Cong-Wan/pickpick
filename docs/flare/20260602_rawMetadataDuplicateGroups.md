# RAW Metadata Duplicate Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add RAW/JPG shooting time to `analysis.json`, assign stable 3-second time duplicate groups into existing `review_group_id`, and replace OpenCV JPEG output with one-pass ImageIO JPEG output carrying key metadata.

**Architecture:** Keep the existing scan → JSON merge → RAW conversion → analysis pipeline. Add a macOS metadata reader for fast metadata-only shooting-time reads during JSON merge, and add an Objective-C++ ImageIO JPEG writer called by `RawConverter` so converted JPEGs include key TIFF/EXIF metadata without any OpenCV JPEG fallback.

**Tech Stack:** C++17, Objective-C++, nlohmann/json, LibRaw, ImageIO/CoreGraphics/CoreServices/Foundation, CMake.

---

## Constraints from the user

- Do not create `cpp/tests` or any test-related files.
- Success is measured by compile passing and the implementation matching `docs/recipe/20260602_raw_metadata_duplicate_groups_recipe.md`.
- The user will perform actual data testing.
- Code must not contain an OpenCV JPEG fallback path.
- RAW-to-JPG output must use ImageIO `CGImageDestination` once.
- ImageIO write duration should be recorded; code must not compare ImageIO performance against OpenCV.

---

## File structure

New files:

- `cpp/include/photoMetadataReader.h` — declares metadata-only shooting-time read result and reader interface.
- `cpp/src/photoMetadataReader.mm` — reads `kMDItemContentCreationDate` through macOS Metadata APIs and formats UTC ISO8601 strings.
- `cpp/include/jpgWriter.h` — declares the ImageIO JPEG writer input metadata and write function.
- `cpp/src/jpgWriter.mm` — writes JPEG pixels and TIFF/EXIF metadata with `CGImageDestination`.

Modified files:

- `cpp/src/jsonManager.cpp` — writes `shooting_time`, `shooting_time_source`, and recomputes `review_group_id` as stable `dup_00x` groups.
- `cpp/src/rawConverter.cpp` — replaces `cv::imwrite` with the ImageIO writer; populates JPEG metadata from LibRaw.
- `cpp/CMakeLists.txt` — adds new `.mm` sources and links ImageIO/CoreServices if needed.

Not modified unless required by compiler errors:

- Swift files — existing app reads `review_group_id`; no model change is planned.
- `cpp/tests` — must not be created.
- Existing `rawJpgMat` files — leave them untouched unless build cleanup is explicitly necessary. They may remain unused.

---

## Task 1: Add fast shooting-time reads and JSON duplicate grouping

**Goal:** After scan/merge, every photo record has `shooting_time` and `shooting_time_source`, and existing `review_group_id` is overwritten with stable 3-second `dup_00x` groups only for groups with at least two photos.

**Files touched:**

- `cpp/include/photoMetadataReader.h` — new metadata reader declarations.
- `cpp/src/photoMetadataReader.mm` — new macOS metadata implementation.
- `cpp/src/jsonManager.cpp` — JSON field updates and grouping algorithm.
- `cpp/CMakeLists.txt` — add new source and framework link.

### Step 1 — Implement `photoMetadataReader`

Create `cpp/include/photoMetadataReader.h` with the required project file header and these public types:

```cpp
struct shootingTimeResult {
    bool found = false;
    int64_t epochSeconds = 0;
    std::string isoUtc;
    std::string source = "none";
};

class photoMetadataReader {
public:
    shootingTimeResult readBestShootingTime(const std::string& rawPath, const std::string& jpgPath) const;
    shootingTimeResult readFileShootingTime(const std::string& filePath, const std::string& source) const;
};
```

Create `cpp/src/photoMetadataReader.mm` with the required project file header and implement:

- `readBestShootingTime(rawPath, jpgPath)`:
  - If `rawPath` is not empty, call `readFileShootingTime(rawPath, "raw")`.
  - If RAW result is found, return it.
  - If `jpgPath` is not empty, call `readFileShootingTime(jpgPath, "jpg")`.
  - If JPG result is found, return it.
  - Return `{false, 0, "", "none"}`.
- `readFileShootingTime(filePath, source)`:
  - Return not found for empty path.
  - Use `MDItemCreate(kCFAllocatorDefault, cfPath)`.
  - Use `MDItemCopyAttribute(item, kMDItemContentCreationDate)`.
  - Accept only `CFDateRef` values.
  - Convert `CFDateGetAbsoluteTime(date) + kCFAbsoluteTimeIntervalSince1970` to epoch seconds.
  - Format ISO UTC as `%Y-%m-%dT%H:%M:%SZ` with `std::gmtime`.
  - Release all CoreFoundation objects.
  - Never throw for missing metadata; return `source = "none"` on failure.

Implementation notes:

- Include `<CoreServices/CoreServices.h>` for Metadata APIs.
- Include `<CoreFoundation/CoreFoundation.h>` if needed by the compiler.
- Include `<chrono>`, `<ctime>`, `<cstdint>`, and `<string>` for conversion/formatting.
- Avoid shelling out to `mdls`.
- Do not use LibRaw in this metadata reader.

### Step 2 — Integrate into `JsonManager::mergeScannedPairs`

Update `cpp/src/jsonManager.cpp`:

- Bump the file header version from `1.3` to `1.4` and mention shooting time / duplicate grouping.
- Include `photoMetadataReader.h`.
- Include `<iomanip>` if using `std::setw` / `std::setfill` for group IDs.

Inside `JsonManager::init`:

- After loading or initializing root JSON, set `schema_version` to `"1.4"` so existing `1.3` files are migrated when saved.

Inside `JsonManager::mergeScannedPairs`:

1. Keep all existing photo creation/default-field behavior.
2. Ensure existing records also get these fields if missing:
   - `shooting_time`
   - `shooting_time_source`
3. After path updates for a pair, call the metadata reader with the current pair paths:
   - Prefer `pair.rawPath` if `pair.hasRaw`.
   - Use `pair.jpgPath` if `pair.hasJpg`.
4. Write:
   - If found: `p["shooting_time"] = result.isoUtc`; `p["shooting_time_source"] = result.source`.
   - If not found: `p["shooting_time"] = nullptr`; `p["shooting_time_source"] = "none"`.
5. Do not modify `template_photo_id` beyond existing default-fill behavior.
6. After all pairs have been merged and shooting times written, call a private/static helper to recompute duplicate groups.

Add a file-local helper in `jsonManager.cpp` similar to:

```cpp
struct timeGroupCandidate {
    std::string photoId;
    int64_t epochSeconds = 0;
};

static bool parseIsoUtcSeconds(const std::string& isoUtc, int64_t& epochSeconds);
static void recomputeTimeDuplicateGroups(json& photos);
```

`parseIsoUtcSeconds` requirements:

- Accept the exact `YYYY-MM-DDTHH:MM:SSZ` format written by `photoMetadataReader`.
- Use `std::get_time` into `std::tm`.
- Convert as UTC, not local time.
- On macOS use `timegm(&tm)`.
- Return `false` if parsing fails.

`recomputeTimeDuplicateGroups` requirements:

1. Iterate all `photos`.
2. Set every record's `review_group_id` to `""` before assigning new groups.
3. For records with string `shooting_time`, parse epoch seconds and collect candidates.
4. Sort candidates by `(epochSeconds, photoId)`.
5. Walk candidates with threshold `3` seconds and rule B:
   - Start group at first unprocessed candidate.
   - Include following candidates while `candidate.epochSeconds - groupStartEpoch <= 3`.
   - Close group when the next candidate exceeds 3 seconds.
6. Assign `dup_001`, `dup_002`, ... only when candidate group size is at least 2.
7. Leave single-photo candidate groups with empty `review_group_id`.
8. Use zero-padded three-digit IDs with `std::ostringstream`, `std::setw(3)`, and `std::setfill('0')`.

Call `impl_->updateSummary()` exactly as today after the merge/grouping work.

### Step 3 — Update CMake for metadata reader

Modify `cpp/CMakeLists.txt`:

- Add `src/photoMetadataReader.mm` to `SOURCES`.
- Under `if(APPLE)`, add:
  - `find_library(CORESERVICES_LIBRARY CoreServices)`
  - Link `${CORESERVICES_LIBRARY}` to `rawViewer`.

Do not create or enable test targets.

### Step 4 — Validate Task 1

Run:

```bash
cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=OFF
cmake --build cpp/build
```

Expected:

- Configure succeeds.
- Build succeeds.
- No `cpp/tests` directory is created.

Optional logic inspection command, without modifying data:

```bash
rg -n "shooting_time|shooting_time_source|dup_001|recomputeTimeDuplicateGroups|kMDItemContentCreationDate" cpp/src cpp/include
```

Expected:

- Metadata reader uses `kMDItemContentCreationDate`.
- JSON manager writes `shooting_time` / `shooting_time_source`.
- JSON manager recomputes duplicate groups and formats `dup_00x` IDs.

✅ **Done when:** The project builds and the code path clearly matches the recipe's JSON/time-grouping requirements. Do not proceed to Task 2 until this passes.

---

## Task 2: Add ImageIO one-pass JPEG writer with metadata

**Goal:** RAW conversion writes the final JPEG with ImageIO `CGImageDestination` in one pass, includes key metadata, records `writeJpgMs`, and has no OpenCV JPEG fallback.

**Files touched:**

- `cpp/include/jpgWriter.h` — new ImageIO writer interface.
- `cpp/src/jpgWriter.mm` — new ImageIO implementation.
- `cpp/src/rawConverter.cpp` — call ImageIO writer instead of `cv::imwrite`.
- `cpp/CMakeLists.txt` — add source and ImageIO framework link.

### Step 1 — Implement `jpgWriter` interface

Create `cpp/include/jpgWriter.h` with the required project file header and declarations similar to:

```cpp
struct jpgMetadata {
    int quality = 95;
    int orientation = 1;
    int dpi = 180;
    int64_t timestamp = 0;
    std::string make;
    std::string model;
    std::string software;
    std::string lensModel;
    double isoSpeed = 0.0;
    double exposureTime = 0.0;
    double fNumber = 0.0;
    double focalLength = 0.0;
    int focalLength35mm = 0;
    int exposureProgram = 0;
    int flash = 0;
};

bool writeJpgWithImageIo(const std::string& outputPath,
                         int width,
                         int height,
                         int colors,
                         const void* data,
                         const jpgMetadata& metadata,
                         std::string& error);
```

### Step 2 — Implement ImageIO writer

Create `cpp/src/jpgWriter.mm` with the required project file header and implement `writeJpgWithImageIo`.

Implementation requirements:

- Validate `width > 0`, `height > 0`, and `data != nullptr`.
- Support `colors == 3` RGB input from LibRaw.
- Support `colors == 1` grayscale input if LibRaw returns it.
- Reject all other channel counts with a clear error string.
- Do not call OpenCV.
- Do not include `opencv2/imgcodecs.hpp`.
- Convert RGB input to a CGImage-compatible buffer:
  - For RGB, create an RGBA buffer with alpha 255.
  - Use `CGColorSpaceCreateWithName(kCGColorSpaceSRGB)`.
  - Use `kCGImageAlphaLast | kCGBitmapByteOrder32Big` or a compiler-accepted equivalent.
- For grayscale, use a DeviceGray color space and one byte per pixel.
- Use `CGImageDestinationCreateWithURL` with `kUTTypeJPEG` or the modern equivalent available in the current SDK.
- Set JPEG quality from `metadata.quality / 100.0`, clamped to `[0.0, 1.0]`.
- Set DPI width/height to `metadata.dpi`, defaulting to 180.
- Build TIFF dictionary with available:
  - Make
  - Model
  - Software
  - DateTime
  - Orientation
  - XResolution
  - YResolution
  - ResolutionUnit
- Build EXIF dictionary with available:
  - DateTimeOriginal
  - DateTimeDigitized
  - ISOSpeedRatings
  - ExposureTime
  - FNumber
  - FocalLength
  - FocalLengthIn35mmFilm
  - LensModel
  - ExposureProgram
  - Flash
- Format EXIF/TIFF date strings as `YYYY:MM:DD HH:MM:SS` using `std::localtime` from `metadata.timestamp`.
- Skip optional fields when their string is empty or numeric value is non-positive, except `flash` may be written when explicitly set to 0.
- Ensure all CoreFoundation/CoreGraphics objects are released.
- Write to a temporary sibling path first, then rename to final path after `CGImageDestinationFinalize` succeeds.
- Remove the temporary file on failure.
- Return `false` and populate `error` on any failure.

### Step 3 — Modify `RawConverter::convert`

Update `cpp/src/rawConverter.cpp`:

- Bump file header version from `1.2` to `1.3` and mention ImageIO metadata output.
- Include `jpgWriter.h`.
- Remove the direct dependency on OpenCV JPEG writing from this file:
  - Remove `#include <opencv2/opencv.hpp>` if it is only used for `cv::imwrite`.
  - Remove `makeJpgWriteMatFromDecodedImage` usage from the conversion path.
  - Remove `cv::imwrite` usage.
- Keep LibRaw open/unpack/process/make image flow.
- After `dcraw_make_mem_image`, populate `jpgMetadata`:
  - `quality = config.rawConversion.jpgQuality`
  - `timestamp = rawProcessor.imgdata.other.timestamp`
  - `make = rawProcessor.imgdata.idata.make`
  - `model = rawProcessor.imgdata.idata.model`
  - `software = rawProcessor.imgdata.idata.software`
  - `isoSpeed = rawProcessor.imgdata.other.iso_speed`
  - `exposureTime = rawProcessor.imgdata.other.shutter`
  - `fNumber = rawProcessor.imgdata.other.aperture`
  - `focalLength = rawProcessor.imgdata.other.focal_len`
  - `lensModel = rawProcessor.imgdata.lens.Lens`
  - Fill `focalLength35mm`, `exposureProgram`, and `flash` only if available from LibRaw fields verified during implementation; otherwise leave defaults and let writer skip them.
- Measure only the ImageIO write call with `phaseTimer.reset()` and `result.writeJpgMs = phaseTimer.elapsedMs()`.
- If `writeJpgWithImageIo` returns false:
  - Clear LibRaw image memory.
  - Set `result.success = false`.
  - Set `result.error = "ImageIO write failed: " + error`.
  - Return result.
- If writing succeeds:
  - Clear LibRaw image memory.
  - Set `result.success = true`.
  - Return result.

Important: there must be no fallback branch that writes with OpenCV after ImageIO fails.

### Step 4 — Update CMake for ImageIO writer

Modify `cpp/CMakeLists.txt`:

- Add `src/jpgWriter.mm` to `SOURCES`.
- Under `if(APPLE)`, add:
  - `find_library(IMAGEIO_LIBRARY ImageIO)`
  - Link `${IMAGEIO_LIBRARY}` to `rawViewer`.
- Keep `-fobjc-arc` for Objective-C++ sources as already configured.

Do not create or enable test targets.

### Step 5 — Validate Task 2

Run:

```bash
cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=OFF
cmake --build cpp/build
```

Expected:

- Configure succeeds.
- Build succeeds.
- No `cpp/tests` directory is created.

Run static checks:

```bash
rg -n "cv::imwrite|OpenCV.*fallback|fallback.*OpenCV|writeJpgWithImageIo" cpp/src cpp/include
```

Expected:

- `writeJpgWithImageIo` appears in `jpgWriter.mm` and `rawConverter.cpp`.
- `cv::imwrite` does not appear in `rawConverter.cpp`.
- There is no OpenCV fallback branch.

Optional manual command for the user's later validation:

```bash
rm -rf /tmp/rawViewerMetaCheck
mkdir -p /tmp/rawViewerMetaCheck
cp /Users/wilbur/test_bak/P1001124.RW2 /tmp/rawViewerMetaCheck/
(cd cpp && ./build/rawViewer /tmp/rawViewerMetaCheck --config config.yaml)
sips -g all /tmp/rawViewerMetaCheck/P1001124.JPG
mdls -name kMDItemContentCreationDate \
     -name kMDItemAcquisitionMake \
     -name kMDItemAcquisitionModel \
     -name kMDItemISOSpeed \
     -name kMDItemExposureTimeSeconds \
     -name kMDItemFocalLength \
     -name kMDItemFocalLength35mm \
     -name kMDItemLensModel \
     -name kMDItemExposureProgram \
     -name kMDItemFlashOnOff \
     /tmp/rawViewerMetaCheck/P1001124.JPG
```

Expected if the user runs it:

- Output JPEG exists.
- `sips` shows creation/make/model when metadata is available.
- `mdls` shows available camera metadata.
- `.cache/conversion.log` contains `write_jpg=<number>ms` recorded from the ImageIO write path.

✅ **Done when:** The project builds, `rawConverter.cpp` no longer uses OpenCV JPEG output, and the only RAW conversion JPEG writer path is ImageIO.

---

## Task 3: Final integration review and compile gate

**Goal:** Confirm the full implementation matches the recipe and user constraints before handing off for real data testing.

**Files touched:** None unless Task 1 or Task 2 left a compile error.

### Step 1 — Full build

Run:

```bash
cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=OFF
cmake --build cpp/build
```

Expected:

- Build succeeds.

### Step 2 — Constraint checks

Run:

```bash
test ! -d cpp/tests && echo "no cpp/tests directory"
rg -n "cv::imwrite|OpenCV.*fallback|fallback.*OpenCV" cpp/src cpp/include || true
rg -n "shooting_time|shooting_time_source|review_group_id|dup_" cpp/src/jsonManager.cpp
rg -n "CGImageDestination|kCGImagePropertyExifDictionary|kCGImagePropertyTIFFDictionary" cpp/src/jpgWriter.mm
```

Expected:

- `no cpp/tests directory` is printed.
- No OpenCV JPEG fallback is present.
- JSON manager writes shooting time and duplicate group fields.
- JPEG writer uses ImageIO metadata dictionaries.

### Step 3 — Manual handoff note

Do not run destructive commands against the user's real photo folders unless explicitly asked. The user will perform actual tests.

✅ **Done when:** Build and static checks pass, and the implementation is ready for user-side real data validation.

---

## Self-review checklist

- Spec coverage: The plan covers JSON shooting time, 3-second rule B grouping, stable `dup_00x`, review group overwrite, preserved `template_photo_id`, ImageIO one-pass JPEG output, metadata fields, and no OpenCV fallback.
- User constraint coverage: The plan creates no test directory or test files and uses compile/static checks instead.
- Type consistency: New declarations are referenced by matching file names and call sites.
- Scope check: The plan does not change Swift models or add root-level duplicate indexes.
- Validation: Each task ends with build commands and static logic checks rather than test-file creation.
