# 浏览器旋转继承（已处理集合方案）+ duplicate 双侧删除按钮

> Recipe 规范文档。实现前需用户复审通过。

## 背景

用户反馈两个问题：

1. **浏览器分组旋转不继承**：在任意分组浏览照片时，旋转第一张（如左转 90°），切换到下一张时旋转没有「带过去」，下一张回到 0°。当前浏览器是「每张照片各自独立 `rotationDegrees`」，`rotateCurrentPhoto` 只转当前一张，所以切到下一张不继承。duplicate 对比页之前已改为「整组一起转」（`rotateCurrentGroup`），故无此问题。
2. **duplicate 对比页缺删除按钮**：当前只能用 ←/→ 方向键删左/删右，没有可点击的删除按钮；用户希望左右两张图各有一个删除按钮。

## 目标与非目标

**目标：**

- 浏览器分组：旋转某张后，浏览切换时旋转角度「带过去」并逐张持久化；但**已处理过的照片（手动转过或已被惯性带过）回翻时不被再次覆盖**，保留用户为每张设定的角度。
- duplicate 对比页：左右各加一个删除按钮，点击即删除对应一侧（点哪删哪）。

**非目标：**

- 不改 duplicate 对比页的旋转逻辑（已是整组旋转）。
- 不改缩略图列表 / 分组卡片预览的旋转显示（不在本次范围）。
- 不为 duplicate 删除按钮加二次确认（与方向键一致，废纸篓可恢复）。
- 不改 duplicate 删除的边界行为（复用 `keepLeft`/`keepRight`，零新增边界）。
- 不改浏览器删除确认弹窗（Enter/Esc 已正常工作，无需改动）。

## 需求 1 设计要点（与 B+B1 的关键区别）

用户明确否决了原 B+B1「回翻也用惯性覆盖」的行为——同组照片有横有竖，强绑单一角度会把竖图存成横图、且回翻偷改数据。最终确认的行为模型如下。

**核心：带过去要落盘（带过去即继承并持久化），但用「已处理集合」防止回翻覆盖。**

- 新增惯性角度 `carriedRotation: Int?`（nil = 尚未开始带旋转）。
- 新增「已处理集合」`handledPhotoIds: Set<String>`（记录已被碰过的照片：手动旋转过、或已被惯性带过落盘）。
- **旋转当前照片**：先落盘当前照片新角度 → 设 `carriedRotation` = 新角度 → 当前照片入 `handledPhotoIds` → 更新内存角度。
- **导航切到新当前照片**（movePrevious/moveNext/setCurrentIndex/confirmDelete 后/restoreNormalTargetsAndUpdateList 后）：若 `carriedRotation` 非 nil 且新当前照片**不在** `handledPhotoIds`，则把 `carriedRotation` 落盘到该照片 + 更新内存角度 + 该照片入 `handledPhotoIds`（之后回翻到它就跳过，不再覆盖）；若已在集合中，跳过（保留用户为它设定的角度）。
- **显示层**：`show` 仍读 `currentPhoto.rotationDegrees`（已被上述逻辑更新为正确的继承值或用户手动设定值）。
- **重置**：`carriedRotation`、`handledPhotoIds` 随 viewModel 生命周期重置为空。

### 行为规格（A 横图需转90才正、B 竖图0度即正、C 横图需转90才正）

| 步骤 | 动作 | 存的角度 | carriedRotation | handledPhotoIds | 说明 |
| --- | --- | --- | --- | --- | --- |
| 1 | 转A 左90° | A=90 | 90 | {A} | 旋转落盘 A，设惯性，A 入集 |
| 2 | 翻到B（没改） | B=90 | 90 | {A,B} | B 未入集 → 继承惯性落盘，B 入集 |
| 3 | 嫌B歪，右转B回正 | B=0 | 0 | {A,B} | 旋转落盘 B，惯性更新为0（B 已在集） |
| 4 | 翻到C（没改） | C=0 | 0 | {A,B,C} | C 未入集 → 继承新惯性0落盘，C 入集 |
| 5 | 回翻到B | B=0（不动） | 0 | {A,B,C} | B 在集 → 跳过，保持 B=0 |
| 6 | 回翻到A | A=90（不动） | 0 | {A,B,C} | A 在集 → 跳过，保持 A=90 |

**关键性质：**
1. **带过去要落盘**：B 没改也存 90（步骤2），符合「切到下一张时 B 也应是 90」。
2. **预览到哪张哪张才继承**：只有翻到的照片才被惯性带过并落盘，没翻到的不动。
3. **横竖可手动纠正且持久**：B 手动转回 0，存 0，回翻不丢。
4. **回翻不覆盖**：已处理照片回翻时不被惯性再次覆盖，保留用户为每张设定的角度——这是与 B+B1 的核心区别，消除「强行绑定」。
5. **离开分组再进来**：`carriedRotation`/`handledPhotoIds` 重置为空（依赖每次新建 VM），每张显示各自已存角度。

### 取舍（用户已确认）

- **带过去是粗略默认**：惯性把同一角度套到下一张，竖图会被带成横显（步骤2 的 B）。用户可手动纠正且纠正后持久、回翻不丢——这是确认接受的取舍2。
- **写盘**：开始带旋转后，每翻到一张未处理照片多一次 `store.setRotations`（load-mutate-save 整个 analysis.json）。组内照片通常几十张，JSON 小，可接受。
- **与 duplicate 一致性**：duplicate 是「整组一起转」，浏览器是「带过去逐张存 + 已处理不覆盖」——两者都达成「继承旋转状态」，但实现不同（用户明确选本方案）。

---

## 需求 1：浏览器旋转带过去（已处理集合方案）

### 方案

改动文件：`rawViewer/browser/photoBrowserViewModel.swift`（仅此文件）。

**1. 新增状态**

```swift
public private(set) var carriedRotation: Int?  // nil = 尚未开始带旋转
public private(set) var handledPhotoIds: Set<String> = []  // 已处理照片（手动转过或已被惯性带过）
```

> **重置前提**：`carriedRotation`/`handledPhotoIds` 随 viewModel 生命周期重置依赖一个已核实的前提——`appCoordinator.showBrowser` 每次进分组都新建 `photoBrowserViewModel`（`appCoordinator.swift:119`），离开即销毁，状态自然归空。若将来上层改为复用 VM，必须在进入/离开分组时显式清空这两个状态，否则会跨分组串角度。

**2. 旋转 `rotateCurrentPhoto`**

```swift
@discardableResult
public func rotateCurrentPhoto(direction: photoRotationDirection) throws -> Int? {
    guard let photo = currentPhoto else { return nil }
    let base = carriedRotation ?? photo.rotationDegrees
    let newRotation = rotatedDegrees(base, direction: direction)
    try store.setRotations([photo.photoId: newRotation])
    carriedRotation = newRotation
    handledPhotoIds.insert(photo.photoId)
    photos[currentIndex].rotationDegrees = newRotation
    currentRequestId += 1
    return newRotation
}
```

- `base` 优先用 `carriedRotation`（已开始带），否则用当前照片自身角度。
- **先持久化成功再设 `carriedRotation`**：若 `setRotations` 抛错（VC 会弹错），`carriedRotation` 不被设置，不会产生「未持久化却带旋转」的脏状态。
- 当前照片入 `handledPhotoIds`（手动转过的，回翻不再覆盖）。

**3. 新增 `applyCarriedRotationIfNeeded()`**

```swift
private func applyCarriedRotationIfNeeded() {
    guard let carried = carriedRotation else { return }
    guard photos.indices.contains(currentIndex) else { return }
    let photo = photos[currentIndex]
    guard !handledPhotoIds.contains(photo.photoId) else { return }  // 已处理 → 跳过，保留用户设定的角度
    do {
        try store.setRotations([photo.photoId: carried])
        photos[currentIndex].rotationDegrees = carried
        handledPhotoIds.insert(photo.photoId)
    } catch {
        appFileLogger.log("carry rotation failed photoId=\(photo.photoId) rotation=\(carried) error=\(error.localizedDescription)", level: .error)
    }
}
```

- 只在 `carriedRotation` 非 nil 时生效（不旋转直接浏览不破坏已有角度）。
- **已处理照片跳过**（`handledPhotoIds.contains`）——这是回翻不覆盖的关键。
- **失败时的一致性说明**：出错只记日志、不阻断导航，但会出现不一致中间态——`photos[currentIndex].rotationDegrees` 未更新（保持旧值，故显示旧角度），`carriedRotation` 仍为 carried 值，磁盘也未写入，且**该照片未入 `handledPhotoIds`**（落盘失败不算处理完成），下次切换到它会再尝试，可自愈。被切到的照片必来自 store，正常不抛 `missingPhotoIds`。

**4. 在所有「当前照片切换」处调用**

在以下方法改变 `currentIndex` 之后、`currentRequestId += 1` 之前，调用 `applyCarriedRotationIfNeeded()`：

- `movePrevious()`
- `moveNext()`
- `setCurrentIndex(_:)`
- `confirmDelete()` throws（在 `currentIndex` 调整后、`currentRequestId += 1` 之前）
- `restoreNormalTargetsAndUpdateList()` throws（在 `currentIndex` 调整后、`currentRequestId += 1` 之前；注意该方法自身不含「空组」判断，空组判断在 VC 层）

**5. 显示层不改**

`show` 仍读 `currentPhoto.rotationDegrees`（已被 `applyCarriedRotationIfNeeded` 更新为继承值或用户设定值）。`photoBrowserViewController` 无需改动。

### 影响

- 新增 2 个状态 + 1 个 private 方法 + 5 个导航接线点 + 旋转方法扩展。
- 写盘：开始带旋转后，每翻到一张未处理照片多一次 `setRotations`；已处理照片回翻不写盘。
- 仅改 `photoBrowserViewModel.swift`，`photoBrowserViewController` 无需改动。

---

## 需求 2：duplicate 对比页双侧删除按钮

改动文件：`rawViewer/duplicate/duplicateCompareViewController.swift`、`rawViewer/views/photoMetalViewController.swift`。

### 语义约定（务必区分）

- **删除按钮：点哪删哪**。点左删除按钮 → 删左图（调 `keepRight()`）；点右删除按钮 → 删右图（调 `keepLeft()`）。
- **方向键：按哪留哪**（既有逻辑，不改）。← → `keepLeft()`（删右留左），→ → `keepRight()`（删左留右）。
- 二者语义**相反**，但底层都复用 `keepLeft`/`keepRight`，删除后的边界结果（继续比较 / 结束）完全相同。

### 方案

**1. 新增属性**

```swift
private var leftDeleteButton = NSButton(title: "🗑", target: nil, action: nil)
private var rightDeleteButton = NSButton(title: "🗑", target: nil, action: nil)
```

**2. `photoMetalViewController` 暴露图片区顶部锚点**

fileNameBar 高度是动态的（有名字 30、无名字 0），删除按钮若用固定偏移会在「无名字」时悬空。为让按钮始终贴在 fileNameBar 正下方，新增只读锚点：

```swift
public var contentTopAnchor: NSLayoutYAxisAnchor { fileNameBar.bottomAnchor }
```

（仅暴露现有内部约束锚点，不改变任何渲染行为，对其他调用方无影响。）

**3. `loadView` 中创建并布局**

在 `splitView.addArrangedSubview(rightPhotoController.view)` 之后配置两个按钮，加入 `root`，约束在各自图片区左上/右上角（fileNameBar 下方）：

```swift
leftDeleteButton.target = self
leftDeleteButton.action = #selector(deleteLeftClicked)
leftDeleteButton.bezelStyle = .rounded
leftDeleteButton.toolTip = "Delete left photo"
leftDeleteButton.translatesAutoresizingMaskIntoConstraints = false

rightDeleteButton.target = self
rightDeleteButton.action = #selector(deleteRightClicked)
rightDeleteButton.bezelStyle = .rounded
rightDeleteButton.toolTip = "Delete right photo"
rightDeleteButton.translatesAutoresizingMaskIntoConstraints = false

root.addSubview(leftDeleteButton)
root.addSubview(rightDeleteButton)

NSLayoutConstraint.activate([
    leftDeleteButton.topAnchor.constraint(equalTo: leftPhotoController.contentTopAnchor, constant: 8),
    leftDeleteButton.leadingAnchor.constraint(equalTo: leftPhotoController.view.leadingAnchor, constant: 12),
    rightDeleteButton.topAnchor.constraint(equalTo: rightPhotoController.contentTopAnchor, constant: 8),
    rightDeleteButton.trailingAnchor.constraint(equalTo: rightPhotoController.view.trailingAnchor, constant: -12)
])
```

> `contentTopAnchor` 即 fileNameBar.bottomAnchor，无论 fileNameBar 高 30 还是 0，按钮都紧跟其下方 8px，不会悬空。删除按钮在 `splitView` 之后 `addSubview` 到 `root`，层级在图片之上，可见可点。

> **遮挡取舍**：按钮叠在图片左上/右上角内侧，会遮挡图片角落一小块。删除是低频但需直观可达的操作，角落遮挡可接受；禁用态（该侧无照片）按钮灰显。

**4. 动作**

```swift
@objc private func deleteLeftClicked() {
    do {
        let result = try viewModel.keepRight()   // 点左 → 删左留右
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
}

@objc private func deleteRightClicked() {
    do {
        let result = try viewModel.keepLeft()    // 点右 → 删右留左
        handleActionResult(result)
    } catch {
        showErrorAlert(message: error.localizedDescription)
    }
}
```

> 注意 `deleteLeftClicked` 调 `keepRight`、`deleteRightClicked` 调 `keepLeft`——这正是「点哪删哪」与方向键「按哪留哪」相反的体现。**不要**按字面把「删左」对到 `keepLeft`，那会删错方向。

- 复用现有 `keepLeft`/`keepRight` + `handleActionResult`，删除后流转零新增逻辑。

**5. `updateActionButtons` 启用/禁用**

```swift
private func updateActionButtons() {
    let hasLeft = viewModel.mainPhoto != nil
    let hasRight = viewModel.candidatePhoto != nil
    let hasPhoto = hasLeft || hasRight
    rotateLeftButton.isEnabled = hasPhoto
    rotateRightButton.isEnabled = hasPhoto
    leftDeleteButton.isEnabled = hasLeft
    rightDeleteButton.isEnabled = hasRight
}
```

### 边界行为（底层复用 keepLeft/keepRight，与方向键结果相同）

| 场景 | 行为 |
| --- | --- |
| 组内 >2 张，删左图 | 右图前移到左、加载新右图，`.continueComparing` |
| 组内 ==2 张，删一张 | 剩余那张标记 `.kept`、清空 `reviewGroupId` → 归入 Normal，`.finished` → 回分组页 |
| 该侧无照片 | 对应删除按钮禁用 |

### 影响

- `duplicateCompareViewController`：新增 2 个按钮 + 2 个 action + `updateActionButtons` 扩展 + 布局约束。
- `photoMetalViewController`：新增只读 `contentTopAnchor` 锚点（不触碰渲染）。
- 不触碰 `duplicateCompareViewModel`。
- 删除无二次确认（与方向键一致；废纸篓可恢复）。

---

## 涉及文件汇总

| 文件 | 改动 |
| --- | --- |
| `rawViewer/browser/photoBrowserViewModel.swift` | 需求 1：`carriedRotation` + `handledPhotoIds` + `applyCarriedRotationIfNeeded` + 旋转/导航接线 |
| `rawViewer/duplicate/duplicateCompareViewController.swift` | 需求 2：双侧删除按钮 + actions + 启用状态 + 布局 |
| `rawViewer/views/photoMetalViewController.swift` | 需求 2：新增只读 `contentTopAnchor` 锚点（供删除按钮布局） |

## 验证方式

- 不使用测试框架（项目约定）。用 `xcodebuild` Debug 构建确认编译通过。
- 最终手动验证（参照既有 flare 文档的手动验证风格）：
  - 需求 1：进任意分组，转第 1 张 90°，下翻若干张确认都继承 90°（落盘）；中途再转确认后续继承新角度；**回翻到之前翻过的照片确认保持各自已存角度、不被覆盖**；不旋转直接浏览确认不破坏已有角度。
  - 需求 2：duplicate 对比页点左删除按钮确认删左图、点右删除按钮确认删右图（注意与 ←/→ 方向键「留」的方向相反）；边界行为（>2 继续、==2 结束）与方向键一致；某侧无照片时对应按钮禁用。

## 版本号

按项目约定小版本递增并更新文件头 Description：

- `photoBrowserViewModel.swift`：v1.2 → v1.3
- `duplicateCompareViewController.swift`：v3.8 → v3.9
- `photoMetalViewController.swift`：v1.4 → v1.5
