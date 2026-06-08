# 重复分组相关 Bug 根因分析报告

**日期**: 2026-06-08
**涉及模块**: `photoModels.swift`, `duplicateCompareViewModel.swift`, `jsonReviewStateStore.swift`, `appCoordinator.swift`, `jsonManager.cpp`
**问题描述**:
1. 单张照片也被显示为一个重复分组；
2. 进入重复分组完成筛选后，该分组在返回卡片界面时仍然存在，未将最终照片移入 normal 等常规分组。

---

## 一、当前处理逻辑全链路梳理

### 1.1 重复分组的创建（C++ 后端）

在 `cpp/src/jsonManager.cpp` 的 `recomputeTimeDuplicateGroups` 中，根据 shooting_time 以 **3 秒阈值** 进行时间聚类：

```cpp
size_t groupSize = index - groupStart;
if (groupSize < 2) {
    continue;  // 初始创建时排除了单张分组
}
```

聚类通过后，为组内每张照片写入 `review_group_id`（格式如 `dup_001`）。

### 1.2 分组的可见化构建（Swift 侧）

`rawViewer/photoModels.swift` 的 `makeVisiblePhotoGroups` 负责将 `photoItem` 列表转换为 `photoGroup` 列表：

```swift
let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }

// overexposed / underexposed / blurry / normal 分组
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)

// 重复分组
let duplicateGroupIds = Array(Set(visiblePhotos.map(\.reviewGroupId).filter { !$0.isEmpty })).sorted()
for reviewGroupId in duplicateGroupIds {
    appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
}
```

其中 `appendGroup` 的逻辑为：

```swift
private func appendGroup(_ kind: photoGroupKind, photos: [photoItem], into groups: inout [photoGroup]) {
    guard !photos.isEmpty else { return }
    groups.append(photoGroup(kind: kind, photos: photos))
}
```

### 1.3 重复分组的筛选交互（Duplicate Compare）

`rawViewer/duplicateCompareViewModel.swift` 提供三种操作：

#### keepLeft / keepRight
```swift
public func keepLeft() throws -> duplicateCompareActionResult {
    guard let left = mainPhoto else { return .finished }
    guard let right = candidatePhoto else {
        try markFinalKept(left)
        return .finished
    }
    try store.mark(photoId: right.photoId, status: .trashed)   // 淘汰 -> trashed
    photos.removeAll { $0.photoId == right.photoId }            // 从内存数组移除
    if photos.count == 1 {
        try markFinalKept(left)                                 // 最后一张 -> kept + 清 reviewGroupId
        return .finished
    }
    // 继续比较...
}
```

#### keepBoth
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

#### markFinalKept
```swift
private func markFinalKept(_ photo: photoItem) throws {
    try store.mark(photoId: photo.photoId, status: .kept)
    if !photo.reviewGroupId.isEmpty {
        try store.setTemplate(reviewGroupId: photo.reviewGroupId, templatePhotoId: photo.photoId)
        try store.clearReviewGroupId(photoId: photo.photoId)     // 关键：清空 review_group_id
    }
}
```

### 1.4 状态持久化

`rawViewer/jsonReviewStateStore.swift` 直接读写 `.cache/analysis.json`：
- `mark()` → 修改 `review_status`
- `clearReviewGroupId()` → 将 `review_group_id` 置为空字符串 `""`
- `setTemplate()` → 为组内照片写入 `template_photo_id`

### 1.5 完成后的数据重载

`rawViewer/appCoordinator.swift`：
```swift
duplicate.onFinished = { [weak self] in
    guard let self = self else { return }
    do {
        try self.reloadData()      // 重新从 JSON 加载所有照片状态
    } catch {
        // 失败时仍 showGroups，使用内存中的旧数据
    }
    self.showGroups()
}
```

`reloadData()` 调用 `analyzer.loadAnalysisResult()`，C++ 侧每次都会 `JsonManager::init()` 重新读取文件。

---

## 二、Bug 1：单张重复分组仍被显示

### 根因定位

**文件**: `rawViewer/photoModels.swift`
**函数**: `makeVisiblePhotoGroups`

当某个 `reviewGroupId` 下原本有多张照片，但经过用户操作后，**其他照片被标记为 `.trashed` 或 `.passed`**，导致 `visiblePhotos` 中该 group 仅剩 **1 张**照片时：

```swift
for reviewGroupId in duplicateGroupIds {
    appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
}
```

`appendGroup` 仅检查 `!photos.isEmpty`，未对 `duplicate` 类型的分组做 **数量 >= 2** 的校验。因此单张照片也会被创建为一个独立的 `.duplicate` 分组。

### 为什么会产生单张可见的情况

1. **用户筛选导致**：`keepLeft`/`keepRight` 将被淘汰的照片标记为 `.trashed`，这些照片从 `visiblePhotos` 中被过滤掉，组内照片数量减少。
2. **keepBoth 导致**（见 Bug 2 路径 A）：如果分组原本 >= 3 张，`keepBoth` 只处理了 2 张，剩余照片仍留在组内。但如果剩余照片被其他操作（如 browser 中的 passed）处理，也可能导致只剩 1 张。

---

## 三、Bug 2：筛选完成后重复分组依旧存在

此现象存在 **多条可能路径**，核心根因如下：

### 路径 A：keepBoth 未处理分组中剩余照片（主因）

**文件**: `rawViewer/duplicateCompareViewModel.swift`
**函数**: `keepBoth`

假设一个重复分组初始有 **3 张照片 [A, B, C]**：
- ViewModel 初始化后：`mainIndex=0 (A)`, `candidateIndex=1 (B)`，C 在数组中但不在当前比较位。
- 用户点击 **Keep both**：
  - A 被 mark `.kept` + `clearReviewGroupId`
  - B 被 mark `.kept` + `clearReviewGroupId`
  - **C 完全未被处理**，`review_status` 仍为 `active`，`review_group_id` 仍为原 groupId
- 返回 `finished` → `reloadData()` → `makeVisiblePhotoGroups()`
- `visiblePhotos` 仍包含 **C**（active，reviewGroupId 非空）
- 因此该 `reviewGroupId` 仍被创建为 `.duplicate` 分组，且只有 **1 张照片**

**与 keepLeft/keepRight 的对比**：
- `keepLeft`/`keepRight` 每次都会 `photos.removeAll` 淘汰者，并在 `photos.count == 1` 时调用 `markFinalKept`，确保内存数组和 JSON 中所有照片都被处理完毕。
- `keepBoth` 却**直接返回 `.finished`，没有遍历处理 `photos` 中剩余的其他照片**。

### 路径 B：单张重复分组的"幽灵显示"

即使 `keepLeft`/`keepRight` 通过 `markFinalKept` 正确清除了最后一张照片的 `reviewGroupId`，如果由于其他原因（如用户在 Browser 中对某张重复组照片点了 passed，或 JSON 被外部修改）导致某 `reviewGroupId` 下只剩 1 张 visible 照片，**Bug 1 的单张显示问题会让这个"幽灵分组"继续出现在界面上**。

### 路径 C：reloadData 失败回退（低概率）

**文件**: `rawViewer/appCoordinator.swift`

```swift
do {
    try self.reloadData()
} catch {
    // reloadData 失败时仍尝试 showGroups，用内存中的旧数据
}
self.showGroups()
```

如果 `reloadData()` 抛出异常（如 JSON 文件损坏、磁盘权限问题），`records` 不会被更新，后续 `showGroups()` 使用的是**内存中的旧数据**，旧分组自然仍然存在。但此路径需要异常发生，非主要根因。

---

## 四、数据流向图（关键问题标注）

```
┌─────────────────────┐
│  recomputeTimeDuplicateGroups  │  ← 初始创建，groupSize<2 被跳过
│  (jsonManager.cpp)  │
└──────────┬──────────┘
           │ 写入 review_group_id
           ▼
┌─────────────────────┐
│   analysis.json     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  makeVisiblePhotoGroups (photoModels.swift)                  │
│  ─────────────────────────────────────────                   │
│  visiblePhotos = 过滤掉 passed/trashed                       │
│  ─────────────────────────────────────────                   │
│  对每组 reviewGroupId 创建 .duplicate 分组                   │
│  ❌ BUG 1: 未校验数量 >= 2，单张也会建组                     │
└──────────┬──────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  duplicateCompareViewModel                                   │
│  ─────────────────────────────────────────                   │
│  keepLeft/keepRight: 逐张淘汰 -> 最后一张 clearReviewGroupId │
│  keepBoth: 只处理 main+candidate                             │
│  ❌ BUG 2-A: 未处理 photos 中剩余的其他照片                  │
└──────────┬──────────────────────────────────────────────────┘
           │ 更新 JSON
           ▼
┌─────────────────────┐
│   analysis.json     │  ← 被 Swift 侧直接修改
└──────────┬──────────┘
           │ reloadData()
           ▼
┌─────────────────────────────────────────────────────────────┐
│  JsonManager::init() -> getAllPhotoStates()                  │
│  重新读取文件 -> 生成 photoItem 列表                         │
│  ─────────────────────────────────────────                   │
│  若 keepBoth 漏处理了 C，C 的 reviewGroupId 仍在             │
│  -> makeVisiblePhotoGroups 仍会为该 groupId 创建 duplicate   │
│  -> 同时该 group 可能只剩 1 张，触发 BUG 1 的显示问题        │
└─────────────────────────────────────────────────────────────┘
```

---

## 五、为什么"最后选择的照片没有进入 normal 分组"

用户期望：筛选完成后，最终保留下来的照片应该像普通照片一样进入 `normal`/`blurry`/`overexposed`/`underexposed` 分组。

当前逻辑下，这取决于该照片的 `reviewGroupId` 是否被成功清空：

| 操作路径 | reviewGroupId 是否清空 | 是否会进入常规分组 |
|---------|----------------------|------------------|
| keepLeft/keepRight 到只剩 1 张 | ✅ `markFinalKept` 会调用 `clearReviewGroupId` | ✅ 是，按 blur/exposure 属性归入对应分组 |
| keepBoth（2 张照片） | ✅ 两张都会被 `clearReviewGroupId` | ✅ 是 |
| keepBoth（>= 3 张照片） | ❌ 仅 main+candidate 被清空，其余照片保留原 groupId | ❌ 剩余照片仍留在 duplicate 分组 |

此外，常规分组的过滤条件是：
```swift
appendGroup(.normal, photos: visiblePhotos.filter { !$0.isBlurry && $0.exposureStatus == "normal" && $0.reviewGroupId.isEmpty }, into: &groups)
```

照片只有同时满足 `reviewGroupId.isEmpty` 才会进入常规分组。如果 `reviewGroupId` 未被清空，即使它不再是"重复"状态，也**无法进入任何常规分组**，只能在 `duplicate` 分组中"悬挂"。

---

## 六、关联代码索引

| 文件 | 行/区域 | 说明 |
|-----|--------|------|
| `rawViewer/photoModels.swift` | `makeVisiblePhotoGroups` 函数末尾的 duplicate 分组构建循环 | Bug 1 发生点：未过滤单张 duplicate 分组 |
| `rawViewer/duplicateCompareViewModel.swift` | `keepBoth` 方法 | Bug 2-A 发生点：未遍历处理所有照片 |
| `rawViewer/duplicateCompareViewModel.swift` | `keepLeft`/`keepRight` 方法 | 正常路径：通过 `markFinalKept` 正确处理最后一张照片 |
| `rawViewer/appCoordinator.swift` | `duplicate.onFinished` 闭包 | reloadData 失败时无保护性回退，使用旧数据 |
| `rawViewer/jsonReviewStateStore.swift` | `clearReviewGroupId` 方法 | 数据持久化接口本身无问题 |
| `cpp/src/jsonManager.cpp` | `recomputeTimeDuplicateGroups` | 初始创建逻辑正确，groupSize < 2 已排除 |

---

## 七、修复方向建议（非实施）

1. **在 `makeVisiblePhotoGroups` 中过滤单张 duplicate 分组**：
   构建 duplicate 分组时，仅当该 group 的 visible 照片数量 **>= 2** 时才创建分组；否则让这 1 张照片按自身属性（blur/exposure）归入常规分组。

2. **修正 `keepBoth` 处理全部照片**：
   `keepBoth` 应遍历 `photos` 数组中**所有照片**（而不仅是 main+candidate），为每张照片执行 `mark(.kept)` + `clearReviewGroupId`。

3. **统一 `visibleGroupCards` 的过滤逻辑**：
   `groupGridViewController.swift` 中的 `visibleGroupCards` 目前只过滤 `photos.isEmpty`，与 `makeVisiblePhotoGroups` 的单张 duplicate 问题形成叠加，建议两端保持一致校验。

4. **为 `reloadData()` 失败增加更明确的处理**：
   当前 `onFinished` 中 `reloadData` 失败静默吞掉异常，建议至少打印日志或给用户提示，避免旧数据导致的界面不一致。
