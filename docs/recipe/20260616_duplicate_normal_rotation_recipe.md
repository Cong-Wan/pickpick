# Duplicate 筛选归档与组内旋转继承方案

**日期**: 2026-06-16  
**范围**: Normal 分组可见性、Duplicate 筛选后归档语义、Duplicate 对比页旋转状态继承  
**目标**: 用最少代码修复两个体验问题：没有初始 Normal 照片时 Normal 分组缺失；Duplicate 组旋转后新顶替照片没有继承当前旋转角度。

---

## 1. 背景与问题

### 1.1 Normal 分组缺失

当前 `makeVisiblePhotoGroups(from:)` 只在某个分组照片非空时追加分组。若初始没有任何 `isNormalAnalysisResult == true` 的照片，则不会生成 Normal 分组。用户处理 Duplicate 后，保留下来的照片虽然会被移出 duplicate 分组，但界面上没有一个明确的“最终保留池”，容易产生“照片不知道去哪了”的感受。

相关代码：

- `rawViewer/models/photoModels.swift`
  - `makeVisiblePhotoGroups(from:)`
  - `appendGroup(_:photos:into:)`
- `rawViewer/groupGrid/groupGridViewController.swift`
  - `visibleGroupCards(from:)`

### 1.2 Duplicate 旋转没有继承到新顶替照片

当前 Duplicate 页旋转只写入当前左右两张照片：

- `viewModel.mainPhoto`
- `viewModel.candidatePhoto`

如果 A/B 旋转 90° 后，用户选择 A，C 顶替 B 位置；C 没被旋转过，仍以 0° 展示，造成视觉状态断裂。

相关代码：

- `rawViewer/duplicate/duplicateCompareViewModel.swift`
  - `rotateCurrentPair(direction:)`
- `rawViewer/duplicate/duplicateCompareViewController.swift`
  - `rotateCurrentPair(direction:actionName:)`

---

## 2. 成功标准

1. 分组页在初始没有 normal 照片时仍显示 `Normal · 0`。
2. Duplicate 中被保留的照片返回分组页后稳定进入 Normal 分组。
3. Duplicate 页点击旋转后，当前 duplicate 组内剩余照片都继承同一旋转状态。
4. A/B 旋转后，B 被移除，C 顶替进来时，C 与 A 保持同一旋转角度。
5. 旋转状态仍通过 `analysis.json` 持久化，不修改 JPG/RAW 原文件。
6. 不引入新的复杂抽象，不改动分析算法。

---

## 3. 推荐方案

采用最小闭环方案：

1. Normal 分组改成固定工作流分组，即使为空也显示。
2. `reviewStatus == .kept` 的照片在展示分组上归入 Normal。
3. Duplicate 旋转从“当前 pair”改为“当前 duplicate 组剩余照片整体旋转”。

该方案避免修改原始分析结果字段，只调整工作流展示语义和旋转写回范围。

---

## 4. 详细设计

### 4.1 Normal 固定显示

修改 `rawViewer/models/photoModels.swift`：

- `makeVisiblePhotoGroups(from:)` 中 Normal 分组不再使用 `appendGroup` 的空组过滤。
- 直接追加 Normal 分组：

```swift
groups.append(photoGroup(kind: .normal, photos: normalPhotos))
```

其中 `normalPhotos` 可以为空。

修改 `rawViewer/groupGrid/groupGridViewController.swift`：

- `visibleGroupCards(from:)` 保留空 Normal。
- 其他空组仍过滤掉。

建议逻辑：

```swift
public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { group in
        if case .normal = group.kind { return true }
        return !group.photos.isEmpty
    }
}
```

### 4.2 Duplicate 保留照片归入 Normal 展示分组

不建议在 Duplicate 完成时强行修改：

- `exposureStatus`
- `isBlurry`

原因：这些字段代表分析结果，直接改掉会丢失原始判断信息。

推荐在 `photoItem` extension 中增加展示语义：

```swift
var isNormalDisplayPhoto: Bool {
    reviewStatus == .kept || isNormalAnalysisResult
}
```

然后调整分组过滤：

- Overexposed / Underexposed / Blurry 排除 `.kept`。
- Normal 使用 `isNormalDisplayPhoto`。
- Duplicate 仍只包含有效 duplicate group 中的 active/kept 可见照片；但一旦照片 `reviewGroupId` 被清空，就不会再进入 duplicate。

建议规则：

```swift
let isReviewKept = $0.reviewStatus == .kept
```

```swift
overexposed: exposureStatus == "overexposed" && !isReviewKept && !isInValidDuplicateGroup(photo)
underexposed: exposureStatus == "underexposed" && !isReviewKept && !isInValidDuplicateGroup(photo)
blurry: isBlurry && !isReviewKept && !isInValidDuplicateGroup(photo)
normal: isNormalDisplayPhoto && !isInValidDuplicateGroup(photo)
```

这样 Duplicate 中保留下来的 `.kept` 照片会稳定出现在 Normal，而不会同时出现在异常分组。

### 4.3 Duplicate 旋转改为组级旋转

修改 `rawViewer/duplicate/duplicateCompareViewModel.swift`：

- 将 `rotateCurrentPair(direction:)` 的写回范围从 `mainPhoto/candidatePhoto` 扩大为 `photos` 全部剩余照片。
- 可保留原方法名以减少控制器改动，也可重命名为 `rotateCurrentGroup(direction:)`。

推荐重命名为：

```swift
public func rotateCurrentGroup(direction: photoRotationDirection) throws -> [String: Int]
```

核心逻辑：

```swift
var rotations: [String: Int] = [:]
for photo in photos {
    rotations[photo.photoId] = rotatedDegrees(photo.rotationDegrees, direction: direction)
}

guard !rotations.isEmpty else { return [:] }
try store.setRotations(rotations)

for index in photos.indices {
    let photoId = photos[index].photoId
    if let rotation = rotations[photoId] {
        photos[index].rotationDegrees = rotation
    }
}
return rotations
```

修改 `rawViewer/duplicate/duplicateCompareViewController.swift`：

- 调用新方法。
- 日志从 left/right 角度改为更通用的 `targetCount`，减少误导。

### 4.4 空 Normal 点击行为

最小方案：允许点击 `Normal · 0` 进入浏览页。当前浏览页已经能处理 `currentPhoto == nil`，按钮会禁用，图片区域为空。

可选增强：空 Normal 卡片不可点击或显示空状态文案。但这不是本次必须项，避免扩大范围。

---

## 5. 需要修改的文件

1. `rawViewer/models/photoModels.swift`
   - 增加 `isNormalDisplayPhoto` 展示语义。
   - 调整 `makeVisiblePhotoGroups(from:)`。
   - Normal 分组固定追加。

2. `rawViewer/groupGrid/groupGridViewController.swift`
   - `visibleGroupCards(from:)` 保留空 Normal。

3. `rawViewer/duplicate/duplicateCompareViewModel.swift`
   - 将旋转范围从当前 pair 改为当前 duplicate 组全部剩余照片。

4. `rawViewer/duplicate/duplicateCompareViewController.swift`
   - 调整方法调用与失败日志。

---

## 6. 验证计划

### 6.1 构建验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：构建通过。

### 6.2 Normal 固定显示验证

准备数据：所有照片都不是 normal，且至少有一个 duplicate 组。

步骤：

1. 打开文件夹完成分析。
2. 进入分组页。
3. 确认出现 `Normal · 0`。
4. 进入 duplicate 组并完成筛选。
5. 返回分组页。
6. 确认保留照片进入 Normal，Normal 数量增加。

### 6.3 Duplicate 旋转继承验证

准备数据：duplicate 组至少包含 A/B/C 三张。

步骤：

1. 打开 duplicate 组，当前显示 A/B。
2. 点击右旋 90°。
3. 确认 A/B 都为 90°。
4. 选择保留 A，让 C 顶替 B。
5. 确认 A/C 都为 90°。
6. 再点击右旋 90°。
7. 确认当前剩余组所有照片都为 180°。
8. 返回分组页再重新进入。
9. 确认旋转角度持久化。

### 6.4 回归验证

1. 普通浏览页单张旋转仍只影响当前照片。
2. Restore Normal 仍能让异常照片离开异常组。
3. Delete / Trash 流程不受影响。
4. Duplicate `keepLeft` / `keepRight` / `keepBoth` 原有筛选流程不受影响。

---

## 7. 风险与取舍

### 风险 1：`.kept` 进入 Normal 可能改变用户对异常组的预期

如果某张照片原本是 blurry，但在 duplicate 中被保留，它会进入 Normal，而不是继续留在 Blurry。

取舍：这符合当前诉求——Duplicate 筛选后的保留结果需要一个明确归档位置。原始分析字段不被改掉，后续如果要展示“保留但原本虚焦”的标记，仍有数据基础。

### 风险 2：组级旋转会持久化到尚未显示过的照片

用户旋转 A/B 时，C/D/E 也会被一起写入同角度。

取舍：这正是当前交互所需的“继承当前旋转状态”。Duplicate 组通常来自同一时间连拍，方向一致概率高。若个别照片方向不同，用户可再次旋转当前组调整。

### 风险 3：空 Normal 可点击时浏览页为空

最小方案允许进入空浏览页。此行为可接受，但体验一般。

后续可选增强：空组卡片置灰且不可点击，或进入后显示 `No photos in Normal`。

---

## 8. 非目标

本方案不做以下事情：

1. 不修改 RAW/JPG 原文件方向。
2. 不重新跑分析算法。
3. 不新增数据库或额外持久化文件。
4. 不重构整体分组架构。
5. 不新增测试 target；若项目已有测试目标，可补单元测试，否则以构建和手工验证为准。

---

## 9. 实施顺序建议

1. 修改 `makeVisiblePhotoGroups` 和 `visibleGroupCards`，先解决 Normal 固定显示与 `.kept` 归档。
2. 修改 Duplicate 旋转为组级旋转。
3. 构建验证。
4. 使用三张以上 duplicate 组做手工验证。

---

## 10. 自复审结果

- 占位符检查：无 TODO、无未填写路径。
- 一致性检查：Normal 固定显示与 `.kept` 归入 Normal 展示语义一致。
- 范围检查：只涉及分组展示与 Duplicate 旋转，不扩大到分析算法或文件修改。
- 歧义检查：明确选择“Duplicate 保留照片归入 Normal 展示分组”，不是修改分析字段。
