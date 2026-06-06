# rawViewer Bug Fix Internal Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the nine reported rawViewer App bugs while preserving the user-visible App layout and improving internal architecture with ViewModels, centralized image loading, caching, and thinner controllers.

**Architecture:** Keep the existing AppKit page structure, but move page state into ViewModels and image IO into `photoImageService` plus `photoImageCache`. `mainWindowController` remains the window composition point, while `metalPhotoView` becomes a display-only view that accepts prepared `CIImage` values and never performs file loading during zoom or source switching.

**Tech Stack:** Swift 5, AppKit, Core Image, MetalKit, `NSCache`, current script-style Swift tests under `tests/`, Xcode `rawViewer` scheme.

---

## Scope and Non-Negotiable Rules

- Do not redesign the App layout.
- Do not change the visible page structure:
  - start page remains a central folder selection area;
  - groups page remains a group card grid;
  - browser page remains toolbar + left thumbnails + right main photo;
  - duplicate page remains toolbar + left/right compare images.
- Code may be heavily refactored internally.
- Every task must be implemented first, then tested.
- Do not proceed to the next task until the current task's tests pass.
- Existing user work in the repository must not be overwritten unnecessarily.

---

## File Structure Map

### New files

- `rawViewer/appNavigationViewModel.swift` — central screen state and back-navigation rules.
- `rawViewer/groupGridViewModel.swift` — visible group list, route decisions, preview item selection, responsive column calculation.
- `rawViewer/photoBrowserViewModel.swift` — normal browser state, current index, selection, delete target rules, display request identity.
- `rawViewer/duplicateCompareViewModel.swift` — duplicate compare state machine, especially two-photo finish behavior.
- `rawViewer/photoImageCache.swift` — `NSCache` wrapper keyed by photo id, source kind, and thumbnail size.
- `rawViewer/photoImageService.swift` — Core Image JPG/RAW loading, thumbnail downsampling, display-pair preloading.
- `tests/appNavigationViewModelTests.swift` — navigation behavior coverage.
- `tests/groupGridViewModelTests.swift` — group filtering, routing, preview, column count coverage.
- `tests/photoBrowserViewModelTests.swift` — browser index, selection, deletion, request identity coverage.
- `tests/duplicateCompareViewModelTests.swift` — duplicate state machine coverage including two-photo left/right boundary.
- `tests/photoImageServiceTests.swift` — mockable image cache/service behavior coverage.
- `tests/metalPhotoViewStateTests.swift` — display state and zoom-state behavior coverage without real Metal rendering.

### Modified files

- `rawViewer/startViewController.swift` — replace ugly plain button with dashed folder drop zone while preserving folder selection behavior.
- `rawViewer/mainWindowController.swift` — inject ViewModels/services and wire back callbacks.
- `rawViewer/groupGridViewController.swift` — use `groupGridViewModel`, adaptive columns, back button, async group previews.
- `rawViewer/groupCardView.swift` — accept preview photos and show real JPG thumbnails instead of gray blocks.
- `rawViewer/photoThumbnailView.swift` — show real JPG thumbnails and bind selection/check state from ViewModel.
- `rawViewer/photoBrowserViewController.swift` — bind `photoBrowserViewModel`, preload display pair, clear old image before switching.
- `rawViewer/duplicateCompareViewController.swift` — bind `duplicateCompareViewModel`, finish on two-photo left/right decisions.
- `rawViewer/metalPhotoView.swift` — add `setImage`, `clearImage`, `showError`, explicit clear, and display-only responsibilities.
- `rawViewer.xcodeproj/project.pbxproj` — add new Swift source files to the `rawViewer` target if Xcode does not auto-include them.

---

## Task 1: Add navigation and group ViewModels

**Goal:** Screen navigation and group grid decisions are represented by testable ViewModels, including back rules and responsive column calculation.

**Files touched:**

- `rawViewer/appNavigationViewModel.swift` — screen state, current folder, records, groups, selected group, navigation methods.
- `rawViewer/groupGridViewModel.swift` — group filtering, route, preview photos, column count.
- `tests/appNavigationViewModelTests.swift` — validates navigation transitions.
- `tests/groupGridViewModelTests.swift` — validates group behavior and adaptive columns.
- `rawViewer.xcodeproj/project.pbxproj` — include new source files if required.

---

### Step 1 — Implement

- [ ] Create `appNavigationViewModel.swift` with file header.
- [ ] Create `groupGridViewModel.swift` with file header.
- [ ] Keep all type names in lower camel case to match project style.

#### `appNavigationViewModel.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: navigation ViewModel)

import Foundation

public final class appNavigationViewModel {
    public private(set) var screenState: windowScreenState = .start
    public private(set) var records: [photoItem] = []
    public private(set) var groups: [photoGroup] = []
    public private(set) var selectedGroup: photoGroup?
    public private(set) var currentFolderUrl: URL?

    public init() {}

    public func showStart() {
        screenState = .start
        selectedGroup = nil
        records = []
        groups = []
        currentFolderUrl = nil
    }

    public func startAnalysis(folderUrl: URL) {
        currentFolderUrl = folderUrl
        selectedGroup = nil
        screenState = .progress
    }

    public func showGroups(records newRecords: [photoItem]) {
        records = newRecords
        groups = makeVisiblePhotoGroups(from: newRecords)
        selectedGroup = nil
        screenState = .groups
    }

    public func openGroup(_ group: photoGroup) {
        selectedGroup = group
        screenState = group.kind.isDuplicate ? .duplicateCompare : .browser
    }

    public func backToStart() {
        showStart()
    }

    public func backToGroups() {
        selectedGroup = nil
        if records.isEmpty {
            screenState = .start
            groups = []
            return
        }
        groups = makeVisiblePhotoGroups(from: records)
        screenState = .groups
    }

    public func showError(message: String) {
        screenState = .error(message)
    }
}
```

#### `groupGridViewModel.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: group grid ViewModel)

import AppKit

public final class groupGridViewModel {
    public private(set) var groups: [photoGroup]
    public let minimumCardWidth: CGFloat
    public let maximumCardWidth: CGFloat
    public let columnSpacing: CGFloat
    public let horizontalPadding: CGFloat

    public init(
        groups: [photoGroup],
        minimumCardWidth: CGFloat = 200,
        maximumCardWidth: CGFloat = 320,
        columnSpacing: CGFloat = 16,
        horizontalPadding: CGFloat = 32
    ) {
        self.groups = visibleGroupCards(from: groups)
        self.minimumCardWidth = minimumCardWidth
        self.maximumCardWidth = maximumCardWidth
        self.columnSpacing = columnSpacing
        self.horizontalPadding = horizontalPadding
    }

    public convenience init(records: [photoItem]) {
        self.init(groups: makeVisiblePhotoGroups(from: records))
    }

    public func columnCount(for availableWidth: CGFloat) -> Int {
        let contentWidth = max(0, availableWidth - horizontalPadding)
        let candidateWidth = minimumCardWidth + columnSpacing
        if contentWidth <= minimumCardWidth { return 1 }
        let rawCount = Int((contentWidth + columnSpacing) / candidateWidth)
        return max(1, rawCount)
    }

    public func previewPhotos(for group: photoGroup) -> [photoItem] {
        Array(group.photos.prefix(3))
    }

    public func route(for group: photoGroup) -> groupRoute {
        group.kind.isDuplicate ? .duplicateCompare : .browser
    }

    public func update(groups newGroups: [photoGroup]) {
        groups = visibleGroupCards(from: newGroups)
    }
}
```

### Step 2 — Write tests based on the plan goal

- [ ] Add script tests mirroring the current `tests/*.swift` style.
- [ ] Tests must define minimal model copies needed to run standalone.

#### `tests/appNavigationViewModelTests.swift` pseudocode

```swift
import Foundation

define minimal reviewStatus, photoItem, photoGroupKind, photoGroup, windowScreenState
implement minimal makeVisiblePhotoGroups
copy appNavigationViewModel logic

create folder URL /tmp/rawViewerTest
create two photoItem records, one normal and one duplicate

assert initial state is .start
call startAnalysis(folderUrl)
assert state .progress
assert currentFolderUrl equals folder
call showGroups(records)
assert state .groups
assert records count 2
assert groups not empty
open first non duplicate group
assert state .browser
call backToGroups()
assert state .groups
open duplicate group
assert state .duplicateCompare
call backToStart()
assert state .start
assert records empty
assert groups empty

create fresh viewModel
call backToGroups with no records
assert state .start

print success line
```

#### `tests/groupGridViewModelTests.swift` pseudocode

```swift
import Foundation
import CoreGraphics

define minimal photoItem, photoGroupKind, photoGroup, groupRoute
implement visibleGroupCards and makeVisiblePhotoGroups if needed
copy groupGridViewModel logic without AppKit dependency by using CGFloat from CoreGraphics

create empty group and nonempty group
assert empty group filtered
assert nonempty group retained
assert normal route is browser
assert duplicate route is duplicateCompare
create group with five photos
assert previewPhotos returns exactly first three photo ids
assert columnCount(width: 100) equals 1
assert columnCount(width: 460) is at least 2
assert columnCount(width: 900) is greater than columnCount(width: 460)

print success line
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/appNavigationViewModelTests.swift
swift tests/groupGridViewModelTests.swift
```

Expected output:

```plain
All appNavigationViewModel tests passed!
All groupGridViewModel tests passed!
```

✅ **Done when:** Both new test scripts print their success lines and existing app still builds after adding files to the Xcode target.

---

## Task 2: Add photo image cache and service

**Goal:** All JPG, RAW, thumbnail, and display-pair loading is centralized behind a cache-backed service with explicit unavailable states.

**Files touched:**

- `rawViewer/photoImageCache.swift` — cache key, wrapper, get/set/remove methods.
- `rawViewer/photoImageService.swift` — image loading, thumbnail generation, RAW fallback state, display pair preloading.
- `tests/photoImageServiceTests.swift` — validates cache and service behavior with mock load results.
- `rawViewer.xcodeproj/project.pbxproj` — include new source files if required.

---

### Step 1 — Implement

- [ ] Use `NSCache<NSString, photoCachedImage>` because `NSCache` requires class objects.
- [ ] Use `CIImage` for display images to match `metalPhotoView`.
- [ ] For thumbnails, generate a transformed `CIImage` with target extent no larger than requested size.
- [ ] RAW loading returns unavailable when `rawPath` is missing.

#### `photoImageCache.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: cache for photo images)

import AppKit
import CoreImage

public enum photoImageKind: Hashable {
    case thumbnail(width: Int, height: Int)
    case displayJpg
    case displayRaw
}

public final class photoCachedImage {
    public let image: CIImage
    public init(image: CIImage) { self.image = image }
}

public struct photoImageCacheKey: Hashable {
    public let photoId: String
    public let kind: photoImageKind

    public var rawValue: String {
        switch kind {
        case .thumbnail(let width, let height): return "\(photoId)|thumbnail|\(width)x\(height)"
        case .displayJpg: return "\(photoId)|displayJpg"
        case .displayRaw: return "\(photoId)|displayRaw"
        }
    }
}

public final class photoImageCache {
    private let cache = NSCache<NSString, photoCachedImage>()

    public init(countLimit: Int = 160) {
        cache.countLimit = countLimit
    }

    public func image(for key: photoImageCacheKey) -> CIImage? {
        cache.object(forKey: key.rawValue as NSString)?.image
    }

    public func setImage(_ image: CIImage, for key: photoImageCacheKey) {
        cache.setObject(photoCachedImage(image: image), forKey: key.rawValue as NSString)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}
```

#### `photoImageService.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: centralized JPG RAW and thumbnail loader)

import AppKit
import CoreImage

public enum photoImageResult: Equatable {
    case image(CIImage)
    case unavailable(String)

    public static func == (lhs, rhs) -> Bool {
        compare cases only because CIImage is not Equatable
    }
}

public struct photoDisplayPair {
    public let photoId: String
    public let jpg: photoImageResult
    public let raw: photoImageResult
}

public final class photoImageService {
    private let cache: photoImageCache
    private let fileManager: FileManager

    public init(cache: photoImageCache = photoImageCache(), fileManager: FileManager = .default) {
        self.cache = cache
        self.fileManager = fileManager
    }

    public func loadImage(for photo: photoItem, kind: photoImageKind) async -> photoImageResult {
        let key = photoImageCacheKey(photoId: photo.photoId, kind: kind)
        if let cached = cache.image(for: key) { return .image(cached) }

        let result: photoImageResult
        switch kind {
        case .thumbnail(let width, let height):
            result = loadJpgThumbnail(photo: photo, width: width, height: height)
        case .displayJpg:
            result = loadJpgDisplay(photo: photo)
        case .displayRaw:
            result = loadRawDisplay(photo: photo)
        }

        if case .image(let image) = result {
            cache.setImage(image, for: key)
        }
        return result
    }

    public func preloadDisplayPair(for photo: photoItem) async -> photoDisplayPair {
        async let jpgResult = loadImage(for: photo, kind: .displayJpg)
        async let rawResult = loadImage(for: photo, kind: .displayRaw)
        return await photoDisplayPair(photoId: photo.photoId, jpg: jpgResult, raw: rawResult)
    }

    private func loadJpgDisplay(photo: photoItem) -> photoImageResult {
        guard fileManager.fileExists(atPath: photo.jpgPath) else { return .unavailable("Missing JPG") }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: photo.jpgPath)) else { return .unavailable("Cannot decode JPG") }
        return .image(image)
    }

    private func loadRawDisplay(photo: photoItem) -> photoImageResult {
        guard let rawPath = photo.rawPath, !rawPath.isEmpty else { return .unavailable("RAW missing") }
        guard fileManager.fileExists(atPath: rawPath) else { return .unavailable("Missing RAW") }
        guard let filter = CIFilter(imageURL: URL(fileURLWithPath: rawPath), options: nil), let image = filter.outputImage else {
            return .unavailable("Cannot decode RAW")
        }
        return .image(image)
    }

    private func loadJpgThumbnail(photo: photoItem, width: Int, height: Int) -> photoImageResult {
        let display = loadJpgDisplay(photo: photo)
        guard case .image(let image) = display else { return display }
        let scale = min(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
        let safeScale = max(0.001, scale)
        let thumbnail = image.transformed(by: CGAffineTransform(scaleX: safeScale, y: safeScale))
        return .image(thumbnail)
    }
}
```

### Step 2 — Write tests based on the plan goal

#### `tests/photoImageServiceTests.swift` pseudocode

```swift
import Foundation
import CoreImage
import CoreGraphics

define minimal photoItem
copy photoImageKind, photoImageCacheKey, photoCachedImage, photoImageCache
create mockPhotoImageService that does not read disk:
  stores dictionary of key to photoImageResult
  records load count per key
  checks cache before returning stored result
  preloadDisplayPair calls displayJpg and displayRaw

create CIImage using CIImage(color: .red).cropped(to: CGRect(x:0,y:0,width:10,height:10))
create photo with jpg path and raw path

assert first JPG load returns image
assert second JPG load returns image and load count remains 1 due cache
assert RAW missing photo returns unavailable
assert preloadDisplayPair requests both jpg and raw exactly once
assert unavailable result is not cached as image

print success line
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/photoImageServiceTests.swift
```

Expected output:

```plain
All photoImageService tests passed!
```

✅ **Done when:** The service/cache test passes and the app builds with the new service files included.

---

## Task 3: Refactor metalPhotoView into a display-only view

**Goal:** `metalPhotoView` can clear old images, accept prepared `CIImage` values, show errors, and zoom without reading or decoding files.

**Files touched:**

- `rawViewer/metalPhotoView.swift` — add display state API and explicit clear behavior.
- `tests/metalPhotoViewStateTests.swift` — validates state transitions without Metal rendering.

---

### Step 1 — Implement

- [ ] Keep existing MetalKit drawing support.
- [ ] Add public state inspection only where tests need it, such as `hasImage` and `errorMessage`.
- [ ] Mark `loadPhoto(url:source:)` as compatibility wrapper or remove usages after later tasks. If kept, internally call service-style helpers only temporarily.
- [ ] Ensure drawing clears drawable even when `currentImage` is nil.

#### `metalPhotoView.swift` implementation logic pseudocode

```swift
keep existing imports AppKit, CoreImage, MetalKit
keep photoLoadError and photoSource only if current callers still require them during transition

public final class metalPhotoView: MTKView {
    private currentImage: CIImage?
    private(set) public var errorMessage: String?
    private(set) public var isShowingError: Bool = false
    private userZoom = 1.0

    public var hasImage: Bool { currentImage != nil }
    public var currentZoom: Double { userZoom }

    public func setImage(_ image: CIImage?) {
        currentImage = image
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func clearImage() {
        currentImage = nil
        errorMessage = nil
        isShowingError = false
        needsDisplay = true
    }

    public func showError(_ message: String) {
        currentImage = nil
        errorMessage = message
        isShowingError = true
        needsDisplay = true
    }

    public func zoomIn() {
        userZoom = clamped(userZoom * 1.2)
        needsDisplay = true
    }

    public func zoomOut() {
        userZoom = clamped(userZoom / 1.2)
        needsDisplay = true
    }

    public func resetZoom() {
        userZoom = 1.0
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        acquire drawable and command buffer
        create full target bounds
        explicitly clear target with transparent or black background before rendering image
        if currentImage exists:
            compute fitScale = min(targetWidth/imageWidth, targetHeight/imageHeight)
            compute effectiveScale = fitScale * userZoom
            compute centered x and y
            render transformed CIImage to target
        present and commit
    }
}
```

Important rendering note:

```plain
The old bug is caused by not clearing old content. The implementation must render a clear background every draw cycle before rendering the current image. If no image exists, the cleared drawable must still be presented so stale pixels disappear.
```

### Step 2 — Write tests based on the plan goal

#### `tests/metalPhotoViewStateTests.swift` pseudocode

```swift
import Foundation
import CoreImage
import CoreGraphics

create lightweight metalPhotoViewState class with same state API:
  setImage
  clearImage
  showError
  zoomIn
  zoomOut
  resetZoom
  hasImage
  currentZoom
  errorMessage

create CIImage fixture
call setImage
assert hasImage true
assert error nil
call showError
assert hasImage false
assert error message matches
call setImage again
assert error cleared
call zoomIn
assert hasImage still true
assert zoom changed
call clearImage
assert hasImage false
assert zoom remains current zoom or reset only if implementation explicitly resets zoom
call resetZoom
assert zoom equals 1.0

print success line
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/metalPhotoViewStateTests.swift
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

Expected output:

```plain
All metalPhotoView state tests passed!
** BUILD SUCCEEDED **
```

✅ **Done when:** The state test passes and Xcode build succeeds.

---

## Task 4: Wire start page, groups page, real group previews, adaptive columns, and group back button

**Goal:** The start page uses the designed dashed folder selection area, group cards show real JPG previews, group columns adapt to window width, and groups can return to start.

**Files touched:**

- `rawViewer/startViewController.swift` — custom drop zone.
- `rawViewer/groupGridViewController.swift` — ViewModel-backed adaptive grid and back button.
- `rawViewer/groupCardView.swift` — async JPG previews.
- `rawViewer/mainWindowController.swift` — wire groups `onBack`.
- `tests/groupGridViewModelTests.swift` — already covers column and preview logic; extend if gaps appear.

---

### Step 1 — Implement

#### Start page pseudocode

```swift
startViewController.loadView:
    create root NSView with window background
    create folderDropZoneView or NSView subclass
    drop zone:
        wantsLayer true
        dashed border using CAShapeLayer or custom draw
        corner radius 12
        plus label font size 48
        text label with two lines
        click gesture target chooseFolder
    center drop zone in root
    constraints:
        width >= 420
        height >= 230
        width <= 760
        height <= 300
```

#### Group grid pseudocode

```swift
groupGridViewController:
    store viewModel instead of raw groups array
    add public onBack closure
    root view contains vertical stack:
        toolbar height around existing toolbar height
        back button on left
        scroll view below
    on back button click:
        onBack?()

    buildGrid():
        remove old grid/container
        let columns = viewModel.columnCount(for: view.bounds.width)
        create NSGridView rows with exactly columns items per full row
        for each group:
            card = groupCardView(group: group, previewPhotos: viewModel.previewPhotos(for: group), imageService: sharedImageService)
            card.onTap = onSelectGroup
        pad last row with empty NSView if needed
        install grid in scroll documentView

    viewDidLayout:
        if calculated columns changed:
            rebuild grid
```

#### Group card pseudocode

```swift
groupCardView init accepts group, previewPhotos, imageService
for each preview photo up to three:
    create NSImageView or layer-backed view
    configure imageScaling to scaleProportionallyUpOrDown
    apply rotation and offset constraints as current design does
    start Task:
        result = await imageService.loadImage(for: photo, kind: .thumbnail(width: 160, height: 110))
        on MainActor:
            if image result:
                convert CIImage to NSImage using NSCIImageRep
                set imageView.image
            if unavailable:
                keep fallback background
```

#### Main window pseudocode

```swift
mainWindowController.showGroups(records):
    navigationViewModel.showGroups(records)
    let imageService = shared service
    let controller = groupGridViewController(viewModel: groupGridViewModel(groups: navigationViewModel.groups), imageService: imageService)
    controller.onBack = { self.showStart through navigation model }
    controller.onSelectGroup = { self.showGroup(group) }
    set contentViewController
```

### Step 2 — Write tests based on the plan goal

- [ ] Extend `tests/groupGridViewModelTests.swift` to assert preview photos are first three and column count changes with width.
- [ ] UI visual details are verified manually in Task 7 because script tests cannot inspect AppKit rendering reliably.

Additional group ViewModel test pseudocode:

```swift
create five-photo group
assert previewPhotos ids are 0,1,2
assert previewPhotos count 3
let narrow = columnCount(250)
let wide = columnCount(1000)
assert narrow == 1
assert wide > narrow
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/groupGridViewModelTests.swift
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

Expected output:

```plain
All groupGridViewModel tests passed!
** BUILD SUCCEEDED **
```

✅ **Done when:** Group ViewModel tests pass, build succeeds, and manual launch shows dashed start zone, real group previews when JPG paths exist, adaptive columns, and groups back button.

---

## Task 5: Wire browser ViewModel, real sidebar thumbnails, source preloading, no-stale-image switching, and browser back button

**Goal:** Normal browser state is ViewModel-driven, sidebar items show real JPG thumbnails, switching photos clears stale images, JPG/RAW display pair is preloaded, and browser can return to groups.

**Files touched:**

- `rawViewer/photoBrowserViewModel.swift` — new browser state model.
- `rawViewer/photoBrowserViewController.swift` — bind ViewModel and image service.
- `rawViewer/photoThumbnailView.swift` — real thumbnail image views and state binding.
- `rawViewer/mainWindowController.swift` — wire browser `onBack`.
- `tests/photoBrowserViewModelTests.swift` — browser state coverage.

---

### Step 1 — Implement

#### `photoBrowserViewModel.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: browser ViewModel)

import Foundation

public final class photoBrowserViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var currentIndex: Int = 0
    public private(set) var checkedPhotoIds: Set<String> = []
    public private(set) var displaySource: displaySource
    public private(set) var currentRequestId: Int = 0
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring, displaySource: displaySource = .jpg) {
        self.photos = photos
        self.store = store
        self.displaySource = displaySource
    }

    public var currentPhoto: photoItem? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    public func movePrevious() {
        currentIndex = max(0, currentIndex - 1)
        currentRequestId += 1
    }

    public func moveNext() {
        currentIndex = min(max(photos.count - 1, 0), currentIndex + 1)
        currentRequestId += 1
    }

    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        currentRequestId += 1
    }

    public func setDisplaySource(_ source: displaySource) {
        displaySource = source
        currentRequestId += 1
    }

    public func isCurrentRequest(_ requestId: Int, photoId: String) -> Bool {
        currentRequestId == requestId && currentPhoto?.photoId == photoId
    }

    public func toggleCheck(photoId: String, isChecked: Bool) {
        if isChecked { checkedPhotoIds.insert(photoId) } else { checkedPhotoIds.remove(photoId) }
    }

    public func toggleAll(isChecked: Bool) {
        checkedPhotoIds = isChecked ? Set(photos.map(\.photoId)) : []
    }

    public func deleteTargets() -> [photoItem] {
        if checkedPhotoIds.isEmpty { return currentPhoto.map { [$0] } ?? [] }
        return photos.filter { checkedPhotoIds.contains($0.photoId) }
    }

    public func confirmDelete() throws {
        let targets = deleteTargets()
        for photo in targets { try store.mark(photoId: photo.photoId, status: .trashed) }
        let ids = Set(targets.map(\.photoId))
        photos.removeAll { ids.contains($0.photoId) }
        checkedPhotoIds.subtract(ids)
        currentIndex = min(currentIndex, max(photos.count - 1, 0))
        currentRequestId += 1
    }
}
```

#### Browser controller pseudocode

```swift
photoBrowserViewController:
    init(viewModel, imageService)
    keep onBack closure
    toolbar includes back button on left without changing overall toolbar layout meaning
    thumbnailView configured with photos and imageService
    sourceControl uses viewModel.displaySource

loadCurrentPhoto():
    guard current photo exists else:
        mainPhotoView.clearImage()
        return
    let requestId = viewModel.currentRequestId
    let photoId = photo.photoId
    mainPhotoView.clearImage()
    Task:
        pair = await imageService.preloadDisplayPair(for: photo)
        MainActor:
            guard viewModel.isCurrentRequest(requestId, photoId: photoId) else { return }
            show selected result from pair

show selected result:
    if source jpg and pair.jpg image: mainPhotoView.setImage(image)
    if source raw and pair.raw image: mainPhotoView.setImage(image)
    if selected unavailable and jpg image exists: mainPhotoView.setImage(jpg) and disable raw
    if both unavailable: mainPhotoView.showError("No image available")

keyDown:
    down: viewModel.moveNext(); thumbnailView.setCurrentIndex; loadCurrentPhoto()
    up: viewModel.movePrevious(); thumbnailView.setCurrentIndex; loadCurrentPhoto()
    backspace: deleteClicked()
    zoom keys: pass to mainPhotoView
```

#### Thumbnail view pseudocode

```swift
photoThumbnailView init accepts photos and optional imageService
create thumbnail item:
    container with border and background
    imageView fills container
    checkbox overlays top-left
    Task load thumbnail width 150 height 56
    on success set imageView.image
    on failure keep background
updatePhotos:
    replace photos
    preserve checkedIds intersection with new photos
    reload thumbnails
```

### Step 2 — Write tests based on the plan goal

#### `tests/photoBrowserViewModelTests.swift` pseudocode

```swift
import Foundation

define minimal photoItem, reviewStatus, jsonReviewStateStoring, mockStore, displaySource
copy photoBrowserViewModel logic

create three photos
assert current is first
moveNext assert second
movePrevious assert first
movePrevious at first remains first
setCurrentIndex 2 assert third
setCurrentIndex invalid keeps third
record requestId
setDisplaySource raw assert requestId increments
assert isCurrentRequest false for old id

toggle photo 1 on assert checked contains 1
toggle photo 1 off assert checked empty
toggleAll true assert checked count 3
toggleAll false assert checked empty

with no checked assert deleteTargets returns current
with checked 1 and 2 assert deleteTargets returns those two
confirmDelete assert store marked ids trashed
assert photos removed
assert currentIndex valid

print success line
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/photoBrowserViewModelTests.swift
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

Expected output:

```plain
All photoBrowserViewModel tests passed!
** BUILD SUCCEEDED **
```

✅ **Done when:** Browser ViewModel tests pass, build succeeds, manual browser page shows real left thumbnails, back button returns groups, fast up/down never displays old image as current image, and RAW/JPG switch uses preloaded results when available.

---

## Task 6: Wire duplicate ViewModel and two-photo boundary finish behavior

**Goal:** Duplicate compare behavior is ViewModel-driven and two-photo groups finish correctly for both left and right arrow choices.

**Files touched:**

- `rawViewer/duplicateCompareViewModel.swift` — new duplicate state model.
- `rawViewer/duplicateCompareViewController.swift` — bind ViewModel, image service, and finish callback.
- `rawViewer/mainWindowController.swift` — wire duplicate `onFinished` and `onBack` to groups.
- `tests/duplicateCompareViewModelTests.swift` — duplicate state machine coverage.

---

### Step 1 — Implement

#### `duplicateCompareViewModel.swift` pseudocode

```swift
fileHeader(author: wilbur, version: 1.0, date: 2026-06-03, description: duplicate compare ViewModel)

import Foundation

public enum duplicateCompareActionResult: Equatable {
    case continueComparing
    case finished
}

public final class duplicateCompareViewModel {
    public private(set) var photos: [photoItem]
    public private(set) var mainIndex: Int = 0
    public private(set) var candidateIndex: Int = 1
    private let store: jsonReviewStateStoring

    public init(photos: [photoItem], store: jsonReviewStateStoring) {
        self.photos = photos
        self.store = store
    }

    public var mainPhoto: photoItem? { photos.indices.contains(mainIndex) ? photos[mainIndex] : nil }
    public var candidatePhoto: photoItem? { photos.indices.contains(candidateIndex) ? photos[candidateIndex] : nil }

    public func keepLeft() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try store.mark(photoId: right.photoId, status: .trashed)
        photos.removeAll { $0.photoId == right.photoId }
        if photos.count == 1 {
            try markFinalKept(left)
            return .finished
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepRight() throws -> duplicateCompareActionResult {
        guard let left = mainPhoto else { return .finished }
        guard let right = candidatePhoto else {
            try markFinalKept(left)
            return .finished
        }
        try store.mark(photoId: left.photoId, status: .trashed)
        photos.removeAll { $0.photoId == left.photoId }
        if photos.count == 1 {
            try markFinalKept(right)
            return .finished
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }

    public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
        if let left = mainPhoto { try store.mark(photoId: left.photoId, status: .kept) }
        if let right = candidatePhoto { try store.mark(photoId: right.photoId, status: .kept) }
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
        return .finished
    }

    private func markFinalKept(_ photo: photoItem) throws {
        try store.mark(photoId: photo.photoId, status: .kept)
        if !photo.reviewGroupId.isEmpty {
            try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
        }
    }
}
```

#### Duplicate controller pseudocode

```swift
duplicateCompareViewController:
    init(viewModel, imageService)
    expose onBack and onFinished
    toolbar includes back button and existing actions

loadPhotos():
    clear left and right views
    for each visible photo:
        Task preloadDisplayPair
        show selected source when request still matches current photo id

keyDown left:
    result = try viewModel.keepLeft()
    handle result
keyDown right:
    result = try viewModel.keepRight()
    handle result

handle result:
    if finished: onFinished?()
    if continueComparing: loadPhotos()
```

### Step 2 — Write tests based on the plan goal

#### `tests/duplicateCompareViewModelTests.swift` pseudocode

```swift
import Foundation

define minimal reviewStatus, photoItem, jsonReviewStateStoring, mockStore
copy duplicateCompareActionResult and duplicateCompareViewModel logic

create two photos in group G1
call keepLeft
assert result finished
assert store contains right trashed
assert store contains left kept
assert template G1 left

create two photos again
call keepRight
assert result finished
assert store contains left trashed
assert store contains right kept
assert template G1 right

create three photos
call keepLeft
assert result continueComparing
assert only candidate trashed
assert photos count 2

create two photos
call keepBoth(template right)
assert result finished
assert both kept
assert template right

create one photo
call keepLeft
assert result finished
assert single kept
assert template single

print success line
```

### Step 3 — Run tests and confirm all pass

```bash
swift tests/duplicateCompareViewModelTests.swift
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

Expected output:

```plain
All duplicateCompareViewModel tests passed!
** BUILD SUCCEEDED **
```

✅ **Done when:** Duplicate ViewModel tests pass, build succeeds, and manual duplicate groups with exactly two photos allow both left and right choices and return to groups after the decision.

---

## Task 7: Full integration regression and manual verification

**Goal:** The complete App fixes all nine reported bugs without changing the user-visible layout.

**Files touched:**

- No new implementation files expected.
- Existing files may receive small integration fixes discovered during regression.
- `docs/flare/20260603_raw_viewer_bug_fix.md` — update checked boxes only if executing inline.

---

### Step 1 — Implement

- [ ] Run all script tests.
- [ ] Run Xcode build.
- [ ] Launch the App manually from Xcode or build output.
- [ ] Verify the manual checklist below.
- [ ] Fix only defects directly tied to this plan.

Manual verification checklist:

```plain
1. 首页显示中央虚线文件夹选择区域。
2. 点击首页选择文件夹仍可打开 NSOpenPanel。
3. 选择文件夹后分组页出现。
4. 分组卡片显示真实 JPG 叠放预览。
5. 分组每行数量随窗口宽度变化。
6. 分组页返回按钮回到首页。
7. 普通分组页左侧显示真实 JPG 缩略图。
8. 普通分组页返回按钮回到分组页。
9. 快速按上下键切换图片，不出现旧图叠加。
10. JPG/RAW 切换不再现场慢读，缓存命中时基本即时。
11. 缩放不触发文件重新读取和明显闪烁。
12. duplicate 页返回按钮回到分组页。
13. duplicate 分组只有两张照片时，左键和右键都能完成选择并返回分组页。
14. RAW 不存在或解码失败时 UI 不崩溃。
```

### Step 2 — Write tests based on the plan goal

- [ ] This task does not add a new unit test file unless a regression is found.
- [ ] If a regression is found, add the smallest script test that fails before the fix and passes after the fix.

Regression test decision pseudocode:

```plain
if failure is ViewModel logic:
    add assertion to the relevant ViewModel test file
if failure is image service cache logic:
    add assertion to photoImageServiceTests.swift
if failure is metal display state:
    add assertion to metalPhotoViewStateTests.swift
if failure is pure AppKit visual wiring:
    document in manual checklist result because script tests cannot reliably inspect rendered AppKit hierarchy
```

### Step 3 — Run tests and confirm all pass

```bash
for f in tests/*Tests.swift; do echo "== $f =="; swift "$f" || exit 1; done
xcodebuild -project rawViewer.xcodeproj -scheme rawViewer -configuration Debug -destination 'platform=macOS' build
```

Expected output:

```plain
== tests/appNavigationViewModelTests.swift ==
All appNavigationViewModel tests passed!
== tests/duplicateCompareViewModelTests.swift ==
All duplicateCompareViewModel tests passed!
== tests/groupGridViewModelTests.swift ==
All groupGridViewModel tests passed!
== tests/metalPhotoViewStateTests.swift ==
All metalPhotoView state tests passed!
== tests/photoBrowserViewModelTests.swift ==
All photoBrowserViewModel tests passed!
== tests/photoImageServiceTests.swift ==
All photoImageService tests passed!
** BUILD SUCCEEDED **
```

✅ **Done when:** All script tests pass, Xcode build succeeds, and the manual verification checklist passes without changing the visible App layout.

---

## Self-Review

### 1. Spec coverage

- 首页样式 bug: Task 4.
- 分组真实图片: Task 2 and Task 4.
- 分组自适应列: Task 1 and Task 4.
- 三处返回按钮: Task 1, Task 4, Task 5, Task 6.
- 普通浏览左侧预览: Task 2 and Task 5.
- 上下键叠图: Task 3 and Task 5.
- RAW/JPG 切换延迟: Task 2 and Task 5.
- 缩放刷新体感: Task 3.
- duplicate 两张边界: Task 6.
- Full regression: Task 7.

### 2. Placeholder scan

The plan contains concrete files, goals, pseudocode logic, tests, and commands. It intentionally uses pseudocode blocks because the requested planning output asked for implementation logic explanations. The implementing agent must translate each pseudocode block into Swift while preserving the described signatures and behavior.

### 3. Type consistency

- `groupGridViewModel` uses `columnCount`, `previewPhotos`, and `route` consistently.
- `photoBrowserViewModel` uses `currentRequestId` and `isCurrentRequest` consistently.
- `duplicateCompareViewModel` uses `duplicateCompareActionResult` consistently.
- `photoImageService` and `photoImageCache` share `photoImageKind` and `photoImageCacheKey`.
- `metalPhotoView` exposes `setImage`, `clearImage`, and `showError` for controller integration.

### 4. Test completeness

Each task has a runnable verification command. State-heavy work has standalone Swift script tests. AppKit-rendering details are covered by build plus manual checklist because script tests cannot reliably inspect the rendered macOS UI.

---

## Execution Handoff

Plan complete and saved to `docs/flare/20260603_raw_viewer_bug_fix.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
