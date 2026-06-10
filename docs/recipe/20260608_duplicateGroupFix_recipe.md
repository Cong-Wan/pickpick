# 重复分组逻辑修复方案

**日期**: 2026-06-08
**关联 Bug 报告**: `docs/bugReport_duplicateGroupLogic.md`
**修改范围**: `rawViewer/duplicateCompareViewModel.swift`, `rawViewer/photoModels.swift`
**不修改范围**: C++ 后端 (`jsonManager.cpp`)、ViewController 层、Coordinator 层

---

## 一、问题陈述

当前重复分组（Duplicate Group）存在两个互相关联的 bug：

1. **单张分组不应被显示**：经过用户筛选后，某个 `reviewGroupId` 下仅剩 1 张可见照片，代码仍为其创建一个 `.duplicate` 分组卡片。一张图片不能构成"重复"。
2. **keepBoth 语义错误**：当重复组内照片数量 >= 3 时，点击 Keep both 只处理了 `mainPhoto` 和 `candidatePhoto` 两张，其余照片仍保留原 `reviewGroupId`。返回后该分组依旧存在，且用户对此无感知（UI 上从未展示过其余照片）。

---

## 二、修复目标

1. **表现层过滤**：`makeVisiblePhotoGroups` 中，仅当某个 `reviewGroupId` 下的可见照片数量 **>= 2** 时，才创建 `.duplicate` 分组；否则让这 1 张照片按自身属性（blur/exposure）归入常规分组（normal/blurry/overexposed/underexposed）。
2. **keepBoth 语义修正为"保留当前两张，其余继续比较"**：
   - 将 `mainPhoto` 和 `candidatePhoto` 标记为 `.kept` 并清空 `reviewGroupId`，移出重复组。
   - 从内存 `photos` 数组移除这两张。
   - 根据剩余照片数量决定下一步：
     - 剩余 0 张 → 返回 `.finished`
     - 剩余 1 张 → `markFinalKept` 后返回 `.finished`
     - 剩余 >= 2 张 → `setTemplate` 后更新索引，返回 `.continueComparing`

---

## 三、详细设计

### 3.1 `duplicateCompareViewModel.swift` — keepBoth 重写

#### 当前代码（有 bug）

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

**问题**：未从 `photos` 数组移除已保留的照片；未处理剩余照片数量 < 2 的自动收尾；剩余 >= 2 时不应返回 `.finished`。

#### 目标代码

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

    let keptIds = Set([mainPhoto, candidatePhoto].compactMap(\.photoId))
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

**关键变更点**：
1. 增加 `photos.removeAll` 将已保留照片从内存数组移除。
2. 增加 `switch photos.count` 分支处理三种剩余状态。
3. 剩余 >= 2 时调用 `setTemplate`（为仍在组内的照片设置模板引用）并更新 `mainIndex` / `candidateIndex`。
4. `keepLeft` / `keepRight` 的原有逻辑不变，它们已正确处理逐张淘汰路径。

---

### 3.2 `photoModels.swift` — makeVisiblePhotoGroups 过滤

#### 当前代码（有 bug）

```swift
let duplicateGroupIds = Array(Set(visiblePhotos.map(\.reviewGroupId).filter { !$0.isEmpty })).sorted()
for reviewGroupId in duplicateGroupIds {
    appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
}
```

**问题**：未校验数量 >= 2，单张也会创建 duplicate 分组；单张 orphan 因 `reviewGroupId` 非空，也无法进入常规分组。

#### 目标代码

```swift
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
```

**关键变更点**：
1. 先通过 `Dictionary(grouping:by:)` 统计每个 `reviewGroupId` 的可见照片数量。
2. 仅数量 >= 2 的 groupId 被纳入 `validDuplicateIds`。
3. 常规分组（overexposed/underexposed/blurry/normal）的过滤条件从 `reviewGroupId.isEmpty` 改为 `!isInValidDuplicateGroup()`，使单张 orphan 照片能被纳入常规分组。
4. `.duplicate` 分组只遍历 `validDuplicateIds`。

---

## 四、边界情况推演

### 4.1 分组恰好 2 张，keepBoth

| 步骤 | 状态 |
|-----|------|
| 初始 | photos = [A, B] |
| keepBoth | A, B → `.kept` + `groupId = ""`；`photos.removeAll(A, B)` → `[]` |
| 剩余 0 张 | 返回 `.finished` |
| reloadData | 该 groupId 不再存在；A, B 进入常规分组 |

→ 与当前 2 张 keepBoth 行为完全一致，向后兼容。

### 4.2 分组 3 张 [A, B, C]，keepBoth

| 步骤 | 状态 |
|-----|------|
| 初始 | photos = [A, B, C] |
| keepBoth | A, B → `.kept` + `groupId = ""`；`photos = [C]` |
| 剩余 1 张 | `markFinalKept(C)` → C `.kept` + `groupId = ""`；`photos = []` |
| 返回 | `.finished` |
| reloadData | 分组消失，A/B/C 全部进入常规分组 |

→ 3 张全部保留，全部正确归入常规分组。

### 4.3 分组 4 张 [A, B, C, D]，keepBoth

| 步骤 | 状态 |
|-----|------|
| 初始 | photos = [A, B, C, D] |
| keepBoth | A, B → `.kept` + `groupId = ""`；`photos = [C, D]` |
| 剩余 2 张 | `setTemplate(groupId, A)`；`mainIndex = 0(C)`，`candidateIndex = 1(D)` |
| 返回 | `.continueComparing` |
| UI 刷新 | 显示 C 和 D 的比较界面 |

→ 分组被拆分：A, B 进入常规分组；C, D 继续作为重复组存在。

### 4.4 分组 5 张，混用 keepLeft + keepBoth

初始 `[A, B, C, D, E]`

| 步骤 | 操作 | photos |
|-----|------|--------|
| 1 | keepLeft（淘汰 B）| `[A, C, D, E]` |
| 2 | keepLeft（淘汰 C）| `[A, D, E]` |
| 3 | keepBoth（保留 A, D）| `[E]` |
| 4 | 自动收尾 | `markFinalKept(E)` → `[]` |
| 5 | finished | — |

→ 混用操作也能正确收尾，所有照片进入常规分组。

### 4.5 Browser 外部操作导致单张 orphan

用户在 Browser 中对某张重复组照片点了 `.passed`，导致该 groupId 下仅剩 1 张 visible。

| 情况 | 当前行为 | 修复后行为 |
|-----|---------|-----------|
| 1 张 visible | 创建单张 duplicate 分组（Bug） | 不创建 duplicate 分组；该照片按 blur/exposure 归入常规分组 |
| 0 张 visible | 不创建任何分组（正确） | 不变 |

→ `makeVisiblePhotoGroups` 的过滤逻辑兜底了所有可能导致单张 orphan 的数据路径。

### 4.6 `reloadData()` 失败回退

`appCoordinator.onFinished` 中 `reloadData()` 失败时静默使用旧数据。此问题**不在本次修复范围内**，但需确认：修复后的 `keepBoth` 在内存层面已正确更新 `photos`，即使 `reloadData` 失败，Coordinator 调用 `showGroups()` 时也会重新调用 `makeVisiblePhotoGroups(from: records)`。由于 `records` 未被更新，显示的是旧数据，但这是一个已有问题，非本次引入。

---

## 五、修改文件清单

| 文件 | 修改类型 | 修改内容 |
|-----|---------|---------|
| `rawViewer/duplicateCompareViewModel.swift` | 编辑 | 重写 `keepBoth` 方法 |
| `rawViewer/photoModels.swift` | 编辑 | 重写 `makeVisiblePhotoGroups` 中 duplicate 分组构建逻辑 |

---

## 六、数据流图（修复后）

```
┌─────────────────────────────────────────────────────────────┐
│  duplicateCompareViewModel.keepBoth()                        │
│  ───────────────────────────────────                         │
│  1. mark main+candidate as .kept + clearReviewGroupId       │
│  2. photos.removeAll(main+candidate)                        │
│  3. switch photos.count:                                    │
│     0 → .finished                                           │
│     1 → markFinalKept(last) → .finished                     │
│     ≥2 → setTemplate → update index → .continueComparing   │
└──────────┬──────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  makeVisiblePhotoGroups(from: records)                       │
│  ─────────────────────────────────────                       │
│  1. 统计每个 reviewGroupId 的 visible 数量                   │
│  2. validDuplicateIds = { groupId | count ≥ 2 }             │
│  3. 常规分组过滤: !isInValidDuplicateGroup(photo)           │
│  4. duplicate 分组仅遍历 validDuplicateIds                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、兼容性

- **向后兼容**：`keepBoth` 在恰好 2 张照片时的行为不变；`keepLeft`/`keepRight` 完全不变；JSON 数据格式不变。
- **不影响 C++ 后端**：所有修改在 Swift 侧完成，不涉及 `jsonManager.cpp`。
- **不影响 UI/VC 层**：`duplicateCompareViewController` 的 `handleActionResult` 已支持 `.continueComparing` 和 `.finished`，无需修改。
- **不影响测试**：如需验证，可通过 `duplicateCompareViewModel` 的 `photos` 属性断言内存状态，通过 `store.operations` 断言持久化操作。
