# Duplicate 筛选归档、空 Normal 与组级旋转修复方案

**日期**: 2026-06-17  
**范围**: Groups 分组展示、Duplicate 对比筛选归档、Duplicate 对比页旋转状态  
**目标**: 修复 Duplicate 筛选后保留照片在 Normal 中不可见、初始无 Normal 时 Normal 卡片缺失、Duplicate 新顶替照片不继承旋转角度三个相关问题。

---

## 1. 背景与用户可观察问题

当前 App 存在三个相互关联的工作流问题：

1. 用户在 Duplicate 分组中选完照片后，期望保留下来且分析未失败的照片进入 Normal 分组，但回到 Normal 后看不见刚刚保留的照片。
2. 如果首次分析结果中没有任何 Normal 照片，Groups 页面不会出现 Normal 卡片，用户没有一个明确的“最终保留池”。
3. Duplicate 对比页的旋转角度当前只绑定到当前左右两张照片。用户旋转 A/B 后，淘汰其中一张，C 顶替进来时 C 仍是 0°，没有继承当前 duplicate 组的旋转状态。

这三个问题都属于“审片工作流展示语义”问题，不是分析算法问题，也不是原始 JPG/RAW 文件方向问题。

---

## 2. 当前代码病因

### 2.1 Duplicate 保留照片没有稳定进入 Normal

相关文件：

- `rawViewer/models/photoModels.swift`
- `rawViewer/duplicate/duplicateCompareViewModel.swift`
- `rawViewer/appCoordinator.swift`

当前 `duplicateCompareViewModel` 在筛选完成时会把保留下来的照片标记为：

```swift
reviewStatus = .kept
reviewGroupId = ""
```

但 `makeVisiblePhotoGroups(from:)` 中 Normal 的归类条件仍然是分析结果语义：

```swift
isNormalAnalysisResult
```

也就是：

```swift
!hasFailedAnalysis && !isBlurry && exposureStatus == "normal"
```

因此，如果 Duplicate 中保留下来的照片原本被分析为 blurry / overexposed / underexposed，它即使已经 `.kept`，也不会进入 Normal。当前代码没有把未失败的 `.kept` 解释为“人工筛选后保留，应展示在 Normal 工作流分组”。

### 2.2 初始没有 Normal 时 Normal 卡片消失

相关文件：

- `rawViewer/models/photoModels.swift`
- `rawViewer/groupGrid/groupGridViewController.swift`

当前 `makeVisiblePhotoGroups(from:)` 通过 `appendGroup` 追加分组：

```swift
private func appendGroup(_ kind: photoGroupKind, photos: [photoItem], into groups: inout [photoGroup]) {
    guard !photos.isEmpty else { return }
    groups.append(photoGroup(kind: kind, photos: photos))
}
```

Normal 也走这个空组过滤，所以没有 Normal 照片时不会生成 Normal 分组。

同时 `visibleGroupCards(from:)` 也会过滤空组：

```swift
public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { !$0.photos.isEmpty }
}
```

所以即使后续把空 Normal 生成出来，也仍会被卡片层过滤掉。

### 2.3 Duplicate 旋转是当前 pair 状态，不是组级状态

相关文件：

- `rawViewer/duplicate/duplicateCompareViewModel.swift`
- `rawViewer/duplicate/duplicateCompareViewController.swift`

当前旋转方法只写当前左右两张：

```swift
if let left = mainPhoto {
    rotations[left.photoId] = rotatedDegrees(left.rotationDegrees, direction: direction)
}
if let right = candidatePhoto {
    rotations[right.photoId] = rotatedDegrees(right.rotationDegrees, direction: direction)
}
```

显示时也从单张照片读取：

```swift
viewModel.mainPhoto?.rotationDegrees
viewModel.candidatePhoto?.rotationDegrees
```

所以 A/B 被旋转后，未显示过的 C/D/E 不会被更新。C 顶替进来时仍然使用自己的旧 `rotationDegrees`，通常是 0°。

---

## 3. 成功标准

本次修复完成后应满足：

1. Groups 页面永远显示 Normal 卡片，即使数量为 0，也显示 `Normal · 0`。
2. Duplicate 中被保留且分析未失败的照片返回 Groups 后进入 Normal 分组。
3. 未失败的 `.kept` 照片不会因为原始分析是 blurry / overexposed / underexposed 而继续显示在异常分组中；失败分析照片仍不进入 Normal。
4. Duplicate 页点击左旋/右旋后，当前 duplicate 组剩余照片共享同一个旋转状态。
5. A/B 旋转后，C 顶替进来时直接按相同角度显示。
6. 旋转状态仍写入现有 `analysis.json` 的 `rotationDegrees` 字段，不修改原始照片文件。
7. 不改分析算法，不引入新的持久化格式，不重构导航架构。

---

## 4. 方案选项与取舍

### 方案 A：修改分析字段，让 kept 照片变成真正 normal

做法：Duplicate 保留时直接改：

```swift
exposureStatus = "normal"
isBlurry = false
```

优点：现有 Normal 归类逻辑几乎不用改。

缺点：会破坏原始分析结果。照片原本是否过曝/欠曝/虚焦的信息被覆盖，后续无法区分“分析 normal”和“人工保留”。

结论：不推荐。

### 方案 B：新增展示语义，未失败的 `.kept` 归入 Normal

做法：保留原始分析字段不变，新增展示语义：

```swift
isNormalDisplayPhoto = (reviewStatus == .kept && !hasFailedAnalysis) || isNormalAnalysisResult
```

Normal 分组使用展示语义；异常分组排除 `.kept`；Duplicate 仍按有效 `reviewGroupId` 生成。为保持 v1.9 的失败分析兼容语义，`failed` / `jpg_failed` / `none` 即使被 `.kept` 也不进入 Normal。

优点：符合用户心智，保留分析数据，改动集中。

缺点：Normal 这个名字同时承载“分析正常”和“人工保留池”两层含义，需要在代码命名中明确为 display 语义。

结论：推荐。

### 方案 C：新增独立 Kept / Selected 分组

做法：新增一个新的 `photoGroupKind.kept`，Duplicate 里保留的照片进入 Kept，而不是 Normal。

优点：语义最严格。

缺点：不符合用户当前明确要求“放进 Normal”；UI 分组数量变多，范围变大。

结论：不采用。

---

## 5. 推荐设计

采用方案 B，并配套修复空 Normal 与 Duplicate 组级旋转。

### 5.1 Normal 固定生成

修改 `rawViewer/models/photoModels.swift`：

- `makeVisiblePhotoGroups(from:)` 中 Normal 不再通过 `appendGroup` 追加。
- Normal 直接追加，即使 `photos` 为空。

目标逻辑：

```swift
let normalPhotos = visiblePhotos.filter {
    $0.isNormalDisplayPhoto && !isInValidDuplicateGroup($0)
}
groups.append(photoGroup(kind: .normal, photos: normalPhotos))
```

### 5.2 Group Grid 保留空 Normal 卡片

修改 `rawViewer/groupGrid/groupGridViewController.swift`：

```swift
public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { group in
        if case .normal = group.kind { return true }
        return !group.photos.isEmpty
    }
}
```

这样其他空分组仍隐藏，但 Normal 作为固定工作流入口保留。

### 5.3 未失败的 `.kept` 进入 Normal 展示语义

修改 `rawViewer/models/photoModels.swift` 的 `photoItem` extension：

```swift
var isNormalDisplayPhoto: Bool {
    (reviewStatus == .kept && !hasFailedAnalysis) || isNormalAnalysisResult
}
```

分组规则调整为：

- Overexposed：排除 `.kept`，排除仍处于有效 duplicate 组中的照片。
- Underexposed：排除 `.kept`，排除仍处于有效 duplicate 组中的照片。
- Blurry：排除 `.kept`，排除仍处于有效 duplicate 组中的照片。
- Normal：包含 `isNormalDisplayPhoto`，排除仍处于有效 duplicate 组中的照片；`isNormalDisplayPhoto` 已排除失败分析照片。
- Duplicate：只对 visible 且 `reviewGroupId` 非空、同组数量 >= 2 的照片生成。

关键点：

- `.kept` 不改原始 `isBlurry` / `exposureStatus`。
- `.kept` 不再展示到异常分组，避免一张人工保留照片同时出现在 Normal 和异常组。
- `failed` / `jpg_failed` / `none` 保持不归入 Normal，即使其 reviewStatus 后续变为 `.kept`。

### 5.4 Duplicate 旋转改为当前组剩余照片整体旋转

修改 `rawViewer/duplicate/duplicateCompareViewModel.swift`：

新增或替换为组级方法：

```swift
@discardableResult
public func rotateCurrentGroup(direction: photoRotationDirection) throws -> [String: Int] {
    guard !photos.isEmpty else { return [:] }

    let baseRotation = mainPhoto?.rotationDegrees
        ?? candidatePhoto?.rotationDegrees
        ?? photos.first?.rotationDegrees
        ?? 0
    let targetRotation = rotatedDegrees(baseRotation, direction: direction)
    let rotations = Dictionary(uniqueKeysWithValues: photos.map { ($0.photoId, targetRotation) })

    try store.setRotations(rotations)

    for index in photos.indices {
        photos[index].rotationDegrees = targetRotation
    }
    return rotations
}
```

保留旧方法作为兼容转发：

```swift
@discardableResult
public func rotateCurrentPair(direction: photoRotationDirection) throws -> [String: Int] {
    try rotateCurrentGroup(direction: direction)
}
```

修改 `rawViewer/duplicate/duplicateCompareViewController.swift`：

- 旋转按钮调用 `rotateCurrentGroup(direction:)`。
- 失败日志从左右单张角度改成 `targetCount`，避免误导。

---

## 6. 数据流设计

### 6.1 Duplicate 筛选后进入 Normal

```text
用户在 Duplicate 中选择保留
        ↓
duplicateCompareViewModel 写入 analysis.json
        ↓
保留照片 reviewStatus = .kept，reviewGroupId = ""
        ↓
appCoordinator reloadData()
        ↓
makeVisiblePhotoGroups(from:)
        ↓
未失败的 .kept 照片符合 isNormalDisplayPhoto
        ↓
进入 Normal 分组

失败分析照片即使为 .kept，也因 hasFailedAnalysis == true 不进入 Normal。
```

### 6.2 空 Normal 固定显示

```text
analysis records
        ↓
makeVisiblePhotoGroups(from:)
        ↓
无论 normalPhotos 是否为空，都 append .normal
        ↓
visibleGroupCards(from:)
        ↓
.normal 空组不过滤
        ↓
Groups 页面显示 Normal · 0
```

### 6.3 Duplicate 组级旋转继承

```text
当前 duplicate photos = [A, B, C, D]
        ↓
用户点击右旋 90°
        ↓
rotateCurrentGroup 以当前 mainPhoto 角度为锚点计算 targetRotation
        ↓
A/B/C/D 所有剩余照片 rotationDegrees 统一写为同一个 targetRotation
        ↓
当前 A/B 重新加载显示 90°
        ↓
用户淘汰 B，C 顶替
        ↓
C 已经有 90°，直接按 90° 显示
```

---

## 7. 具体修改文件

### 7.1 `rawViewer/models/photoModels.swift`

修改点：

1. 文件头版本与描述更新。
2. `photoItem` extension 增加：

```swift
var isNormalDisplayPhoto: Bool
```

3. 修改 `makeVisiblePhotoGroups(from:)`：
   - 异常组排除 `.kept`。
   - Normal 使用 `isNormalDisplayPhoto`。
   - Normal 固定 append。
   - Duplicate 仍只对有效 `reviewGroupId` 且数量 >= 2 的组生成。

### 7.2 `rawViewer/groupGrid/groupGridViewController.swift`

修改点：

1. 文件头版本与描述更新。
2. `visibleGroupCards(from:)` 保留空 Normal，其他空分组继续隐藏。

### 7.3 `rawViewer/duplicate/duplicateCompareViewModel.swift`

修改点：

1. 文件头版本与描述更新。
2. 新增 `rotateCurrentGroup(direction:)`。
3. 旧 `rotateCurrentPair(direction:)` 转发到 `rotateCurrentGroup(direction:)`。

### 7.4 `rawViewer/duplicate/duplicateCompareViewController.swift`

修改点：

1. 文件头版本与描述更新。
2. 旋转交互调用 `rotateCurrentGroup(direction:)`。
3. 失败日志记录 `targetCount`、left/right photoId 和错误信息。

---

## 8. 非目标

本方案不做以下事情：

1. 不修改 JPG/RAW 原文件方向。
2. 不重新分析照片。
3. 不修改 `exposureStatus` 或 `isBlurry` 来伪造分析结果。
4. 不新增 Kept 分组。
5. 不重构 `appCoordinator` 导航架构。
6. 不新增新的 JSON schema 字段。
7. 不处理无关的 group card UI 美化。

---

## 9. 验证计划

### 9.1 构建验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：

```text
** BUILD SUCCEEDED **
```

### 9.2 静态确认

```bash
rg -n "isNormalDisplayPhoto|groups.append\(photoGroup\(kind: \.normal|case \.normal = group.kind" rawViewer/models/photoModels.swift rawViewer/groupGrid/groupGridViewController.swift
```

预期：能看到：

- `isNormalDisplayPhoto`
- Normal 固定 append
- `visibleGroupCards` 中保留空 Normal 的判断

```bash
rg -n "rotateCurrentGroup|baseRotation|targetRotation|Dictionary\(uniqueKeysWithValues|targetCount" rawViewer/duplicate/duplicateCompareViewModel.swift rawViewer/duplicate/duplicateCompareViewController.swift
```

预期：能看到：

- `rotateCurrentGroup`
- `baseRotation` / `targetRotation` 的锚点统一旋转逻辑
- `Dictionary(uniqueKeysWithValues:)` 的全组写入逻辑
- 控制器日志中的 `targetCount`

### 9.3 模型层临时验证（不使用测试框架）

使用 `/tmp/main.swift` 临时脚本验证核心模型规则；Duplicate ViewModel 验证可额外生成 `/tmp/duplicateSupport.swift` 声明最小协议支撑编译。不新增项目测试 target，不提交测试文件。验证点：

1. 空 Normal 固定生成；`visibleGroupCards` 保留空 Normal 由静态确认覆盖。
2. 未失败的 `.kept` 异常照片进入 Normal，不进入 Overexposed / Underexposed / Blurry。
3. `failed` / `jpg_failed` / `none` 的 `.kept` 照片不进入 Normal。
4. 历史混合旋转数据中 A/B=90、C=0 时，右旋后全组统一为 180。

### 9.4 手动验证：空 Normal

测试数据：没有初始 normal 照片，但有 duplicate 分组。

步骤：

1. 启动 App，选择测试文件夹。
2. 分析完成进入 Groups。
3. 确认显示 `Normal · 0`。
4. 点击 Normal。
5. 空浏览页不崩溃，操作按钮应不可用或无照片可操作。

### 9.5 手动验证：Duplicate 保留进入 Normal

测试数据：duplicate 组中至少有两张照片，其中至少一张原始分析不是 normal，且不是 failed / jpg_failed / none。

步骤：

1. 进入 Duplicate 分组。
2. 通过 keepLeft / keepRight / keepBoth 完成筛选。
3. 返回 Groups。
4. 进入 Normal。
5. 确认刚刚保留的照片可见。
6. 确认该 `.kept` 照片不会同时出现在 Blurry / Overexposed / Underexposed。

### 9.6 手动验证：Duplicate 旋转继承

测试数据：一个 duplicate 组至少三张照片 A/B/C。

步骤：

1. 进入 Duplicate，当前显示 A/B。
2. 点击右旋 90°。
3. 确认 A/B 都旋转 90°。
4. 用方向键保留 A 或 B，让 C 顶替进来。
5. 确认 C 直接以 90° 显示。
6. 返回 Groups 后重新进入该 duplicate 组。
7. 确认旋转角度仍然保持，说明持久化成功。

### 9.7 回归验证

1. 普通 Browser 页单张旋转仍只影响当前照片。
2. Delete / Trash 流程不受影响。
3. Restore Normal 仍能让异常照片离开异常组。
4. Duplicate 只有一张 visible 照片时不会显示为 Duplicate。

---

## 10. 风险与处理

### 风险 1：`.kept` 原本异常但展示到 Normal

这是有意选择，但只适用于未失败的分析结果。Normal 在这里表示“分析正常 + 人工筛选后保留池”，同时继续保持失败分析不归入 Normal 的既有语义。原始分析字段仍保留，后续如果要显示标记，可以继续使用 `isBlurry` / `exposureStatus`。

### 风险 2：组级旋转会影响未显示过的 duplicate 照片

这是本次需求的目标行为。用户在 duplicate 组中调整方向时，期望后续顶替照片继承同一方向。实现上必须统一写入同一个 `targetRotation`，而不是每张照片基于自己的旧角度分别累加。

### 风险 3：空 Normal 可点击后没有照片

当前 Browser 已经能处理空照片列表。最小方案允许进入空页，不额外做置灰或禁用，避免扩大 UI 范围。

---

## 11. 实施顺序建议

1. 修改 `photoModels.swift`，完成 `.kept` 展示语义和 Normal 固定生成。
2. 修改 `groupGridViewController.swift`，保留空 Normal 卡片。
3. 修改 `duplicateCompareViewModel.swift`，实现组级旋转。
4. 修改 `duplicateCompareViewController.swift`，切换调用和日志。
5. 运行构建验证。
6. 运行静态确认。
7. 运行模型层临时验证脚本。
8. 手动验证三个核心场景。

---

## 12. 自我复审

### 占位符扫描

无 TODO、无待补路径、无未完成章节。

### 内部一致性

- Normal 固定生成与 Grid 保留空 Normal 卡片一致。
- 未失败的 `.kept` 进入 Normal 与异常组排除 `.kept` 一致，避免重复展示；失败分析照片不归入 Normal。
- Duplicate 旋转继承通过组级统一 `targetRotation` 写入实现，与持久化字段 `rotationDegrees` 一致。

### 范围检查

方案集中在分组展示与 Duplicate 旋转，不涉及分析算法、文件方向写入、导航重构或新增持久化格式，范围可控。

### 歧义检查

已明确：Normal 在本方案中是工作流展示分组，包含分析 normal 和未失败的人工 kept；失败分析照片不进入 Normal。原始分析字段不被修改。
