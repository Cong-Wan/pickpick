# pickpick 窗口尺寸回退 BUG 深度分析与收窄修复方案

- Author: wilbur
- Version: 2.0
- Date: 2026-06-24
- Scope: macOS AppKit 窗口尺寸在返回分组卡片页时被重置的问题
- Target file: `appCoordinator.swift`

---

## 1. 问题描述

用户复现现象：

```plain
1. 从分组卡片页进入任意一个分组。
2. 在分组预览/比较页面手动放大应用窗口。
3. 点击 Back 或完成当前分组流程，返回分组卡片页。
4. 窗口尺寸被强制缩回原始尺寸，而不是保持用户放大后的尺寸。
```

用户描述中的关键约束是：

- “任意一个分组”都会触发；
- 问题发生在“从分组退出到分组卡片页”这一瞬间；
- 用户放大的是 macOS 应用窗口，不是图片内部 zoom。

---

## 2. 分析结论

BUG 的直接触发点在 `appCoordinator.swift` 的 `showGroups()`：

```swift
window?.contentViewController = controller
```

返回分组卡片页时，当前实现会重新创建一个新的 `groupGridViewController`，并直接替换 `NSWindow.contentViewController`。在替换前后，代码没有保存并恢复用户当前的 `window.frame`，也没有把新 controller 的 root view 预先设成当前窗口内容区尺寸。

因此，AppKit 在安装新的 content view controller 时，有机会根据新 controller 的 view 当前尺寸 / fitting size / 初始布局状态重新调整窗口内容尺寸，最终表现为窗口回到启动时或原始页面尺寸。

### 最小修复结论

只需要修改：

```plain
appCoordinator.swift
```

只建议先修改：

```swift
public func showGroups()
```

不建议本轮全局替换所有 `window?.contentViewController = ...`，因为当前 BUG 的公共落点就是 `showGroups()`。全局替换虽然可能统一窗口行为，但会影响启动页、进度页、错误页、进入浏览页、进入重复比较页等其它导航路径，修改范围超过当前问题需要。

---

## 3. 成功标准

修复后的行为必须满足：

```plain
场景 A：普通分组返回
1. 启动应用。
2. 选择目录，进入分组卡片页。
3. 进入 Normal / Overexposed / Underexposed / Blurry 任意普通分组。
4. 手动把窗口放大。
5. 点击 Back。
6. 预期：返回分组卡片页后，窗口尺寸保持第 4 步放大后的尺寸。

场景 B：重复分组返回
1. 启动应用。
2. 进入 Duplicate 分组。
3. 手动把窗口放大。
4. 点击 Back。
5. 预期：返回分组卡片页后，窗口尺寸保持第 3 步放大后的尺寸。

场景 C：重复分组完成后自动返回
1. 启动应用。
2. 进入 Duplicate 分组。
3. 手动把窗口放大。
4. 执行操作直到 onFinished 触发并自动返回分组卡片页。
5. 预期：返回分组卡片页后，窗口尺寸保持第 3 步放大后的尺寸。
```

非目标行为：

```plain
1. 本次不改变图片内部缩放逻辑。
2. 本次不改变分组卡片布局算法。
3. 本次不重构整体路由架构。
4. 本次不改变启动页、进度页、错误页的窗口尺寸策略。
```

---

## 4. 我采用的假设

1. 用户说的“窗口放大”指 `NSWindow` 的窗口 frame 被用户手动调整。
2. 用户说的“原始尺寸”高度疑似对应 `mainWindowController.swift` 中初始化窗口时的 `1100 x 760`。
3. 上传的代码中没有工程文件或可执行 UI 测试环境，因此本报告基于静态代码证据、AppKit 窗口行为、调用链推演完成。
4. 没有发现业务代码显式调用 `window.setFrame(...)` 或 `window.setContentSize(...)` 把窗口改回默认尺寸，因此病因不是显式 resize API，而是 controller 替换过程中的窗口尺寸副作用。

---

## 5. 直接证据

### 5.1 初始窗口尺寸只在 `mainWindowController.swift` 中定义

文件：`mainWindowController.swift`

```swift
29        let window = NSWindow(
30            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
31            styleMask: [.titled, .closable, .miniaturizable, .resizable],
32            backing: .buffered,
33            defer: false
34        )
35        window.title = "pickpick"
36        window.minSize = NSSize(width: 760, height: 520)
37        window.center()
```

证据含义：

- `1100 x 760` 是应用启动时的默认窗口尺寸。
- `760 x 520` 是最小窗口尺寸，不是默认尺寸。
- 如果用户看到窗口“回到原始尺寸”，最直接的候选尺寸来源就是这里。

---

### 5.2 搜索结果显示没有显式窗口 resize API

在上传的 Swift 文件中搜索窗口尺寸相关 API，结果中只发现 `contentViewController` 替换和初始化尺寸：

```plain
appCoordinator.swift:43:  window?.contentViewController = progressController
appCoordinator.swift:89:  window?.contentViewController = controller
appCoordinator.swift:104: window?.contentViewController = controller
appCoordinator.swift:130: window?.contentViewController = browser
appCoordinator.swift:152: window?.contentViewController = duplicate
appCoordinator.swift:171: window?.contentViewController = controller
mainWindowController.swift:30: contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760)
mainWindowController.swift:36: window.minSize = NSSize(width: 760, height: 520)
```

没有发现：

```plain
window.setFrame(...)
window.setContentSize(...)
contentMinSize / contentMaxSize 主动约束窗口尺寸
preferredContentSize 参与主动窗口适配
```

证据含义：

- 窗口被缩回并不是某处直接写了 `setFrame(1100, 760)`。
- 高危点集中在 `window.contentViewController` 替换行为。

---

### 5.3 `showGroups()` 是返回分组卡片页的公共落点

文件：`appCoordinator.swift`

```swift
92     public func showGroups() {
93         groups = makeVisiblePhotoGroups(from: records)
94         screenState = .groups
95
96         let viewModel = groupGridViewModel(groups: groups)
97         let controller = groupGridViewController(viewModel: viewModel, imageService: imageService)
98         controller.onBack = { [weak self] in
99             self?.showStart()
100        }
101        controller.onSelectGroup = { [weak self] group in
102            self?.navigateToGroup(group)
103        }
104        window?.contentViewController = controller
105    }
```

证据含义：

- 每次返回分组卡片页都会重新创建 `groupGridViewController`。
- 返回不是恢复旧的分组页 controller，而是新建后安装到 window。
- 第 104 行是窗口尺寸状态可能被 AppKit 重新计算的直接触发点。

---

### 5.4 普通分组 Back 必然进入 `showGroups()`

文件：`photoBrowserViewController.swift`

```swift
297    @objc private func backClicked() {
298        onBack?()
299    }
```

文件：`appCoordinator.swift`

```swift
115    public func showBrowser(group: photoGroup) {
116        screenState = .browser
117        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
118        let viewModel = photoBrowserViewModel(
119            photos: group.photos,
120            store: store,
121            trashService: trashService,
122            displaySource: displaySourceStore().current
123        )
124        let browser = photoBrowserViewController(viewModel: viewModel, imageService: imageService, groupKind: group.kind)
125        browser.onBack = { [weak self] in
126            guard let self else { return }
127            self.reloadDataIgnoringError()
128            self.showGroups()
129        }
130        window?.contentViewController = browser
131    }
```

证据含义：

- 普通分组页点击 Back 后会调用 `onBack`。
- `onBack` 先 reload，然后调用 `showGroups()`。
- 所以普通分组返回时一定走到 `showGroups()` 第 104 行。

---

### 5.5 重复分组 Back 和 Finished 也进入同一个 `showGroups()`

文件：`duplicateCompareViewController.swift`

```swift
297    @objc private func backClicked() {
298        onBack?()
299    }
```

文件：`appCoordinator.swift`

```swift
133    public func showDuplicate(group: photoGroup) {
134        screenState = .duplicateCompare
135        let store = jsonReviewStateStore(folderUrl: currentFolderUrl)
136        let viewModel = duplicateCompareViewModel(photos: group.photos, store: store, trashService: trashService)
137        let duplicate = duplicateCompareViewController(viewModel: viewModel, imageService: imageService)
138        duplicate.onBack = { [weak self] in
139            guard let self else { return }
140            self.reloadDataIgnoringError()
141            self.showGroups()
142        }
143        duplicate.onFinished = { [weak self] in
144            guard let self = self else { return }
145            do {
146                try self.reloadData()
147            } catch {
148                // reloadData 失败时仍尝试 showGroups，用内存中的旧数据
149            }
150            self.showGroups()
151        }
152        window?.contentViewController = duplicate
153    }
```

证据含义：

- 重复分组点击 Back 会调用 `showGroups()`。
- 重复分组完成 `onFinished` 也会调用 `showGroups()`。
- 这解释了为什么用户说“任意一个分组”退出都会发生。

---

### 5.6 分组卡片页自身没有主动改窗口尺寸

文件：`groupGridViewController.swift`

```swift
132    public override func viewDidLayout() {
133        super.viewDidLayout()
134        let width = scrollView.bounds.width
135        let columns = viewModel.columnCount(for: width)
136        if columns != currentColumns {
137            currentColumns = columns
138            let cardWidth = viewModel.cardWidth(for: width)
139            flowLayout.itemSize = NSSize(width: cardWidth, height: 180)
140            collectionView.collectionViewLayout?.invalidateLayout()
141        }
142    }
```

证据含义：

- 分组页只根据 `scrollView.bounds.width` 计算列数与 item 宽度。
- 它没有调用窗口 resize API。
- 它是被动响应当前可用宽度，不是主动把窗口改小的代码。

---

## 6. 根因链路

```plain
用户在分组预览页 / 重复比较页手动放大窗口
↓
点击 Back 或触发 onFinished
↓
photoBrowserViewController.backClicked / duplicateCompareViewController.backClicked
↓
onBack / onFinished closure
↓
appCoordinator.reloadDataIgnoringError() 或 reloadData()
↓
appCoordinator.showGroups()
↓
重新创建 groupGridViewController
↓
直接执行 window?.contentViewController = controller
↓
新 controller 的 root view 以初始尺寸 / fitting size / 当前布局状态参与窗口内容区适配
↓
当前用户手动调整后的 window.frame 没有被保存，也没有被恢复
↓
窗口尺寸回退到原始/默认尺寸
```

---

## 7. 为什么不是其它模块导致

### 7.1 不是 Metal 图片视图导致

问题发生在返回分组卡片页时，且代码搜索没有发现 `metalPhotoView` 或 `photoMetalViewController` 调用 `NSWindow` resize API。图片 zoom 属于视图内部显示状态，不负责修改外层窗口 frame。

### 7.2 不是分组卡片布局导致

`groupGridViewController.viewDidLayout()` 只做 collection item 尺寸计算，输入是当前 `scrollView.bounds.width`，输出是 `flowLayout.itemSize`。它没有窗口层 API。

### 7.3 不是某个分组类型独有逻辑

普通分组与重复分组返回路径都汇入 `showGroups()`，所以 BUG 不应该放在单个分组页面里修。

---

## 8. 修复策略比较

| 方案 | 改动范围 | 是否覆盖当前 BUG | 风险 | 结论 |
|---|---:|---:|---|---|
| 只修 `showGroups()` | 最小 | 是 | 低 | 推荐 |
| 新增统一 `installContentViewController` 并替换所有页面切换 | 中等 | 是 | 会改变其它页面切换行为 | 暂不推荐 |
| 改 `groupGridViewController.viewDidLayout()` | 小 | 不一定 | 修错层级 | 不推荐 |
| 改照片浏览页 Back 逻辑 | 中等 | 只覆盖普通页，不覆盖 duplicate finished | 不完整 | 不推荐 |
| 固定 root container，只替换 child controller | 大 | 是 | 架构改动大 | 长期可考虑，本次不做 |

---

## 9. 推荐修复方案：只保护 `showGroups()`

### 9.1 修改原则

只在 `showGroups()` 安装分组卡片页 controller 时：

1. 保存当前 `window.frame`。
2. 保存当前 `contentView` 的 bounds size。
3. 提前加载新 controller 的 view。
4. 把新 controller 的 view frame 设置为当前 content size。
5. 替换 `contentViewController`。
6. 如果替换过程改变了窗口 frame，则恢复原 frame。
7. full screen 状态下不强制 `setFrame`。

### 9.2 为什么要先设置 `controller.view.frame`

如果直接执行：

```swift
window.contentViewController = controller
```

新 controller 的 root view 可能还处于初始 frame 状态。此时 AppKit 安装内容 controller 时，会使用该 view 的当前尺寸 / fitting size / 约束结果参与内容区尺寸计算。

提前执行：

```swift
controller.loadViewIfNeeded()
controller.view.frame = NSRect(origin: .zero, size: currentContentSize)
```

可以让新分组页 root view 在被安装前就拥有“当前窗口内容区尺寸”，降低 AppKit 把窗口重新适配到默认尺寸的概率。

### 9.3 为什么还要 `setFrame(currentFrame, display: true)`

即使预设了新 view frame，`contentViewController` 替换过程仍可能改变窗口 frame。保存并恢复 `currentFrame` 是兜底措施，确保用户拖拽后的窗口位置和尺寸都被保留。

---

## 10. 完整建议 diff

文件：`appCoordinator.swift`

```diff
diff --git a/appCoordinator.swift b/appCoordinator.swift
--- a/appCoordinator.swift
+++ b/appCoordinator.swift
@@
 /*
 Author: wilbur
-Version: 1.5
-Date: 2026-06-11
-Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC；普通浏览页传递 group kind；持有 trashService 实例并注入到各 ViewModel
+Version: 1.6
+Date: 2026-06-24
+Description: 导航协调器，持有 records/groups 作为全 app 数据单一来源，管理 screenState 状态机，路由分发到各 VC；普通浏览页传递 group kind；持有 trashService 实例并注入到各 ViewModel；v1.6 返回分组页时保留当前窗口 frame，避免 contentViewController 替换导致窗口尺寸回退
 */
@@
     public func showGroups() {
         groups = makeVisiblePhotoGroups(from: records)
         screenState = .groups
 
         let viewModel = groupGridViewModel(groups: groups)
         let controller = groupGridViewController(viewModel: viewModel, imageService: imageService)
         controller.onBack = { [weak self] in
             self?.showStart()
         }
         controller.onSelectGroup = { [weak self] group in
             self?.navigateToGroup(group)
         }
-        window?.contentViewController = controller
+        guard let window else { return }
+        let currentFrame = window.frame
+        let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size
+
+        controller.loadViewIfNeeded()
+        controller.view.frame = NSRect(origin: .zero, size: currentContentSize)
+        window.contentViewController = controller
+
+        if !window.styleMask.contains(.fullScreen), !NSEqualRects(window.frame, currentFrame) {
+            window.setFrame(currentFrame, display: true)
+        }
     }
```

---

## 11. 修复后 `showGroups()` 完整代码

```swift
public func showGroups() {
    groups = makeVisiblePhotoGroups(from: records)
    screenState = .groups

    let viewModel = groupGridViewModel(groups: groups)
    let controller = groupGridViewController(viewModel: viewModel, imageService: imageService)
    controller.onBack = { [weak self] in
        self?.showStart()
    }
    controller.onSelectGroup = { [weak self] group in
        self?.navigateToGroup(group)
    }

    guard let window else { return }
    let currentFrame = window.frame
    let currentContentSize = window.contentView?.bounds.size ?? currentFrame.size

    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(origin: .zero, size: currentContentSize)
    window.contentViewController = controller

    if !window.styleMask.contains(.fullScreen), !NSEqualRects(window.frame, currentFrame) {
        window.setFrame(currentFrame, display: true)
    }
}
```

---

## 12. 影响推演

### 12.1 对普通分组返回的影响

原路径：

```plain
photoBrowserViewController.backClicked
→ onBack
→ reloadDataIgnoringError()
→ showGroups()
→ window?.contentViewController = controller
```

修复后：

```plain
photoBrowserViewController.backClicked
→ onBack
→ reloadDataIgnoringError()
→ showGroups()
→ 保存当前 window.frame
→ 预设 groupGridViewController.view.frame
→ 替换 contentViewController
→ 必要时恢复 window.frame
```

预期结果：窗口不再回退。

### 12.2 对重复分组 Back 的影响

原路径：

```plain
duplicateCompareViewController.backClicked
→ onBack
→ reloadDataIgnoringError()
→ showGroups()
→ window?.contentViewController = controller
```

修复后同样由 `showGroups()` 保护，因此覆盖。

### 12.3 对重复分组 Finished 的影响

原路径：

```plain
duplicateCompareViewController.onFinished
→ reloadData()
→ showGroups()
→ window?.contentViewController = controller
```

修复后同样由 `showGroups()` 保护，因此覆盖。

### 12.4 对启动页的影响

没有影响。

本次不修改：

```swift
showStart()
```

所以返回起始页时仍保持当前代码行为。

### 12.5 对进度页的影响

没有影响。

本次不修改：

```swift
startAnalysis(folderUrl:)
```

所以分析进度页仍保持当前代码行为。

### 12.6 对进入浏览页 / 重复比较页的影响

没有影响。

本次不修改：

```swift
showBrowser(group:)
showDuplicate(group:)
```

因此不会改变进入预览页时的窗口策略。

### 12.7 对 full screen 的影响

修复代码包含：

```swift
if !window.styleMask.contains(.fullScreen), !NSEqualRects(window.frame, currentFrame) {
    window.setFrame(currentFrame, display: true)
}
```

因此 full screen 下不会强行调用 `setFrame`。

---

## 13. 风险评估

### 13.1 风险：`controller.loadViewIfNeeded()` 提前触发布局

风险等级：低。

原因：`showGroups()` 原本马上就会安装 `controller`，安装时也必须加载 view。提前加载只是把加载时机向前移动几行，不会新增页面生命周期路径。

### 13.2 风险：手动设置 `controller.view.frame`

风险等级：低。

原因：`groupGridViewController.loadView()` 中 root view 没有设置 `translatesAutoresizingMaskIntoConstraints = false`，默认 frame/autoresizing 行为适合被设置为窗口 content size。分组页内部子视图通过约束依附 root view，后续 `viewDidLayout()` 会根据 `scrollView.bounds.width` 重新计算卡片列数。

### 13.3 风险：`window.setFrame(currentFrame, display: true)` 造成闪烁

风险等级：低到中。

原因：只有在 `contentViewController` 替换后 frame 真的发生变化时才调用 `setFrame`。如果预设 view frame 已经避免了窗口变化，则不会调用。

### 13.4 风险：窗口当前尺寸小于新页面最小可布局尺寸

风险等级：低。

原因：窗口本身已经有：

```swift
window.minSize = NSSize(width: 760, height: 520)
```

分组卡片页没有发现比这个更大的硬性根约束。

---

## 14. 验证方案

### 14.1 手动验证

```plain
验证 1：普通分组 Back
1. 进入分组卡片页。
2. 进入任意普通分组。
3. 把窗口拖大到明显大于默认尺寸。
4. 点击 Back。
5. 检查窗口尺寸是否保持不变。

验证 2：重复分组 Back
1. 进入 Duplicate 分组。
2. 把窗口拖大。
3. 点击 Back。
4. 检查窗口尺寸是否保持不变。

验证 3：重复分组 Finished
1. 进入 Duplicate 分组。
2. 把窗口拖大。
3. 执行处理直到自动返回分组卡片页。
4. 检查窗口尺寸是否保持不变。

验证 4：窗口位置
1. 把窗口拖到屏幕某个非居中位置。
2. 进入分组再返回。
3. 检查窗口位置是否也保持不变。

验证 5：小窗口边界
1. 把窗口调到接近最小尺寸。
2. 进入分组再返回。
3. 检查不会小于 `760 x 520`，不会出现布局异常。
```

### 14.2 临时日志验证

如果需要证明修复确实压住 frame 变化，可以临时加入日志：

```swift
appDebugLogger.log("showGroups frame before install=\(currentFrame)")
window.contentViewController = controller
appDebugLogger.log("showGroups frame after install=\(window.frame)")

if !window.styleMask.contains(.fullScreen), !NSEqualRects(window.frame, currentFrame) {
    window.setFrame(currentFrame, display: true)
    appDebugLogger.log("showGroups frame restored=\(window.frame)")
}
```

验证完成后删除这些临时日志。不要把调试日志作为最终代码保留，除非你明确希望持续记录这个窗口状态。

### 14.3 建议的断点验证

可以在以下位置加断点：

```plain
appCoordinator.showGroups()
第 1 个断点：进入 showGroups 时，查看 window.frame
第 2 个断点：执行 window.contentViewController = controller 后，查看 window.frame
第 3 个断点：执行 setFrame 后，查看 window.frame
```

如果第 2 个断点看到 frame 从放大尺寸变回默认尺寸，而第 3 个断点恢复成功，即可直接证明病因。

---

## 15. 不建议本轮采用的方案

### 15.1 不建议全局 helper 替换所有页面跳转

上一版思路是新增：

```swift
private func installContentViewController(_ controller: NSViewController)
```

然后替换 `appCoordinator.swift` 中所有：

```swift
window?.contentViewController = ...
```

重新推演后，不建议本轮这样做。

原因：

```plain
1. 当前 BUG 只在返回分组卡片页时发生。
2. 普通分组、重复分组、重复分组完成都汇入 showGroups()。
3. 全局替换会改变 start/progress/browser/duplicate/error 的窗口行为。
4. 这违反“只碰必须碰的代码”的原则。
```

### 15.2 不建议修改 `groupGridViewController.viewDidLayout()`

原因：

```plain
1. 它只负责 collection view item layout。
2. 它没有访问 NSWindow。
3. 修改这里是在错误层级修问题。
```

### 15.3 不建议在 Back 按钮处修

例如在 `photoBrowserViewController.backClicked()` 或 `duplicateCompareViewController.backClicked()` 保存窗口 frame。

原因：

```plain
1. VC 不应该知道外层窗口路由策略。
2. duplicate onFinished 不是 Back 按钮，也会返回 showGroups()。
3. 真正公共落点是 appCoordinator.showGroups()。
```

---

## 16. 长期架构建议

如果后续还出现类似“切换页面导致窗口尺寸异常”的问题，可以考虑建立固定 root container：

```plain
NSWindow.contentViewController = rootContainerController
rootContainerController 内部替换 child controller.view
```

优点：

```plain
1. NSWindow 的生命周期和页面生命周期分离。
2. 页面切换不再反复触碰 window.contentViewController。
3. 用户窗口尺寸天然保持。
```

缺点：

```plain
1. 改动范围较大。
2. 需要统一 child controller add/remove 逻辑。
3. 不适合作为本次 BUG 的最小修复。
```

本次不建议做长期架构改造。

---

## 17. 最终建议

本次建议只改 `appCoordinator.swift` 的 `showGroups()`：

```plain
1. 保存当前 window.frame。
2. 让新的 groupGridViewController.view 先匹配当前 content size。
3. 替换 window.contentViewController。
4. 如果替换导致窗口 frame 变化，则恢复原 frame。
5. full screen 下跳过 setFrame。
```

这套方案满足：

```plain
1. 覆盖普通分组 Back。
2. 覆盖重复分组 Back。
3. 覆盖重复分组 onFinished。
4. 不影响启动页、进度页、错误页、进入浏览页、进入重复比较页。
5. 修改范围最小。
6. 每一行修改都能直接追溯到“返回分组卡片页时窗口尺寸回退”这个 BUG。
```

---

## 18. 外部 API 参考

Apple 官方文档中，`NSWindow.setContentSize(_:)` 的说明指出：设置窗口 content view 尺寸会改变 `NSWindow` 对象本身尺寸；`NSWindow.setFrame(_:display:)` 则用于设置窗口 frame 的 origin 和 size。

参考：

- `NSWindow.setContentSize(_:)`: https://developer.apple.com/documentation/appkit/nswindow/setcontentsize%28_%3A%29
- `NSWindow.setFrame(_:display:)`: https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:)

这些 API 说明支持本报告中的修复策略：如果页面切换过程可能影响窗口 content size，就应在关键切换点显式保留并恢复用户当前的 `window.frame`。
