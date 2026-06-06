## 代码审核报告 — Plan4 Navigation + BUG 修复 + 集成

### 总览
- 审核文件：8 个（2 新建 + 6 修改/重写）
  - `jsonReviewStateStore.swift`（修改）
  - `duplicateCompareViewModel.swift`（修改）
  - `photoModels.swift`（修改）
  - `appCoordinator.swift`（新建）
  - `mainWindowController.swift`（重写）
  - `photoBrowserViewController.swift`（重写）
  - `duplicateCompareViewController.swift`（重写）
  - `metalPhotoView.swift`（精简）
- 发现问题：🔴 0 个 / 🟠 1 个 / 🟡 1 个 / 🔵 1 个
- 整体评价：appCoordinator 架构清晰，数据流闭环正确。核心 BUG4（Duplicate 完成后分组不消失）通过 clearReviewGroupId + reloadData 链路根治。主要问题在于 `keepBoth` 路径未清空 reviewGroupId。

---

### 问题清单

### 🟠 [High] keepBoth 未清空 reviewGroupId，"Keep both" 后分组仍不消失

**位置**: `duplicateCompareViewModel.swift` — `keepBoth(templatePhotoId:)`
**问题**: `markFinalKept` 已正确调用 `clearReviewGroupId`，但 `keepBoth` 路径没有。用户选择 "Keep both" 后，两张照片的 `reviewGroupId` 仍然非空，`makeVisiblePhotoGroups` 中 duplicate 分组仍然包含它们。onFinished → reloadData → showGroups 后，该 duplicate 分组仍然出现。

**修复方案**: 在 `keepBoth` 中为两张存活照片都调用 `clearReviewGroupId`：

```swift
public func keepBoth(templatePhotoId: String) throws -> duplicateCompareActionResult {
    if let left = mainPhoto { 
        try store.mark(photoId: left.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: left.photoId)
    }
    if let right = candidatePhoto { 
        try store.mark(photoId: right.photoId, status: .kept)
        try store.clearReviewGroupId(photoId: right.photoId)
    }
    if let groupId = mainPhoto?.reviewGroupId, !groupId.isEmpty {
        try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
    }
    return .finished
}
```

---

### 🟡 [Medium] appNavigationViewModel.swift 成为死代码

**位置**: `appNavigationViewModel.swift`
**问题**: `mainWindowController` 已不再使用 `appNavigationViewModel`，其全部职责转交给了 `appCoordinator`。该文件现在无任何引用。

**修复方案**: 当前不阻塞功能。后续清理时可直接删除该文件。

---

### 🔵 [Low] mainWindowController.screenState 不再随 coordinator 更新

**位置**: `mainWindowController.swift` — `screenState` 属性
**问题**: 新的 `mainWindowController` 在 `init` 后不再更新 `screenState` 属性（之前通过 `applyScreenState()` 同步）。外部如果有代码读取 `mainWindowController.screenState`，它永远是 `.start`。当前没有发现外部读取该属性的场景，所以实际不影响功能。

**修复方案**: 当前可接受。如需保持同步，可在 coordinator 路由方法中同步更新，或改为 computed property 从 coordinator 读取。

---

### 优点记录

1. **appCoordinator 数据闭环**：Duplicate onFinished → reloadData() 从磁盘重新读取 JSON → showGroups()。彻底解决了旧方案中使用内存旧 records 导致分组不刷新的 BUG。
2. **makeVisiblePhotoGroups 的 reviewGroupId 隔离**：所有 non-duplicate 分组（overexposed/underexposed/blurry/normal）都增加了 `$0.reviewGroupId.isEmpty` 过滤，确保同一张照片不会同时出现在普通分组和 duplicate 分组中。
3. **photoMetalViewController 集成干净**：browser 和 duplicate VC 统一通过 `addChild` + `reset()` + `load(image:)` 管理 Metal 视图，切图时 zoom/pan 自动归零。
4. **metalPhotoView 精简到位**：删除了 4 个 compat 方法和 `jpgFallbackUrl`，文件从约 230 行精简到约 170 行，职责更清晰。

---

### 修复优先级建议

1. 🟠 **keepBoth 未清空 reviewGroupId** — 建议立即修复，"Keep both" 是 Duplicate 比较的核心功能之一，当前路径会导致 BUG4 在此场景下复现
2. 🟡 **死代码清理** — 不阻塞，后续清理
3. 🔵 **screenState 同步** — 不阻塞，按需处理
