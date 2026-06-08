# 重复分组逻辑修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复重复分组中两张照片的处理 bug：1) 单张 orphan 照片不应显示为 duplicate 分组；2) keepBoth 应正确处理组内剩余照片。

**Architecture:** 纯 Swift 侧修改，不涉及 C++ 后端。Task 1 修复 `photoModels.swift` 的表现层过滤逻辑；Task 2 修复 `duplicateCompareViewModel.swift` 的 keepBoth 交互逻辑。两个 Task 有数据依赖（Task 2 的 continueComparing 路径需要 Task 1 的过滤来正确展示剩余分组），按顺序执行。

**Tech Stack:** Swift, AppKit, XCTest, xcodebuild

---

## 文件结构

| 文件 | 职责 | 操作 |
|------|------|------|
| `rawViewer/photoModels.swift` | 分组模型与可见分组构建逻辑 | 编辑 `makeVisiblePhotoGroups` |
| `rawViewer/duplicateCompareViewModel.swift` | 重复照片比较 ViewModel | 编辑 `keepBoth` |
| `rawViewerTests/photoModelsTests.swift` | 验证 `makeVisiblePhotoGroups` 的分组过滤与 orphan 归入 | 新建 |
| `rawViewerTests/duplicateCompareViewModelTests.swift` | 验证 `keepBoth` 的三种剩余数量分支 | 新建 |

**注意**：`rawViewerTests/` 目录当前不存在，需要创建。测试文件创建后，需通过 Xcode 将文件添加到 `rawViewerTests` target（或修改 `rawViewer.xcodeproj/project.pbxproj` 添加文件引用）。

---

## Task 1: 修复 `makeVisiblePhotoGroups` 的单张 duplicate 过滤

**Goal:** `makeVisiblePhotoGroups` 构建分组时，仅当 `reviewGroupId` 下可见照片数量 >= 2 时才创建 `.duplicate` 分组；单张 orphan 照片按自身 blur/exposure 属性归入常规分组。

**Files touched:**

- `rawViewer/photoModels.swift` — 修改 `makeVisiblePhotoGroups` 函数
- `rawViewerTests/photoModelsTests.swift` — 新建测试文件

---

#### Step 1 — Implement

重写 `makeVisiblePhotoGroups`，增加 `validDuplicateIds` 计算，修改常规分组的过滤条件。

```swift
// rawViewer/photoModels.swift
// 只修改 makeVisiblePhotoGroups 函数，其余代码保持不变

public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    // 统计每个 reviewGroupId 的可见照片数量，只有 >= 2 的才是有效重复组
    let groupCounts = Dictionary(grouping: visiblePhotos, by: \.reviewGroupId)
        .filter { !$0.key.isEmpty }
        .mapValues { $0.count }
    let validDuplicateIds = Set(groupCounts.filter { $0.value >= 2 }.keys)

    func isInValidDuplicateGroup(_ photo: photoItem) -> Bool {
        !photo.reviewGroupId.isEmpty && validDuplicateIds.contains(photo.reviewGroupId)
    }

    appendGroup(.overexposed, photos: visiblePhotos.filter {
        $0.exposureStatus == "overexposed" && !isInValidDuplicateGroup($0)
    }, into: &groups)

    appendGroup(.underexposed, photos: visiblePhotos.filter {
        $0.exposureStatus == "underexposed" && !isInValidDuplicateGroup($0)
    }, into: &groups)

    appendGroup(.blurry, photos: visiblePhotos.filter {
        $0.isBlurry && !isInValidDuplicateGroup($0)
    }, into: &groups)

    appendGroup(.normal, photos: visiblePhotos.filter {
        !$0.isBlurry && $0.exposureStatus == "normal" && !isInValidDuplicateGroup($0)
    }, into: &groups)

    for reviewGroupId in validDuplicateIds.sorted() {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}
```

其余代码（`appendGroup`、`displaySourceStore`、`displayUrl` 等）完全保持不变。

---

#### Step 2 — Write tests

```swift
// rawViewerTests/photoModelsTests.swift

import XCTest
@testable import rawViewer

final class photoModelsTests: XCTestCase {

    // MARK: - Helpers

    private func makePhoto(
        photoId: String,
        exposureStatus: String = "normal",
        isBlurry: Bool = false,
        reviewStatus: reviewStatus = .active,
        reviewGroupId: String = ""
    ) -> photoItem {
        photoItem(
            photoId: photoId,
            jpgPath: "/tmp/\(photoId).jpg",
            rawPath: nil,
            isBlurry: isBlurry,
            exposureStatus: exposureStatus,
            reviewStatus: reviewStatus,
            reviewGroupId: reviewGroupId,
            templatePhotoId: ""
        )
    }

    // MARK: - Single orphan should not create duplicate group

    func test_singleOrphanGoesToNormal() {
        let photos = [
            makePhoto(photoId: "A", reviewGroupId: "dup_001"),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .normal)
        XCTAssertEqual(groups[0].photos.count, 1)
        XCTAssertEqual(groups[0].photos[0].photoId, "A")
    }

    func test_singleOrphanGoesToBlurry() {
        let photos = [
            makePhoto(photoId: "A", isBlurry: true, reviewGroupId: "dup_001"),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .blurry)
    }

    func test_singleOrphanGoesToOverexposed() {
        let photos = [
            makePhoto(photoId: "A", exposureStatus: "overexposed", reviewGroupId: "dup_001"),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .overexposed)
    }

    // MARK: - Valid duplicate group (>= 2 photos)

    func test_twoPhotosCreateDuplicateGroup() {
        let photos = [
            makePhoto(photoId: "A", reviewGroupId: "dup_001"),
            makePhoto(photoId: "B", reviewGroupId: "dup_001"),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .duplicate(reviewGroupId: "dup_001"))
        XCTAssertEqual(groups[0].photos.count, 2)
    }

    // MARK: - Mixed: valid duplicate + orphan after filtering

    func test_afterFiltering_oneOrphanMovesToNormal() {
        let photos = [
            makePhoto(photoId: "A", reviewGroupId: "dup_001"),
            makePhoto(photoId: "B", reviewGroupId: "dup_001", reviewStatus: .trashed),
            makePhoto(photoId: "C", reviewGroupId: "dup_001", reviewStatus: .passed),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        // A 是单张 orphan，应归入 normal；不应有 duplicate 分组
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .normal)
        XCTAssertEqual(groups[0].photos[0].photoId, "A")
    }

    func test_afterFiltering_twoRemain_stillDuplicate() {
        let photos = [
            makePhoto(photoId: "A", reviewGroupId: "dup_001"),
            makePhoto(photoId: "B", reviewGroupId: "dup_001"),
            makePhoto(photoId: "C", reviewGroupId: "dup_001", reviewStatus: .trashed),
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .duplicate(reviewGroupId: "dup_001"))
        XCTAssertEqual(groups[0].photos.count, 2)
    }

    // MARK: - Multiple groups interaction

    func test_multipleDuplicateGroupsAndNormal() {
        let photos = [
            makePhoto(photoId: "N1"),                                    // normal
            makePhoto(photoId: "D1A", reviewGroupId: "dup_001"),        // dup group 1
            makePhoto(photoId: "D1B", reviewGroupId: "dup_001"),        // dup group 1
            makePhoto(photoId: "D2A", reviewGroupId: "dup_002"),        // orphan
            makePhoto(photoId: "D3A", isBlurry: true, reviewGroupId: "dup_003"), // dup group 3
            makePhoto(photoId: "D3B", isBlurry: true, reviewGroupId: "dup_003"), // dup group 3
        ]
        let groups = makeVisiblePhotoGroups(from: photos)

        XCTAssertEqual(groups.count, 4)

        let normalGroup = groups.first { $0.kind == .normal }
        XCTAssertNotNil(normalGroup)
        XCTAssertEqual(normalGroup?.photos.count, 1)
        XCTAssertEqual(normalGroup?.photos[0].photoId, "N1")

        let orphanGroup = groups.first { $0.photos.contains(where: { $0.photoId == "D2A" }) }
        XCTAssertNotNil(orphanGroup)
        XCTAssertEqual(orphanGroup?.kind, .normal)  // D2A 是 normal 属性

        let dup1 = groups.first { $0.kind == .duplicate(reviewGroupId: "dup_001") }
        XCTAssertNotNil(dup1)
        XCTAssertEqual(dup1?.photos.count, 2)

        let dup3 = groups.first { $0.kind == .duplicate(reviewGroupId: "dup_003") }
        XCTAssertNotNil(dup3)
        XCTAssertEqual(dup3?.photos.count, 2)
    }
}
```

---

#### Step 3 — Run tests and confirm all pass

```bash
# 1. 创建测试目录
mkdir -p rawViewerTests

# 2. 将测试文件放入目录后，通过 Xcode 添加到 rawViewerTests target：
#    - 在 Xcode 中右键 rawViewerTests → Add Files to "rawViewerTests"
#    - 选择 rawViewerTests/photoModelsTests.swift
#    - 确保勾选 "rawViewerTests" target

# 3. 运行测试
xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' 2>&1 | tail -30
```

**Expected output:**

```
Test Suite 'photoModelsTests' started at ...
Test Case '-[rawViewerTests.photoModelsTests test_singleOrphanGoesToNormal]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_singleOrphanGoesToBlurry]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_singleOrphanGoesToOverexposed]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_twoPhotosCreateDuplicateGroup]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_afterFiltering_oneOrphanMovesToNormal]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_afterFiltering_twoRemain_stillDuplicate]' passed (Xms)
Test Case '-[rawViewerTests.photoModelsTests test_multipleDuplicateGroupsAndNormal]' passed (Xms)
Test Suite 'photoModelsTests' passed at ...
	 Executed 7 tests, with 0 failures
```

✅ **Done when:** 7 个测试全部通过。

---

## Task 2: 修复 `keepBoth` 正确处理组内剩余照片

**Goal:** `keepBoth` 保留当前比较的两张照片并清空其 `reviewGroupId`，根据剩余照片数量：0 张返回 `.finished`；1 张自动 `markFinalKept` 后返回 `.finished`；>=2 张设置模板后更新索引并返回 `.continueComparing`。

**Files touched:**

- `rawViewer/duplicateCompareViewModel.swift` — 修改 `keepBoth` 方法
- `rawViewerTests/duplicateCompareViewModelTests.swift` — 新建测试文件

---

#### Step 1 — Implement

重写 `keepBoth`，增加 `photos.removeAll` 和 `switch photos.count` 分支。

```swift
// rawViewer/duplicateCompareViewModel.swift
// 只修改 keepBoth 方法，其余代码保持不变

public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
    if let left = mainPhoto {
        try store.mark(photoId: left.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: left.photoId)
    }
    if let right = candidatePhoto {
        try store.mark(photoId: right.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: right.photoId)
    }

    let keptIds = Set([mainPhoto, candidatePhoto].compactMap { $0?.photoId })
    photos.removeAll { keptIds.contains($0.photoId) }

    switch photos.count {
    case 0:
        return .finished
    case 1:
        if let last = photos.first {
            try markFinalKept(last)
        }
        return .finished
    default:
        if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
            try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
        }
        mainIndex = 0
        candidateIndex = min(1, photos.count - 1)
        return .continueComparing
    }
}
```

其余代码（`keepLeft`、`keepRight`、`markFinalKept`、属性声明等）完全保持不变。

---

#### Step 2 — Write tests

```swift
// rawViewerTests/duplicateCompareViewModelTests.swift

import XCTest
@testable import rawViewer

final class duplicateCompareViewModelTests: XCTestCase {

    // MARK: - Mock Store

    final class mockStore: jsonReviewStateStoring {
        var operations: [reviewOperation] = []
        var marks: [(photoId: String, status: reviewStatus)] = []
        var clearedIds: [String] = []
        var templates: [(groupId: String, templateId: String)] = []

        func mark(photoId: String, status: reviewStatus) throws {
            marks.append((photoId: photoId, status: status))
            operations.append(.status(photoId: photoId, status: status))
        }

        func setTemplate(reviewGroupId: String, templatePhotoId: String) throws {
            templates.append((groupId: reviewGroupId, templateId: templatePhotoId))
            operations.append(.template(reviewGroupId: reviewGroupId, templatePhotoId: templatePhotoId))
        }

        func clearReviewGroupId(photoId: String) throws {
            clearedIds.append(photoId)
        }
    }

    private func makePhoto(photoId: String, groupId: String = "dup_001") -> photoItem {
        photoItem(
            photoId: photoId,
            jpgPath: "/tmp/\(photoId).jpg",
            rawPath: nil,
            isBlurry: false,
            exposureStatus: "normal",
            reviewStatus: .active,
            reviewGroupId: groupId,
            templatePhotoId: ""
        )
    }

    // MARK: - keepBoth with exactly 2 photos

    func test_keepBoth_twoPhotos_returnsFinished() throws {
        let store = mockStore()
        let photos = [makePhoto(photoId: "A"), makePhoto(photoId: "B")]
        let vm = duplicateCompareViewModel(photos: photos, store: store)

        let result = try vm.keepBoth(templatePhotoId: "A")

        XCTAssertEqual(result, .finished)
        XCTAssertTrue(vm.photos.isEmpty)
        XCTAssertEqual(store.marks.count, 2)
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "A" && $0.status == .kept }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "B" && $0.status == .kept }))
        XCTAssertEqual(Set(store.clearedIds), Set(["A", "B"]))
        XCTAssertTrue(store.templates.isEmpty) // 剩余 0 张，不需要 setTemplate
    }

    // MARK: - keepBoth with 3 photos

    func test_keepBoth_threePhotos_autoFinishesLastOne() throws {
        let store = mockStore()
        let photos = [makePhoto(photoId: "A"), makePhoto(photoId: "B"), makePhoto(photoId: "C")]
        let vm = duplicateCompareViewModel(photos: photos, store: store)

        let result = try vm.keepBoth(templatePhotoId: "A")

        XCTAssertEqual(result, .finished)
        XCTAssertTrue(vm.photos.isEmpty)

        // A, B 被 keepBoth 标记
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "A" && $0.status == .kept }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "B" && $0.status == .kept }))

        // C 被自动 markFinalKept 标记
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "C" && $0.status == .kept }))

        // A, B, C 的 reviewGroupId 都被清空
        XCTAssertEqual(Set(store.clearedIds), Set(["A", "B", "C"]))

        // C 被设为自己的 template（markFinalKept 行为）
        XCTAssertTrue(store.templates.contains(where: { $0.groupId == "dup_001" && $0.templateId == "C" }))
    }

    // MARK: - keepBoth with 4 photos

    func test_keepBoth_fourPhotos_returnsContinueComparing() throws {
        let store = mockStore()
        let photos = [
            makePhoto(photoId: "A"), makePhoto(photoId: "B"),
            makePhoto(photoId: "C"), makePhoto(photoId: "D")
        ]
        let vm = duplicateCompareViewModel(photos: photos, store: store)

        let result = try vm.keepBoth(templatePhotoId: "A")

        XCTAssertEqual(result, .continueComparing)
        XCTAssertEqual(vm.photos.count, 2)
        XCTAssertEqual(vm.photos[0].photoId, "C")
        XCTAssertEqual(vm.photos[1].photoId, "D")
        XCTAssertEqual(vm.mainIndex, 0)
        XCTAssertEqual(vm.candidateIndex, 1)

        // A, B 被标记 kept 并清空 groupId
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "A" && $0.status == .kept }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "B" && $0.status == .kept }))
        XCTAssertTrue(store.clearedIds.contains("A"))
        XCTAssertTrue(store.clearedIds.contains("B"))

        // C, D 仍在组内，setTemplate 被调用
        XCTAssertTrue(store.templates.contains(where: { $0.groupId == "dup_001" && $0.templateId == "A" }))

        // C, D 没有被 mark/clear
        XCTAssertFalse(store.marks.contains(where: { $0.photoId == "C" }))
        XCTAssertFalse(store.marks.contains(where: { $0.photoId == "D" }))
        XCTAssertFalse(store.clearedIds.contains("C"))
        XCTAssertFalse(store.clearedIds.contains("D"))
    }

    // MARK: - keepBoth with 5 photos, then continue

    func test_keepBoth_fivePhotos_thenContinueComparing() throws {
        let store = mockStore()
        let photos = [
            makePhoto(photoId: "A"), makePhoto(photoId: "B"),
            makePhoto(photoId: "C"), makePhoto(photoId: "D"),
            makePhoto(photoId: "E")
        ]
        let vm = duplicateCompareViewModel(photos: photos, store: store)

        let result = try vm.keepBoth(templatePhotoId: "B")

        XCTAssertEqual(result, .continueComparing)
        XCTAssertEqual(vm.photos.count, 3)
        XCTAssertEqual(vm.photos.map(\.photoId), ["C", "D", "E"])
        XCTAssertEqual(vm.mainIndex, 0)
        XCTAssertEqual(vm.candidateIndex, 1)

        // A, B 被移出
        XCTAssertTrue(store.clearedIds.contains("A"))
        XCTAssertTrue(store.clearedIds.contains("B"))

        // C, D, E 仍在组内，模板设为 B
        XCTAssertTrue(store.templates.contains(where: { $0.groupId == "dup_001" && $0.templateId == "B" }))
    }

    // MARK: - Mixed: keepLeft twice then keepBoth

    func test_mixed_keepLeftThenKeepBoth_autoFinishes() throws {
        let store = mockStore()
        let photos = [
            makePhoto(photoId: "A"), makePhoto(photoId: "B"),
            makePhoto(photoId: "C"), makePhoto(photoId: "D"),
            makePhoto(photoId: "E")
        ]
        let vm = duplicateCompareViewModel(photos: photos, store: store)

        // 先淘汰 B
        _ = try vm.keepLeft()
        XCTAssertEqual(vm.photos.count, 4)
        XCTAssertEqual(vm.photos.map(\.photoId), ["A", "C", "D", "E"])

        // 再淘汰 C
        _ = try vm.keepLeft()
        XCTAssertEqual(vm.photos.count, 3)
        XCTAssertEqual(vm.photos.map(\.photoId), ["A", "D", "E"])

        // keepBoth 保留 A, D
        let result = try vm.keepBoth(templatePhotoId: "A")

        // 剩余 E 自动收尾
        XCTAssertEqual(result, .finished)
        XCTAssertTrue(vm.photos.isEmpty)

        // B, C 被 trashed
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "B" && $0.status == .trashed }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "C" && $0.status == .trashed }))

        // A, D, E 被 kept
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "A" && $0.status == .kept }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "D" && $0.status == .kept }))
        XCTAssertTrue(store.marks.contains(where: { $0.photoId == "E" && $0.status == .kept }))

        // 所有人的 groupId 都被清空
        XCTAssertEqual(Set(store.clearedIds), Set(["A", "D", "E"]))
    }
}
```

---

#### Step 3 — Run tests and confirm all pass

```bash
# 1. 将测试文件放入 rawViewerTests/ 目录后，通过 Xcode 添加到 rawViewerTests target

# 2. 运行测试
xcodebuild test -project rawViewer.xcodeproj -scheme rawViewer -destination 'platform=macOS' 2>&1 | tail -40
```

**Expected output:**

```
Test Suite 'duplicateCompareViewModelTests' started at ...
Test Case '-[rawViewerTests.duplicateCompareViewModelTests test_keepBoth_twoPhotos_returnsFinished]' passed (Xms)
Test Case '-[rawViewerTests.duplicateCompareViewModelTests test_keepBoth_threePhotos_autoFinishesLastOne]' passed (Xms)
Test Case '-[rawViewerTests.duplicateCompareViewModelTests test_keepBoth_fourPhotos_returnsContinueComparing]' passed (Xms)
Test Case '-[rawViewerTests.duplicateCompareViewModelTests test_keepBoth_fivePhotos_thenContinueComparing]' passed (Xms)
Test Case '-[rawViewerTests.duplicateCompareViewModelTests test_mixed_keepLeftThenKeepBoth_autoFinishes]' passed (Xms)
Test Suite 'duplicateCompareViewModelTests' passed at ...
	 Executed 5 tests, with 0 failures
```

✅ **Done when:** 5 个测试全部通过。

---

## Self-Review

**1. Spec coverage:**

- ✅ `makeVisiblePhotoGroups` 单张过滤 → Task 1
- ✅ 单张 orphan 归入常规分组（blur/overexposed/underexposed/normal） → Task 1 test
- ✅ `keepBoth` 剩余 0 张返回 `.finished` → Task 2 test
- ✅ `keepBoth` 剩余 1 张自动 `markFinalKept` → Task 2 test
- ✅ `keepBoth` 剩余 >= 2 张返回 `.continueComparing` + `setTemplate` → Task 2 test
- ✅ 混用 `keepLeft` + `keepBoth` → Task 2 test

**2. Placeholder scan:**

- ✅ 无 "TBD"/"TODO"
- ✅ 所有代码块完整，无省略号
- ✅ 测试代码包含完整 import、describe、assertion
- ✅ 无 "Similar to Task N" 引用

**3. Type consistency:**

- ✅ `reviewGroupId` 属性名一致
- ✅ `duplicateCompareActionResult` case 名一致（`.finished`, `.continueComparing`）
- ✅ `photoItem` 初始化参数顺序与现有代码一致
- ✅ `jsonReviewStateStoring` 协议方法签名一致

**4. Test completeness:**

- Task 1: 7 个测试覆盖单张 orphan（normal/blurry/overexposed）、有效 duplicate、过滤后 orphan、混合场景
- Task 2: 5 个测试覆盖 2/3/4/5 张 keepBoth、混用 keepLeft+keepBoth
- 每个 task 的 Done 条件明确：所有测试通过

---

## Execution Handoff

**Plan complete and saved to `docs/flare/20260608_duplicateGroupFix.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
