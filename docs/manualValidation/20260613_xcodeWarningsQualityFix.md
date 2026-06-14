# Manual Validation — Xcode Warnings Quality Fix

## Constraints

- Do not add XCTest, Quick, Nimble, or any other test framework.
- Do not add validation scripts.
- Validation uses Xcode build output, Xcode console, and manual App behavior only.

## Build Validation

1. Run:

   ```bash
   xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -derivedDataPath build/qualityFixDerived clean build
   ```

2. Confirm build output contains:

   ```text
   ** BUILD SUCCEEDED **
   ```

3. Confirm Xcode no longer reports these warning families:

   - duplicate `-lc++`
   - CFDate forced downcast warning
   - unused `index`
   - AppKit delegate MainActor warning
   - `metalAnalysisContext.shared()` MainActor warning
   - `DispatchGroup.wait` unavailable from async contexts

## Startup Validation

1. Launch pickpick from Xcode.
2. Confirm the main window appears.
3. Confirm the title is `pickpick`.
4. Close the last window.
5. Confirm the App terminates normally.

## Analysis Validation

1. Select a folder containing JPG-only photos.
2. Confirm progress reaches completion and the group grid opens.
3. Select a folder containing RAW-only photos.
4. Confirm progress reaches completion and the group grid opens.
5. Select a folder containing RAW+JPG pairs.
6. Confirm progress reaches completion and duplicate/quality groups appear when applicable.
7. Select a folder containing one damaged or unsupported image.
8. Confirm the App does not crash.
9. Confirm the damaged or unsupported image is not shown as Normal.
10. Watch the Xcode console during analysis and confirm the previous `photoAnalysisService.analyze` Thread Performance Checker backtrace does not appear.

## Browser Validation

1. Open a non-duplicate group.
2. Use Up/Down keys to navigate photos.
3. Confirm the displayed image matches the selected thumbnail.
4. Confirm JPG segment is enabled only when a real JPG exists.
5. Confirm RAW segment is enabled only when a real RAW exists.
6. Zoom in, zoom out, and reset zoom.
7. Rotate left and right.
8. Leave and re-enter the group and confirm rotation persists.

## Duplicate Compare Validation

1. Open a duplicate group.
2. Confirm left and right images load.
3. Use Left Arrow to keep the left photo.
4. Reopen another duplicate group if available.
5. Use Right Arrow to keep the right photo.
6. Use Keep both.
7. Confirm JPG/RAW segment availability matches files on either side.
8. Confirm zoom and rotation actions affect both sides.

## State Mutation Validation

1. Delete a photo.
2. Confirm the file moves to macOS Trash.
3. Quit and relaunch the App.
4. Reopen the same folder.
5. Confirm the deleted photo is not visible.
6. Use Restore Normal on an abnormal photo.
7. Quit and relaunch the App.
8. Confirm the restored photo no longer appears in the abnormal group.
9. Perform rotation, delete, and Restore Normal actions quickly in sequence.
10. Quit and relaunch the App.
11. Confirm all states persisted correctly and no JSON decode error appears in Xcode console.
