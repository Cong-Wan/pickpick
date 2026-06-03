# RAW Metadata and Duplicate Groups Recipe

## Background

The current C++ pipeline scans top-level JPG/RAW files, pairs them by file stem, and writes one photo record per `photoId` into `.cache/analysis.json`. The Swift app already consumes `review_group_id` to display duplicate groups, so the new time-based duplicate grouping must write into that existing field.

The current RAW-to-JPG conversion uses LibRaw for decoding and OpenCV `cv::imwrite` for JPEG output. The generated JPEGs lose important metadata that exists in the RAW file and in camera-exported JPEGs, including shooting time, camera make/model, ISO, exposure time, focal length, and lens model.

## Goals

1. Add each photo's shooting time to `.cache/analysis.json`.
2. Automatically assign time-based duplicate groups to existing `review_group_id` so the Swift app can display them without model changes.
3. Generate duplicate group IDs as stable `dup_00x` values ordered by shooting time.
4. Change RAW-to-JPG output to use ImageIO `CGImageDestination` once, with key metadata written into the JPEG.
5. Do not install or require external metadata tools such as `exiftool` or `exiv2`.
6. Do not keep any fallback path that writes JPEGs with OpenCV when ImageIO fails.

## Non-goals

1. Do not change the Swift app data model for this feature.
2. Do not add a new root-level duplicate group index to the JSON.
3. Do not fully copy Panasonic MakerNotes, all XMP/IPTC fields, thumbnails, or every proprietary RAW metadata field in the first version.
4. Do not compare ImageIO performance against OpenCV in code or tests. The implementation should only record write timing; the user will evaluate performance separately.

## JSON Output Design

Each photo record in `.cache/analysis.json` must contain:

```json
{
  "shooting_time": "2026-03-21T09:02:06Z",
  "shooting_time_source": "raw",
  "review_group_id": "dup_001"
}
```

Field meanings:

- `shooting_time`
  - UTC ISO8601 string when a shooting time is available.
  - `null` when no shooting time can be read.
  - Must be present on every photo record after scanning/merge.
- `shooting_time_source`
  - `"raw"` when time was read from `raw_file_path`.
  - `"jpg"` when no RAW time is available and time was read from `file_path`.
  - `"none"` when neither source provides a time.
  - Must be present on every photo record after scanning/merge.
- `review_group_id`
  - Existing field consumed by the Swift app.
  - Automatically overwritten on each scan/merge.
  - Empty string for photos that do not belong to a duplicate group.
  - `dup_001`, `dup_002`, ... for duplicate groups with at least two photos.
- `template_photo_id`
  - Existing field.
  - Must not be proactively cleared or recomputed by automatic time grouping.

## Shooting Time Read Strategy

The first version should avoid expensive RAW decoding for metadata-only scanning.

Read strategy during scanning/JSON merge:

1. If `raw_file_path` exists, read RAW shooting time using macOS system metadata APIs.
2. If RAW time cannot be read and `file_path` exists, read JPG shooting time using macOS system metadata APIs.
3. If neither works, write `shooting_time: null` and `shooting_time_source: "none"`.

Rationale:

- The sample data under `/Users/wilbur/Downloads/LUMIX_Backup` exposes RAW shooting time through macOS metadata for all tested RAW files.
- A shell `mdls` subprocess loop over 158 RAW files took about 3.16 seconds, roughly 20 ms per file. A direct C++ macOS metadata API implementation should avoid per-file process startup overhead.
- This avoids duplicating the expensive LibRaw decode/open path for photos that already have JPGs and therefore do not enter RAW conversion.

## Duplicate Grouping Rule

Use threshold: 3 seconds.

Algorithm:

1. Collect photos with a valid `shooting_time`.
2. Sort by `(shooting_time, photoId)` ascending for deterministic output.
3. Walk sorted photos and build non-overlapping groups using group-start time:
   - Start a candidate group with the first ungrouped photo.
   - Add following photos while `currentPhotoTime - groupStartTime <= 3 seconds`.
   - Close the candidate group when the next photo would exceed 3 seconds.
4. If a candidate group has at least two photos, assign the next stable group ID:
   - First group by shooting time gets `dup_001`.
   - Second gets `dup_002`.
   - Continue as `dup_003`, etc.
5. If a candidate group has one photo, leave that photo's `review_group_id` as an empty string.
6. Before assigning new groups, clear all photos' `review_group_id` to empty string.
7. Do not clear `template_photo_id`.

This is rule B: the earliest and latest photo in the same group must be within 3 seconds.

## RAW-to-JPG Metadata Design

The conversion path must write JPEGs with ImageIO in one pass.

Current path:

```text
LibRaw -> processed RGB buffer -> cv::Mat -> OpenCV cv::imwrite
```

Target path:

```text
LibRaw -> processed RGB buffer -> CGImage -> CGImageDestination JPEG + metadata
```

Requirements:

1. Use ImageIO `CGImageDestination` for final JPEG writing.
2. Do not write a JPEG with OpenCV as a fallback.
3. If ImageIO writing fails, mark RAW conversion as failed and write a clear `raw_conversion_error`.
4. Continue recording write duration in `RawConvertResult::writeJpgMs` and `conversion.log`.
5. Missing optional metadata fields must not fail conversion. The JPEG should still be written with all available fields.

## JPEG Metadata Fields

Write these fields when source values are available:

TIFF-style fields:

- Make
- Model
- Software
- DateTime
- Orientation
- XResolution
- YResolution
- ResolutionUnit

EXIF-style fields:

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

Color/output fields:

- sRGB color space/profile
- JPEG quality from existing config
- DPI should be 180, matching the observed camera-exported JPEG style more closely than the current 72 DPI output

Expected LibRaw sources include:

- `imgdata.idata.make`
- `imgdata.idata.model`
- `imgdata.idata.software`
- `imgdata.other.timestamp`
- `imgdata.other.iso_speed`
- `imgdata.other.shutter`
- `imgdata.other.aperture`
- `imgdata.other.focal_len`
- `imgdata.lens.Lens`
- LibRaw shooting/makernote fields for 35mm focal length, exposure program, and flash when available

## Component Design

### Metadata reader

Add a small C++/Objective-C++ component for metadata-only time reads:

```text
cpp/include/photoMetadataReader.h
cpp/src/photoMetadataReader.mm
```

Responsibilities:

- Read shooting time from RAW or JPG using macOS system metadata APIs.
- Return ISO8601 UTC string, epoch seconds, and source string.
- Provide deterministic failure output for missing metadata.

### JSON manager integration

Modify `JsonManager::mergeScannedPairs()` to:

1. Preserve existing scan/merge behavior for paths and statuses.
2. Add missing JSON fields for existing records.
3. Read and write `shooting_time` / `shooting_time_source` for every photo.
4. Recompute and overwrite `review_group_id` for all photos after metadata is updated.
5. Leave `template_photo_id` unchanged.
6. Update summary as it does today.

### RAW converter integration

Modify `RawConverter::convert()` to:

1. Keep LibRaw open/unpack/process behavior.
2. Replace `cv::imwrite` JPEG output with ImageIO JPEG output.
3. Build metadata dictionaries from LibRaw data.
4. Record ImageIO write duration in `writeJpgMs`.
5. Return failure when ImageIO cannot create/write the final JPEG.

CMake must link the macOS frameworks needed for ImageIO/CoreFoundation/CoreGraphics if they are not already linked.

## Error Handling

- Metadata read failure for one photo must not stop scanning.
- Photos with no readable time must still have `shooting_time` and `shooting_time_source` fields.
- Photos with no readable time must not be assigned to `dup_00x` groups.
- ImageIO write failure must fail that RAW conversion task.
- Missing optional EXIF fields such as LensModel or FNumber must not fail JPEG writing.
- The implementation must avoid leaving a partially written final JPEG when ImageIO fails.

## Validation Plan

### JSON validation using `/Users/wilbur/Downloads/LUMIX_Backup`

Expected checks:

1. `.cache/analysis.json` has `shooting_time` and `shooting_time_source` on every photo.
2. RAW-backed photos use `shooting_time_source: "raw"` when RAW metadata is available.
3. Single-photo windows have `review_group_id: ""`.
4. Duplicate groups use stable group IDs ordered by shooting time.
5. With the sampled data and 3-second rule, representative groups include:
   - `dup_001`: `P1000275`, `P1000277`
   - `dup_002`: `P1000313`, `P1000314`
   - later groups continue in shooting-time order.

### Swift app compatibility validation

Expected checks:

1. No Swift model change is required for duplicate display.
2. Existing duplicate grouping uses `review_group_id` and should display `dup_001`, `dup_002`, etc.
3. Existing review/template operations continue using `review_group_id` and `template_photo_id`.

### JPEG metadata validation using `/Users/wilbur/test_bak/P1001124.RW2`

Expected checks after conversion:

1. The output JPEG exists and opens normally.
2. `sips -g all` shows at least creation, make, and model when LibRaw provides them.
3. `mdls` shows available camera metadata such as:
   - `kMDItemContentCreationDate`
   - `kMDItemAcquisitionMake`
   - `kMDItemAcquisitionModel`
   - `kMDItemISOSpeed`
   - `kMDItemExposureTimeSeconds`
   - `kMDItemFocalLength`
   - `kMDItemFocalLength35mm` when available
   - `kMDItemLensModel` when available
   - `kMDItemExposureProgram` when available
   - `kMDItemFlashOnOff` when available
4. `conversion.log` records `write_jpg` duration for the ImageIO write path.
5. There is no OpenCV JPEG fallback path.

## Open Questions Resolved

- Duplicate threshold is 3 seconds.
- Grouping uses rule B: earliest and latest in group must be within threshold.
- Group IDs are stable by shooting time and formatted as `dup_00x`.
- Existing `review_group_id` may be overwritten on each scan.
- Existing `template_photo_id` should not be proactively cleared.
- ImageIO is the only allowed JPEG writer for converted RAW output.
