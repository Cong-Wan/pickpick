## 代码审核报告 — Plan3 View Rewrites

### 总览
- 审核文件：5 个
  - `photoThumbnailCellView.swift`（新建）
  - `photoThumbnailView.swift`（重写）
  - `groupGridViewModel.swift`（修改）
  - `groupCollectionViewItem.swift`（新建）
  - `groupGridViewController.swift`（重写）
- 发现问题：🔴 0 个 / 🟠 1 个 / 🟡 2 个 / 🔵 1 个
- 整体评价：核心架构改进（NSTableView 增量刷新、NSCollectionView 替代 NSGridView）正确到位，异步缩略图加载的 Task 生命周期管理清晰。主要问题在于 `groupGridViewController` 中 `card.onTap` 和 `didSelectItemsAt` 双触发。

---

### 问题清单

### 🟠 [High] groupGridViewController 点击回调双触发

**位置**: `groupGridViewController.swift` — `itemForRepresentedObjectAt` + `didSelectItemsAt`
**问题**: `NSCollectionView.isSelectable = true` 使得点击 item 时触发 `didSelectItemsAt`；同时 `groupCardView` 内部有 `NSClickGestureRecognizer` 触发 `onTap`。在 `itemForRepresentedObjectAt` 中又设置了 `card.onTap = { self?.onSelectGroup?(group) }`。用户点击卡片时，`onSelectGroup` 会被调用两次。

**修复方案**: 移除 `card.onTap` 设置，只保留 `didSelectItemsAt`。同时可以保留 `isSelectable = true` 来让 CollectionView 管理选中态。

```swift
// itemForRepresentedObjectAt 中删除以下代码：
// if let card = item.view.subviews.first as? groupCardView {
//     card.onTap = { [weak self] in
//         self?.onSelectGroup?(group)
//     }
// }
```

---

### 🟡 [Medium] groupCollectionViewItem 每次 configure 重建整个 cardView

**位置**: `groupCollectionViewItem.swift` — `configure(with:imageService:)`
**问题**: 每次调用 `configure` 都会 `removeFromSuperview` 旧 card 并创建新 `groupCardView`（含 3 个 NSImageView + 3 个异步加载 Task + 约束）。虽然 `prepareForReuse` 正确清理了旧 card，但 cell 复用的核心价值是**更新数据而非重建 UI**。当前 `groupCardView` 不支持增量更新（所有 UI 在 `init` 中创建），所以这是 `groupCardView` 本身的设计限制。

**修复方案**: 当前可接受。后续如需优化，可给 `groupCardView` 增加 `update(group:previewPhotos:imageService:)` 方法，只更新 label/重新加载缩略图而不重建视图层级。

---

### 🟡 [Medium] groupGridViewController 没有公开方法刷新数据

**位置**: `groupGridViewController.swift` — class body
**问题**: 如果 `viewModel.groups` 在 controller 存活期间发生变化（通过 `viewModel.update(groups:)`），collectionView 不会感知到变化，UI 不会刷新。当前使用方式下（每次 showGroups 都创建新 controller），这不是问题。但如果未来需要支持"Duplicate 完成后刷新网格而不重建 controller"的场景，就需要添加 reload 方法。

**修复方案**: 当前可接受，不需要修改。如后续需要，添加：
```swift
public func reloadGroups(_ newGroups: [photoGroup]) {
    viewModel.update(groups: newGroups)
    collectionView.reloadData()
}
```

---

### 🔵 [Low] gestureRecognizers.removeAll() 可能移除系统手势

**位置**: `photoThumbnailView.swift` — `tableView(_:viewFor:row:)`
**问题**: `cell.gestureRecognizers.removeAll()` 在每次 cell dequeue 时移除所有手势。当前 cell 由代码创建（非 nib），且 NSTableView 本身不向 cell 添加手势，所以实际不会出问题。但这是一个防御性较弱的写法。

**修复方案**: 当前可接受。更安全的做法是只移除自己添加的点击手势（通过标记或引用追踪），但复杂度收益不成比例。

---

### 优点记录

1. **photoThumbnailCellView 的 Task 生命周期管理**：`configure` 时 `cancelLoad` 旧 task 再启动新 task，`prepareForReuse` 再次确保清理，`[weak self, weak targetView]` 避免悬挂引用。整个链路清晰完整。
2. **setCurrentIndex 增量刷新**：`IndexSet([oldIndex, index])` 只刷新两行，彻底解决了旧方案 `reloadThumbnails()` 全量重建的性能问题。
3. **groupGridViewModel.cardWidth(for:)** 新方法与 `columnCount(for:)` 使用完全一致的宽度扣除逻辑（scrollerWidth），避免了两处计算不一致的风险。
4. **checkedIds 的交集过滤** 在 `setCheckedIds` 和 `updatePhotos` 中都正确执行，避免指向不存在照片的脏数据。

---

### 修复优先级建议

1. 🟠 **groupGridViewController 双触发** — 建议立即修复，会导致导航行为异常（如连续 push 两个相同页面）
2. 🟡 **cardView 重建** — 当前不阻塞，作为性能优化 backlog
3. 🟡 **数据刷新方法** — 当前不阻塞，按需添加
