# rawViewer macOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first AppKit version of rawViewer: select a folder, run the existing C++ analyzer through an Objective-C++ bridge, show analysis progress, display grouped results, browse photos with a Metal-backed viewer, and handle duplicate groups with a two-photo comparison workflow.

**Architecture:** Keep C++ responsible for analysis, persistence, and resume data. Add a thin Objective-C++ bridge that exposes App-friendly callbacks and models. Replace the initial SwiftUI shell with an AppKit window controller and focused Swift views/controllers for start, progress, groups, normal browsing, and duplicate comparison.

**Tech Stack:** macOS AppKit, Swift 5, Objective-C++, C++17, MetalKit, Core Image, ImageIO, nlohmann/json, XCTest, existing Xcode project and C++ sources.

---

## File Structure

- `cpp/include/appRunner.h` / `cpp/src/appRunner.cpp` — add progress callback support while preserving CLI behavior.
- `cpp/include/taskState.h` / `cpp/src/taskState.cpp` — add App review status enum and string conversion helpers.
- `cpp/include/jsonManager.h` / `cpp/src/jsonManager.cpp` — persist App review state, template photo id, and trash metadata.
- `rawViewer/rawViewerApp.swift` — replace SwiftUI app entry with AppKit application delegate entry.
- `rawViewer/appDelegate.swift` — create and own the main window.
- `rawViewer/mainWindowController.swift` — coordinate screen transitions and shared app state.
- `rawViewer/photoModels.swift` — Swift models for analysis progress, photos, groups, display source, and duplicate review status.
- `rawViewer/photoAnalyzerBridge.h` / `rawViewer/photoAnalyzerBridge.mm` — Objective-C++ wrapper over C++ analyzer and JSON result loading.
- `rawViewer/photoAnalyzerBridge.swift` — Swift-facing async facade around the Objective-C++ bridge.
- `rawViewer/startViewController.swift` — wide dashed folder drop zone and folder picker.
- `rawViewer/progressViewController.swift` — minimal blue circular progress screen.
- `rawViewer/groupGridViewController.swift` — card-style grouped result overview.
- `rawViewer/photoBrowserViewController.swift` — normal group browser with toolbar, thumbnail list, delete confirmation, and RAW/JPG segmented control.
- `rawViewer/duplicateCompareViewController.swift` — duplicate group two-photo comparison workflow.
- `rawViewer/metalPhotoView.swift` — `MTKView`-based main image renderer using Core Image and Metal textures.
- `rawViewer/photoThumbnailCache.swift` — async thumbnail loading and caching.
- `rawViewer/jsonReviewStateStore.swift` — Swift-side operations for updating App review fields in `analysis.json`.
- `rawViewerTests/*.swift` — XCTest coverage for grouping, review state updates, display source persistence, progress state mapping, and duplicate workflow decisions.
- `rawViewer.xcodeproj/project.pbxproj` — add new source files, frameworks, test files, and build settings.

Do not restructure the existing C++ modules beyond the files listed above. Do not delete `cpp/main.cpp`; it remains the CLI validation entry.

---

## Task 0: Environment Setup

**Goal:** Establish a clean build/test baseline before modifying implementation files.

**Files touched:** None.

- [ ] Create a working branch:

```bash
$ git status --short
# Expected: review existing local changes. Do not revert unrelated changes.

$ git switch -c feature/raw-viewer-app
# Expected: Switched to a new branch 'feature/raw-viewer-app'
```

- [ ] Confirm Xcode project targets:

```bash
$ xcodebuild -list -project rawViewer.xcodeproj
# Expected: targets include rawViewer, PhotoAnalyzerCLI, rawViewerTests.
```

- [ ] Build the app target:

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

- [ ] Run the test target:

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS'
# Expected baseline: tests either pass or fail only because the initial test target has no meaningful tests. Any build failure must be fixed before Task 1.
```

- [ ] Build the C++ CLI target:

```bash
$ xcodebuild -project rawViewer.xcodeproj -target PhotoAnalyzerCLI -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

✅ **Done when:** The current project builds, test target status is understood, and no unrelated local edits were reverted.

---

### Task 1: Add C++ Progress Callback

**Goal:** The analyzer can report scanning, RAW conversion, analysis, organizing, and completed progress without breaking the existing CLI target.

**Files touched:**

- `cpp/include/appRunner.h` — define `RunPhase`, `RunProgress`, and callback field on `RunOptions`.
- `cpp/src/appRunner.cpp` — emit progress updates during `run()`.
- `cpp/src/taskState.cpp` — no change unless string helpers are needed.
- `rawViewerTests/appRunnerProgressTests.swift` or a C++ test harness if the project already has one — verify phase ordering through a bridge-facing seam.

#### Step 1 — Implement

- [ ] Add:

```cpp
enum class RunPhase {
    Scanning,
    RawConversion,
    Analysis,
    Organizing,
    Completed
};

struct RunProgress {
    RunPhase phase = RunPhase::Scanning;
    int completedCount = 0;
    int totalCount = 0;
    double overallProgress = 0.0;
};
```

- [ ] Add `std::function<void(const RunProgress&)> progressCallback;` to `RunOptions`.
- [ ] In `AppRunner::run()`, emit:
  - `Scanning` before and after `scanTopLevel()`;
  - `RawConversion` once before tasks start and after each conversion result is persisted;
  - `Analysis` once before tasks start and after each analysis result is persisted;
  - `Organizing` before final summary;
  - `Completed` after final `atomicSave()`.
- [ ] Compute `overallProgress` monotonically from the known stage totals. If a stage has zero tasks, emit one progress event for that stage with `completedCount == totalCount == 0`.
- [ ] Keep `main.cpp` behavior unchanged except it can ignore progress by leaving the callback empty.

#### Step 2 — Write tests based on the plan goal

- [ ] Add a test seam using fake converter/analyzer callbacks already supported by `AppRunner`.
- [ ] Use a temporary folder fixture containing simple JPG names and a minimal config file.
- [ ] Assert:
  - progress contains `Scanning`, `Analysis`, `Organizing`, `Completed`;
  - final progress is `Completed` with `overallProgress == 1.0`;
  - phases never move backward;
  - an empty folder reports a terminal failure or clean empty result consistently with existing analyzer behavior.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/AppRunnerProgressTests
# Expected: AppRunnerProgressTests pass.
```

If the test cannot link C++ into the Swift test target yet, add a small Objective-C++ test bridge for this task rather than weakening the assertions.

#### Step 4 — Commit

```bash
git add cpp/include/appRunner.h cpp/src/appRunner.cpp rawViewerTests
git commit -m "feat(analyzer): report app progress"
```

✅ **Done when:** Progress events are emitted, tests verify phase behavior, and the commit is made.

---

### Task 2: Persist App Review State In Analysis JSON

**Goal:** App actions can mark photos as active, kept, passed, or trashed so future launches do not load missing files.

**Files touched:**

- `cpp/include/taskState.h` — add review state fields to `PhotoTaskState`.
- `cpp/src/taskState.cpp` — add enum/string helpers.
- `cpp/include/jsonManager.h` — add update methods for review state and template image.
- `cpp/src/jsonManager.cpp` — read/write review fields.
- `rawViewerTests/reviewStateJsonTests.swift` or C++ JSON tests — verify persisted state.

#### Step 1 — Implement

- [ ] Add enum:

```cpp
enum class ReviewStatus {
    Active,
    Kept,
    Passed,
    Trashed
};
```

- [ ] Add fields to `PhotoTaskState`:

```cpp
ReviewStatus reviewStatus = ReviewStatus::Active;
std::string reviewGroupId;
std::string templatePhotoId;
std::string trashedAt;
```

- [ ] Add helpers:

```cpp
std::string toString(ReviewStatus status);
ReviewStatus reviewStatusFromString(const std::string& value);
```

- [ ] Extend JSON load defaults:
  - missing `review_status` maps to `active`;
  - missing `review_group_id`, `template_photo_id`, `trashed_at` maps to empty string.
- [ ] Extend JSON save/update behavior with:
  - `review_status`;
  - `review_group_id`;
  - `template_photo_id`;
  - `trashed_at`.
- [ ] Add JSON manager methods:

```cpp
void updateReviewStatus(const std::string& photoId, ReviewStatus status, const std::string& trashedAt);
void updateDuplicateTemplate(const std::string& reviewGroupId, const std::string& templatePhotoId);
```

#### Step 2 — Write tests based on the plan goal

- [ ] Create a temp folder and seed `.cache/analysis.json` with two photos.
- [ ] Mark one photo `trashed` with a timestamp.
- [ ] Mark both photos with the same `review_group_id` and set a template id.
- [ ] Reload through `JsonManager`.
- [ ] Assert:
  - trashed photo remains in JSON but has `reviewStatus == Trashed`;
  - template id is present for the duplicate group;
  - older JSON without review fields loads as `Active`.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/ReviewStateJsonTests
# Expected: ReviewStateJsonTests pass.
```

#### Step 4 — Commit

```bash
git add cpp/include/taskState.h cpp/src/taskState.cpp cpp/include/jsonManager.h cpp/src/jsonManager.cpp rawViewerTests
git commit -m "feat(json): persist photo review state"
```

✅ **Done when:** JSON review fields round-trip, legacy JSON remains readable, and the commit is made.

---

### Task 3: Add Swift Models And Grouping Logic

**Goal:** Swift code can load analyzer output into typed models and build visible groups while filtering passed/trashed photos.

**Files touched:**

- `rawViewer/photoModels.swift` — define models and grouping functions.
- `rawViewerTests/photoGroupingTests.swift` — verify grouping behavior.
- `rawViewer.xcodeproj/project.pbxproj` — include files in app and test targets.

#### Step 1 — Implement

- [ ] Define `displaySource` as `.jpg` and `.raw`.
- [ ] Define `reviewStatus` as `.active`, `.kept`, `.passed`, `.trashed`.
- [ ] Define `photoItem` with:
  - `photoId`;
  - `jpgPath`;
  - `rawPath`;
  - `isBlurry`;
  - `exposureStatus`;
  - `reviewStatus`;
  - `reviewGroupId`;
  - `templatePhotoId`.
- [ ] Define `photoGroupKind`:
  - `.overexposed`;
  - `.underexposed`;
  - `.blurry`;
  - `.normal`;
  - `.duplicate(reviewGroupId: String)`.
- [ ] Define grouping function:
  - ignore `.passed` and `.trashed`;
  - include blurry photos in blurry group;
  - include overexposed photos in overexposed group;
  - include underexposed photos in underexposed group;
  - include non-blurry normal exposure photos in normal group;
  - group non-empty `reviewGroupId` photos into duplicate groups.

#### Step 2 — Write tests based on the plan goal

- [ ] Assert a blurry overexposed photo appears in both blurry and overexposed groups.
- [ ] Assert passed and trashed photos appear in no visible groups.
- [ ] Assert normal group includes only non-blurry normal exposure photos.
- [ ] Assert duplicate group is created per `reviewGroupId`.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/PhotoGroupingTests
# Expected: PhotoGroupingTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/photoModels.swift rawViewerTests/photoGroupingTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(app): model photo groups"
```

✅ **Done when:** Grouping logic is typed, tested, and committed.

---

### Task 4: Add Objective-C++ Analyzer Bridge

**Goal:** The macOS app can start C++ analysis and load typed results without executing a command-line binary.

**Files touched:**

- `rawViewer/photoAnalyzerBridge.h` — Objective-C API.
- `rawViewer/photoAnalyzerBridge.mm` — C++ integration.
- `rawViewer/photoAnalyzerBridge.swift` — Swift async facade.
- `rawViewerTests/photoAnalyzerBridgeTests.swift` — bridge behavior tests.
- `rawViewer.xcodeproj/project.pbxproj` — add `.mm`, header, Swift facade, C++ source membership, and linker settings.

#### Step 1 — Implement

- [ ] Expose Objective-C classes:
  - `rwAnalysisProgress`;
  - `rwAnalysisResult`;
  - `rwPhotoRecord`;
  - `rwPhotoAnalyzerBridge`.
- [ ] `rwPhotoAnalyzerBridge` methods:

```objc
- (void)startAnalysisAtFolderPath:(NSString *)folderPath
                       configPath:(NSString *)configPath
                         progress:(void (^)(rwAnalysisProgress *progress))progress
                       completion:(void (^)(rwAnalysisResult *result, NSError *error))completion;

- (NSArray<rwPhotoRecord *> *)loadAnalysisResultAtFolderPath:(NSString *)folderPath
                                                        error:(NSError **)error;
```

- [ ] In `.mm`, call `AppRunner::run(options)` directly.
- [ ] Convert C++ progress to Objective-C progress.
- [ ] Dispatch progress and completion callbacks to the main queue.
- [ ] Convert C++ exceptions into `NSError`.
- [ ] Implement `loadAnalysisResultAtFolderPath` by reading `.cache/analysis.json` through `JsonManager`, not by reparsing ad hoc strings.

#### Step 2 — Write tests based on the plan goal

- [ ] Test loading a seeded JSON fixture returns records with review status.
- [ ] Test missing JSON returns a non-nil error.
- [ ] Test progress callbacks are delivered on the main thread using a fake or small fixture.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/PhotoAnalyzerBridgeTests
# Expected: PhotoAnalyzerBridgeTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/photoAnalyzerBridge.h rawViewer/photoAnalyzerBridge.mm rawViewer/photoAnalyzerBridge.swift rawViewerTests/photoAnalyzerBridgeTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(app): bridge analyzer into app"
```

✅ **Done when:** The bridge calls C++ functions directly, returns typed data, and tests pass.

---

### Task 5: Replace SwiftUI Shell With AppKit Window Flow

**Goal:** Launching the app opens an AppKit window controlled by explicit screen transitions instead of the initial SwiftUI hello-world screen.

**Files touched:**

- `rawViewer/rawViewerApp.swift` — remove SwiftUI `App` entry or exclude from target.
- `rawViewer/ContentView.swift` — remove from target or leave unused if project membership is adjusted.
- `rawViewer/appDelegate.swift` — app entry and lifecycle.
- `rawViewer/mainWindowController.swift` — screen coordinator.
- `rawViewer.xcodeproj/project.pbxproj` — target membership and generated Info.plist settings.
- `rawViewerTests/mainWindowControllerTests.swift` — state transition tests.

#### Step 1 — Implement

- [ ] Use `@main final class appDelegate: NSObject, NSApplicationDelegate`.
- [ ] Create a main `NSWindow` with:
  - title `rawViewer`;
  - minimum size suitable for the wide drop zone;
  - content size around `1100 x 760`.
- [ ] `mainWindowController` owns an enum screen state:
  - `.start`;
  - `.progress`;
  - `.groups`;
  - `.browser`;
  - `.duplicateCompare`;
  - `.error`.
- [ ] Add methods:
  - `showStart()`;
  - `startAnalysis(folderUrl:)`;
  - `showGroups(records:)`;
  - `showGroup(group:)`;
  - `showError(message:)`.

#### Step 2 — Write tests based on the plan goal

- [ ] Instantiate `mainWindowController` without showing a real window.
- [ ] Assert initial state is `.start`.
- [ ] Assert `startAnalysis` switches to `.progress`.
- [ ] Assert selecting a normal group switches to `.browser`.
- [ ] Assert selecting duplicate group switches to `.duplicateCompare`.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/MainWindowControllerTests
# Expected: MainWindowControllerTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/appDelegate.swift rawViewer/mainWindowController.swift rawViewer/rawViewerApp.swift rawViewer/ContentView.swift rawViewerTests/mainWindowControllerTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(app): use appkit window flow"
```

✅ **Done when:** The app launches into an AppKit-controlled start screen path and tests verify screen routing.

---

### Task 6: Build Start And Progress Screens

**Goal:** Users can choose or drag a folder, then see the selected minimal circular progress UI while analysis runs.

**Files touched:**

- `rawViewer/startViewController.swift` — wide dashed drop zone and folder picker.
- `rawViewer/progressViewController.swift` — circular progress UI.
- `rawViewer/mainWindowController.swift` — wire start/progress callbacks.
- `rawViewerTests/startProgressTests.swift` — unit tests for accepted inputs and progress formatting.

#### Step 1 — Implement

- [ ] Start screen:
  - centered dashed drop zone;
  - min visual size `420 x 230`;
  - max visual size `760 x 300`;
  - gray plus sign;
  - small text: click to choose a folder or drag it here;
  - accepts folder URLs only.
- [ ] Folder picker:
  - uses `NSOpenPanel`;
  - `canChooseDirectories = true`;
  - `canChooseFiles = false`;
  - single selection.
- [ ] Progress screen:
  - large centered circular progress;
  - blue edge fill;
  - percentage in center;
  - phase label below;
  - count label below phase label.

#### Step 2 — Write tests based on the plan goal

- [ ] Assert files are rejected and directories are accepted by the drop validator.
- [ ] Assert progress formatter maps phases to the agreed text.
- [ ] Assert progress percent clamps to `0...100`.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/StartProgressTests
# Expected: StartProgressTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/startViewController.swift rawViewer/progressViewController.swift rawViewer/mainWindowController.swift rawViewerTests/startProgressTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(app): add start and progress screens"
```

✅ **Done when:** Folder selection starts analysis, progress screen updates, tests pass, and commit is made.

---

### Task 7: Build Result Group Grid

**Goal:** Completed analysis results appear as card-style groups for overexposed, underexposed, blurry, normal, and duplicate groups.

**Files touched:**

- `rawViewer/groupGridViewController.swift` — card grid UI.
- `rawViewer/photoThumbnailCache.swift` — preview image loading.
- `rawViewer/mainWindowController.swift` — route group selection.
- `rawViewerTests/groupGridTests.swift` — group card ordering and visibility tests.

#### Step 1 — Implement

- [ ] Use a scrollable grid of cards.
- [ ] Each card shows:
  - group title;
  - photo count;
  - representative preview.
- [ ] Include cards only for non-empty groups.
- [ ] Duplicate group cards use `templatePhotoId` when present; otherwise first visible photo.
- [ ] Selecting a normal group opens `photoBrowserViewController`.
- [ ] Selecting duplicate group opens `duplicateCompareViewController`.

#### Step 2 — Write tests based on the plan goal

- [ ] Assert empty groups are hidden.
- [ ] Assert duplicate card preview uses `templatePhotoId`.
- [ ] Assert normal group selection routes to browser.
- [ ] Assert duplicate group selection routes to duplicate compare.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/GroupGridTests
# Expected: GroupGridTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/groupGridViewController.swift rawViewer/photoThumbnailCache.swift rawViewer/mainWindowController.swift rawViewerTests/groupGridTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(app): show result group cards"
```

✅ **Done when:** Group cards render, route correctly, tests pass, and commit is made.

---

### Task 8: Add Metal/Core Image Photo Viewer

**Goal:** The main photo area renders JPG and supported RAW files through `MTKView + MTLTexture`.

**Files touched:**

- `rawViewer/metalPhotoView.swift` — MetalKit/Core Image renderer.
- `rawViewer/photoModels.swift` — display source persistence helpers if not already added.
- `rawViewerTests/displaySourceTests.swift` — preference persistence tests.
- `rawViewer.xcodeproj/project.pbxproj` — link MetalKit, Metal, CoreImage, ImageIO.

#### Step 1 — Implement

- [ ] Create `metalPhotoView: MTKView`.
- [ ] Own:
  - `MTLDevice`;
  - `MTLCommandQueue`;
  - Metal-backed `CIContext`;
  - current `CIImage`.
- [ ] `loadPhoto(url:)`:
  - create `CIImage(contentsOf:)`;
  - report failure if image cannot load;
  - draw into current drawable with aspect-fit scaling.
- [ ] JPG and RAW go through the same `loadPhoto(url:)` entry.
- [ ] Store display source in `UserDefaults` with default `.jpg`.
- [ ] If RAW is requested but no RAW path exists, disable RAW selection for that photo.

#### Step 2 — Write tests based on the plan goal

- [ ] Test display source default is JPG.
- [ ] Test switching to RAW persists across a new preference store instance.
- [ ] Test missing RAW path reports unavailable instead of falling through silently.
- [ ] Manual verification is required for actual `MTKView` rendering because it depends on graphics context.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/DisplaySourceTests
# Expected: DisplaySourceTests pass.
```

Manual render check:

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

Open the app, load a known JPG group, and confirm the main image is visible in the `MTKView`.

#### Step 4 — Commit

```bash
git add rawViewer/metalPhotoView.swift rawViewer/photoModels.swift rawViewerTests/displaySourceTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(viewer): render photos with metal"
```

✅ **Done when:** Display source preference is tested, Metal viewer builds, manual render check succeeds, and commit is made.

---

### Task 9: Build Normal Photo Browser

**Goal:** Users can browse normal result groups with thumbnails, keyboard navigation, RAW/JPG switching, and confirmed deletion.

**Files touched:**

- `rawViewer/photoBrowserViewController.swift` — browser UI and keyboard handling.
- `rawViewer/jsonReviewStateStore.swift` — update JSON after delete.
- `rawViewer/photoThumbnailCache.swift` — thumbnail list support.
- `rawViewerTests/photoBrowserTests.swift` — navigation and delete state tests.

#### Step 1 — Implement

- [ ] Top toolbar:
  - group name and count on left;
  - delete button and RAW/JPG segmented control on right.
- [ ] Left thumbnail list:
  - vertical;
  - per-photo checkbox;
  - select-all checkbox;
  - current photo highlight.
- [ ] Main area:
  - `metalPhotoView`;
  - first photo selected on entry.
- [ ] Keyboard:
  - up arrow selects previous photo;
  - down arrow selects next photo;
  - `Backspace` requests delete current photo with confirmation.
- [ ] Delete:
  - if checked photos exist, delete checked photos;
  - otherwise delete current photo;
  - show confirmation dialog;
  - update `analysis.json` to `review_status = trashed`;
  - move files to system trash;
  - remove photos from current list.

#### Step 2 — Write tests based on the plan goal

- [ ] Assert up/down navigation clamps at list boundaries.
- [ ] Assert delete target uses checked photos when present.
- [ ] Assert delete target uses current photo when no checks exist.
- [ ] Assert JSON update is requested before the visible list advances.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/PhotoBrowserTests
# Expected: PhotoBrowserTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/photoBrowserViewController.swift rawViewer/jsonReviewStateStore.swift rawViewer/photoThumbnailCache.swift rawViewerTests/photoBrowserTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(browser): browse and delete grouped photos"
```

✅ **Done when:** Normal browser works, deletion is confirmed and persisted, tests pass, and commit is made.

---

### Task 10: Build Duplicate Compare Workflow

**Goal:** Duplicate groups open a dedicated two-photo comparison screen that persists keep/pass decisions and supports fast keyboard selection.

**Files touched:**

- `rawViewer/duplicateCompareViewController.swift` — duplicate comparison UI and state machine.
- `rawViewer/jsonReviewStateStore.swift` — keep/pass/template operations.
- `rawViewer/metalPhotoView.swift` — reuse for left and right image panes.
- `rawViewerTests/duplicateCompareTests.swift` — workflow decision tests.

#### Step 1 — Implement

- [ ] Screen layout:
  - top toolbar with duplicate group name/count;
  - `Keep both` button;
  - RAW/JPG segmented control;
  - left main image;
  - right candidate image.
- [ ] Behavior:
  - left image is always the main image;
  - right image is the candidate;
  - left arrow keeps left, marks right passed/trashed, deletes right, and loads next candidate;
  - right arrow keeps right, marks left passed/trashed, deletes left, animates right image left, and loads next candidate;
  - no second confirmation for passed duplicate photos;
  - `R` switches RAW;
  - `J` switches JPG.
- [ ] `Keep both` dialog:
  - asks user to choose template image;
  - left arrow chooses left template;
  - right arrow chooses right template;
  - both photos are marked kept;
  - no files are deleted.
- [ ] End:
  - if only one image remains, mark it kept and template;
  - return to group grid or show group complete state.

#### Step 2 — Write tests based on the plan goal

- [ ] Assert keeping left advances candidate and marks previous right as trashed.
- [ ] Assert keeping right makes previous right the new main and marks previous left as trashed.
- [ ] Assert keep both marks both kept and stores selected template id.
- [ ] Assert no delete confirmation is requested for duplicate pass actions.
- [ ] Assert empty/right-exhausted state marks the remaining main image kept.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' -only-testing:rawViewerTests/DuplicateCompareTests
# Expected: DuplicateCompareTests pass.
```

#### Step 4 — Commit

```bash
git add rawViewer/duplicateCompareViewController.swift rawViewer/jsonReviewStateStore.swift rawViewer/metalPhotoView.swift rawViewerTests/duplicateCompareTests.swift rawViewer.xcodeproj/project.pbxproj
git commit -m "feat(duplicates): compare and keep duplicate photos"
```

✅ **Done when:** Duplicate workflow matches the approved design, JSON state is updated, tests pass, and commit is made.

---

### Task 11: End-To-End Integration And Manual Verification

**Goal:** The first-version app flow works from folder selection through analysis, grouped results, normal browsing, duplicate comparison, RAW/JPG persistence, and JSON state persistence.

**Files touched:**

- `rawViewer/mainWindowController.swift` — integration fixes only.
- `rawViewer/*.swift` — only files already introduced by earlier tasks.
- `rawViewer.xcodeproj/project.pbxproj` — final target membership/framework fixes only.
- `docs/recipe/20260601_raw_viewer_app_design.md` — update only if implementation intentionally differs from approved design.

#### Step 1 — Implement

- [ ] Wire final success path:
  - start screen chooses folder;
  - progress screen subscribes to bridge progress;
  - completion loads records;
  - group grid appears.
- [ ] Wire final error path:
  - folder permission errors return to start or show error;
  - analyzer errors stay visible;
  - JSON load errors show actionable text;
  - RAW load errors affect only the current image.
- [ ] Ensure app operations update JSON before advancing UI.
- [ ] Ensure missing files with active/kept status show a missing-file state rather than crashing.

#### Step 2 — Write tests based on the plan goal

- [ ] Add integration-style tests with seeded JSON:
  - normal flow routes start → progress → groups;
  - missing active file produces missing-file state;
  - trashed photo is filtered from groups after reload;
  - display source preference survives re-instantiating controllers.

#### Step 3 — Run tests and confirm all pass

```bash
$ xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS'
# Expected: all rawViewerTests pass.
```

Manual checks:

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug build
# Expected: ** BUILD SUCCEEDED **
```

- [ ] Open app.
- [ ] Select a folder with JPG files.
- [ ] Confirm circular progress appears and updates.
- [ ] Confirm group cards appear after analysis.
- [ ] Open a normal group and navigate with up/down keys.
- [ ] Switch JPG to RAW, close/reopen app, and confirm preference persists.
- [ ] Delete a photo from a normal group, confirm it moves to trash and JSON marks it trashed.
- [ ] Seed a duplicate group in JSON, open it, use left/right arrows, and confirm pass/delete state persists.
- [ ] Use `Keep both`, choose template with arrow key, and confirm group card preview uses that template.

#### Step 4 — Commit

```bash
git add rawViewer rawViewerTests rawViewer.xcodeproj/project.pbxproj docs/recipe/20260601_raw_viewer_app_design.md
git commit -m "test(app): verify first version flow"
```

✅ **Done when:** Full test suite passes, manual checks pass, and final commit is made.

---

## Self-Review

**Spec coverage:** The plan covers direct C++ function calling, AppKit shell, wide folder drop zone, minimal circular progress, card result groups, normal browser, `RAW/JPG` persistence, Metal main rendering, duplicate compare workflow, and JSON review state persistence.

**Unresolved-language scan:** No task relies on vague markers or unnamed future work. The implementation details are explicit enough for a worker to execute task-by-task in the named files.

**Type consistency:** The plan uses consistent names for `reviewStatus`, `displaySource`, `reviewGroupId`, `templatePhotoId`, `RunProgress`, and `RunPhase`.

**Test completeness:** Each implementation task has a dedicated test command and asserts observable behavior. Manual verification is explicitly required only for the graphics path that cannot be fully validated by unit tests.
