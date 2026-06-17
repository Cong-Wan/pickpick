# Duplicate 归入 Normal 与组级旋转继承实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 修复 Normal 分组缺失与 Duplicate 对比页新顶替照片不继承旋转状态的问题。

**架构：** 分组层把 Normal 视为固定工作流分组，并把 Duplicate 中已保留的 `.kept` 照片按展示语义归入 Normal，但不改写原始分析字段。Duplicate 旋转从当前左右 pair 扩大为当前 duplicate 组剩余照片整体旋转，继续通过 `analysis.json` 持久化。

**技术栈：** Swift、AppKit、现有 `photoItem` / `photoGroup` 模型、`jsonReviewStateStore`、`xcodebuild`。

---

## 前置决策

用户选择不需要详尽打印。本计划不新增普通打印输出，也不新增新的日志基础设施；项目已有 `appDebugLogger`，其 `--debug` 解析逻辑位于 `rawViewer/services/appDebugLogger.swift`。如实现过程中需要临时排查，只允许使用受 `--debug` 控制的 `appDebugLogger.log`，完成实现时不得留下临时调试输出。

## 范围检查

本计划只覆盖两个紧密相关的工作流体验问题：

1. Normal 分组可见性与 Duplicate 保留照片的展示归档。
2. Duplicate 对比页旋转状态继承。

不修改分析算法、不重构导航架构、不引入新持久化格式、不创建测试 target。

## 文件结构

将修改以下文件：

- `rawViewer/models/photoModels.swift` — 定义照片展示归类语义，并生成固定 Normal 分组。
- `rawViewer/groupGrid/groupGridViewController.swift` — 分组卡片过滤时保留空 Normal 卡片。
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 将 Duplicate 旋转范围从左右两张改为当前组剩余照片。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 调用组级旋转方法，并调整失败日志字段。

不创建新文件。

---

### Task 1: 固定 Normal 分组并让 Duplicate 保留照片归入 Normal 展示

**目标：** 分组页即使没有 normal 照片也显示 `Normal · 0`，并且 Duplicate 中保留后的 `.kept` 照片返回分组页后显示在 Normal 分组中。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 增加展示归类语义，调整 `makeVisiblePhotoGroups(from:)`。
- `rawViewer/groupGrid/groupGridViewController.swift` — 保留空 Normal 卡片，其他空卡片继续隐藏。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer/models/photoModels.swift` 文件头：

将文件头替换为：

```swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-16
Description: 固定生成 Normal 工作流分组，并让 duplicate 中已保留的 kept 照片按展示语义归入 Normal；保留旋转持久化与失败分析不归入 Normal 的兼容逻辑
*/
```

- [ ] 在 `rawViewer/models/photoModels.swift` 中，将现有 `photoItem` extension：

```swift
nonisolated public extension photoItem {
    var hasFailedAnalysis: Bool {
        exposureStatus == "failed" || analysisSource == "jpg_failed" || analysisSource == "none"
    }

    var isNormalAnalysisResult: Bool {
        !hasFailedAnalysis && !isBlurry && exposureStatus == "normal"
    }
}
```

完整替换为：

```swift
nonisolated public extension photoItem {
    var hasFailedAnalysis: Bool {
        exposureStatus == "failed" || analysisSource == "jpg_failed" || analysisSource == "none"
    }

    var isNormalAnalysisResult: Bool {
        !hasFailedAnalysis && !isBlurry && exposureStatus == "normal"
    }

    var isNormalDisplayPhoto: Bool {
        reviewStatus == .kept || isNormalAnalysisResult
    }
}
```

- [ ] 在 `rawViewer/models/photoModels.swift` 中，将完整的 `makeVisiblePhotoGroups(from:)` 函数替换为：

```swift
public func makeVisiblePhotoGroups(from photos: [photoItem]) -> [photoGroup] {
    let visiblePhotos = photos.filter { $0.reviewStatus != .passed && $0.reviewStatus != .trashed }
    var groups: [photoGroup] = []

    let groupCounts = Dictionary(grouping: visiblePhotos, by: \.reviewGroupId)
        .filter { !$0.key.isEmpty }
        .mapValues { $0.count }
    let validDuplicateIds = Set(groupCounts.filter { $0.value >= 2 }.keys)

    func isInValidDuplicateGroup(_ photo: photoItem) -> Bool {
        !photo.reviewGroupId.isEmpty && validDuplicateIds.contains(photo.reviewGroupId)
    }

    appendGroup(.overexposed, photos: visiblePhotos.filter {
        $0.exposureStatus == "overexposed" && $0.reviewStatus != .kept && !isInValidDuplicateGroup($0)
    }, into: &groups)
    appendGroup(.underexposed, photos: visiblePhotos.filter {
        $0.exposureStatus == "underexposed" && $0.reviewStatus != .kept && !isInValidDuplicateGroup($0)
    }, into: &groups)
    appendGroup(.blurry, photos: visiblePhotos.filter {
        $0.isBlurry && $0.reviewStatus != .kept && !isInValidDuplicateGroup($0)
    }, into: &groups)

    let normalPhotos = visiblePhotos.filter {
        $0.isNormalDisplayPhoto && !isInValidDuplicateGroup($0)
    }
    groups.append(photoGroup(kind: .normal, photos: normalPhotos))

    for reviewGroupId in validDuplicateIds.sorted() {
        appendGroup(.duplicate(reviewGroupId: reviewGroupId), photos: visiblePhotos.filter { $0.reviewGroupId == reviewGroupId }, into: &groups)
    }

    return groups
}
```

- [ ] 修改 `rawViewer/groupGrid/groupGridViewController.swift` 文件头：

将文件头替换为：

```swift
/*
Author: wilbur
Version: 4.1
Date: 2026-06-16
Description: 网格控制器改用 NSCollectionView + NSCollectionViewFlowLayout，resize 时 invalidateLayout 而非全量重建；分组过滤保留空 Normal 工作流卡片
*/
```

- [ ] 在 `rawViewer/groupGrid/groupGridViewController.swift` 中，将 `visibleGroupCards(from:)` 完整替换为：

```swift
public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { group in
        if case .normal = group.kind { return true }
        return !group.photos.isEmpty
    }
}
```

------

#### Step 2 — 运行验证

- [ ] 运行构建命令：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：构建通过，末尾出现 ** BUILD SUCCEEDED **，无 Swift 编译错误。
```

- [ ] 运行静态确认命令：

```bash
$ rg -n "isNormalDisplayPhoto|case \.normal = group.kind|groups.append\(photoGroup\(kind: \.normal" rawViewer/models/photoModels.swift rawViewer/groupGrid/groupGridViewController.swift
# 预期：能看到 isNormalDisplayPhoto、保留空 Normal 的 case .normal 判断、Normal 分组固定 append 三处匹配。
```

如果验证不通过，修复实现后重新运行以上命令，直到构建通过且关键匹配存在。

------

✅ **完成的标志：** 构建通过，运行无异常，关键匹配确认 Normal 固定生成且空 Normal 不会被卡片过滤。

------

### Task 2: Duplicate 对比页旋转改为当前组整体继承

**目标：** Duplicate 组中 A/B 旋转后，B 被移除且 C 顶替进来时，C 自动展示为同一旋转角度。

**涉及的文件：**

- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 新增组级旋转方法，保留旧方法作为兼容转发。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 调用组级旋转方法并调整失败日志。

------

#### Step 1 — 实现

- [ ] 修改 `rawViewer/duplicate/duplicateCompareViewModel.swift` 文件头：

将文件头替换为：

```swift
/*
Author: wilbur
Version: 1.6
Date: 2026-06-16
Description: 注入 photoTrashService，keepLeft/keepRight 在标记 JSON 前先将文件移入废纸篓；Duplicate 旋转改为当前组剩余照片整体旋转，确保新顶替照片继承旋转状态
*/
```

- [ ] 在 `rawViewer/duplicate/duplicateCompareViewModel.swift` 中，将现有 `rotateCurrentPair(direction:)` 方法完整替换为以下两个方法：

```swift
@discardableResult
public func rotateCurrentGroup(direction: photoRotationDirection) throws -> [String: Int] {
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
}

@discardableResult
public func rotateCurrentPair(direction: photoRotationDirection) throws -> [String: Int] {
    try rotateCurrentGroup(direction: direction)
}
```

保留 `rotateCurrentPair` 是为了避免其他旧调用点在同一轮修改外发生编译断裂；控制器在本任务中会切到 `rotateCurrentGroup`。

- [ ] 修改 `rawViewer/duplicate/duplicateCompareViewController.swift` 文件头：

将文件头替换为：

```swift
/*
Author: wilbur
Version: 3.6
Date: 2026-06-16
Description: 重复照片双图比较界面，按左右任意一侧 JPG/RAW 文件存在性控制对应 segment；旋转按钮改为旋转当前 duplicate 组剩余照片，确保新顶替照片继承旋转状态
*/
```

- [ ] 在 `rawViewer/duplicate/duplicateCompareViewController.swift` 中，将完整的 `rotateCurrentPair(direction:actionName:)` 方法替换为：

```swift
private func rotateCurrentPair(direction: photoRotationDirection, actionName: String) {
    let left = viewModel.mainPhoto
    let right = viewModel.candidatePhoto
    guard left != nil || right != nil else { return }

    let targetCount = viewModel.photos.count

    do {
        _ = try viewModel.rotateCurrentGroup(direction: direction)
        loadPhotos()
    } catch {
        let leftId = left?.photoId ?? ""
        let rightId = right?.photoId ?? ""
        appFileLogger.log("operation failed page=duplicate action=\(actionName) targetCount=\(targetCount) leftPhotoId=\(leftId) rightPhotoId=\(rightId) error=\(error.localizedDescription)", level: .error)
        showErrorAlert(message: error.localizedDescription)
    }
}
```

------

#### Step 2 — 运行验证

- [ ] 运行构建命令：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：构建通过，末尾出现 ** BUILD SUCCEEDED **，无 Swift 编译错误。
```

- [ ] 运行静态确认命令：

```bash
$ rg -n "rotateCurrentGroup|for photo in photos|targetCount" rawViewer/duplicate/duplicateCompareViewModel.swift rawViewer/duplicate/duplicateCompareViewController.swift
# 预期：能看到 rotateCurrentGroup 方法、遍历 photos 的旋转逻辑、控制器失败日志中的 targetCount。
```

如果验证不通过，修复实现后重新运行以上命令，直到构建通过且关键匹配存在。

------

✅ **完成的标志：** 构建通过，运行无异常，关键匹配确认 Duplicate 旋转写回范围为当前组剩余照片。

------

### Task 3: 手动端到端验证

**目标：** 通过真实 App 流程确认 Normal 归档和 Duplicate 旋转继承都符合用户可观察行为。

**涉及的文件：**

- `rawViewer/models/photoModels.swift` — 分组行为来源。
- `rawViewer/groupGrid/groupGridViewController.swift` — 分组卡片显示来源。
- `rawViewer/duplicate/duplicateCompareViewModel.swift` — 旋转状态写回来源。
- `rawViewer/duplicate/duplicateCompareViewController.swift` — 旋转交互入口。

------

#### Step 1 — 实现

- [ ] 本任务不继续修改代码。保留 Task 1 和 Task 2 的实现结果。
- [ ] 不新增测试文件，不使用测试框架，不编排 Git 操作。

------

#### Step 2 — 运行验证

- [ ] 运行最终构建命令：

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
# 预期：构建通过，末尾出现 ** BUILD SUCCEEDED **，无 Swift 编译错误。
```

- [ ] 启动 App 进行手动验证。可使用 Xcode 运行，也可运行构建产物。若使用命令行查找构建产物，执行：

```bash
$ find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug/pickpick.app' -maxdepth 6 -print | tail -1
# 预期：输出一个 pickpick.app 路径。
```

- [ ] 打开 App 后验证 Normal 固定显示：

```text
1. 选择一个没有初始 normal 照片、且存在 duplicate 组的照片文件夹。
2. 分析完成后进入 Groups 页面。
3. 确认存在 Normal 卡片，即使数量为 0 也显示为 Normal · 0。
4. 进入 duplicate 组完成一次筛选，让至少一张照片变为 kept 且 reviewGroupId 被清空。
5. 返回 Groups 页面。
6. 确认 kept 照片出现在 Normal 分组，且不会同时出现在 Overexposed / Underexposed / Blurry 分组。
```

关键输出符合预期的判断：界面可见 `Normal · 0`，完成 Duplicate 筛选后 Normal 数量增加。

- [ ] 打开 App 后验证 Duplicate 旋转继承：

```text
1. 选择一个至少有三张照片的 duplicate 组。
2. 进入 duplicate 对比页，当前显示 A/B。
3. 点击右旋 90°。
4. 确认 A/B 同时旋转 90°。
5. 用方向键保留 A 或 B，让 C 顶替被移除照片的位置。
6. 确认新进入的 C 与当前另一侧照片保持相同旋转角度。
7. 返回 Groups 后重新进入该 duplicate 组。
8. 确认旋转角度仍然保持，说明持久化写入成功。
```

关键输出符合预期的判断：C 顶替进来时不再恢复为 0°，而是继承当前 duplicate 组旋转状态。

如果手动验证不通过，回到对应任务修复实现，然后重新构建和手动验证。

------

✅ **完成的标志：** 最终构建通过，App 运行无异常，Normal 固定显示与 Duplicate 组级旋转继承的可观察行为均符合预期。

------

## 自我复审

**1. 规范覆盖：** 方案中的三项需求均有对应任务：Normal 固定显示在 Task 1；`.kept` 归入 Normal 展示在 Task 1；Duplicate 新顶替照片继承旋转在 Task 2；端到端确认在 Task 3。

**2. 占位符扫描：** 计划中没有未完成标记、没有省略实现、没有要求工程师自行补齐的步骤。

**3. 类型一致性：** 新增 `photoItem.isNormalDisplayPhoto` 被 `makeVisiblePhotoGroups(from:)` 使用；新增 `rotateCurrentGroup(direction:)` 被 `duplicateCompareViewController` 调用；保留 `rotateCurrentPair(direction:)` 作为兼容转发，避免旧调用断裂。

**4. 验证完整性：** 每个任务都有 `xcodebuild` 构建验证；Task 1 和 Task 2 有 `rg` 静态确认；Task 3 有明确手动验证路径和可观察预期。
