# rawViewer App 架构 — 逻辑与数据流图

> 所有节点均对应实际代码，非推测。采用总-分结构。

---

## 一、总览：App 架构全景图

> 设计原则：**从上往下，三层递进**：启动链 → 状态/屏幕主轴 → 数据层。
> 主流程用**实线**，数据流用**虚线**，返回线明确标注 `onBack`。

```mermaid
flowchart TD
    subgraph 启动["🚀 1. 启动"]
        direction TB
        MAIN["main.swift<br/>app.run()"]
        DELEGATE["appDelegate<br/>applicationDidFinishLaunching"]
        MWC["mainWindowController<br/>创建 NSWindow + showStart()"]
    end

    subgraph 状态与屏幕["📱 2. 状态与屏幕（竖向主轴）"]
        direction TB

        START["▣ .start<br/>startViewController<br/>点击选择文件夹 (NSOpenPanel)"]

        PROGRESS["▣ .progress<br/>progressViewController<br/>分析进度指示"]

        GROUPS["▣ .groups<br/>groupGridViewController<br/>分组卡片网格"]

        subgraph 浏览分支["展开浏览（横向二选一）"]
            direction LR
            BROWSER["▣ .browser<br/>photoBrowserViewController<br/>单组照片浏览"]
            DUP["▣ .duplicateCompare<br/>duplicateCompareViewController<br/>重复照片对比"]
        end

        ERROR["▣ .error(msg)<br/>错误文本页"]
    end

    subgraph 数据["📦 3. 数据层"]
        direction TB

        ANALYZER["photoAnalyzerBridge<br/>ObjC++ 桥接"]

        subgraph 分析结果["分析结果"]
            direction TB
            JSON[".cache/analysis.json"]
            RECORDS["[photoItem]"]
            GROUPS_DATA["[photoGroup]"]
        end

        subgraph 持久化与缓存["持久化与缓存"]
            direction TB
            STORE["jsonReviewStateStore<br/>review 状态"]
            IMG_SVC["photoImageService"]
            IMG_CACHE["photoImageCache"]
            DS_STORE["displaySourceStore<br/>JPG/RAW 偏好"]
        end
    end

    %% ===== 主流程（实线） =====
    MAIN --> DELEGATE --> MWC --> START
    START -->|"onFolderSelected(url)"| PROGRESS

    PROGRESS -->|分析完成<br/>或读取缓存| GROUPS
    PROGRESS -->|catch error| ERROR

    GROUPS -->|onSelectGroup<br/>非 duplicate| BROWSER
    GROUPS -->|onSelectGroup<br/>是 duplicate| DUP

    BROWSER -->|onBack| GROUPS
    DUP -->|onBack /<br/>onFinished| GROUPS

    %% ===== 数据流（虚线） =====
    START -.->|folderUrl| ANALYZER

    ANALYZER -.->|读取/写入| JSON
    ANALYZER -.->|rwPhotoRecord → photoItem| RECORDS
    RECORDS -.->|makeVisiblePhotoGroups| GROUPS_DATA
    GROUPS_DATA -.->|构造 viewModel| GROUPS

    GROUPS -.->|group.photos| BROWSER
    GROUPS -.->|group.photos| DUP

    BROWSER -.->|"delete<br/>(mark .trashed)"| STORE
    DUP -.->|keepLeft /<br/>keepRight /<br/>keepBoth| STORE
    STORE -.->|updateJson<br/>写回| JSON

    BROWSER -.->|preloadDisplayPair| IMG_SVC
    DUP -.->|preloadDisplayPair| IMG_SVC
    IMG_SVC -.->|内部依赖| IMG_CACHE

    BROWSER -.->|读取偏好| DS_STORE
    DUP -.->|读写偏好| DS_STORE
```

---

## 二、分图

### 2.1 启动流程

```mermaid
sequenceDiagram
    participant Main as main.swift
    participant Del as appDelegate
    participant MWC as mainWindowController
    participant Win as NSWindow
    participant SVC as startViewController

    Note over Main: let app = NSApplication.shared<br/>app.setActivationPolicy(.regular)<br/>let delegate = appDelegate()<br/>app.delegate = delegate<br/>app.run()
    Main->>Del: applicationDidFinishLaunching(_:)
    Note over Del: let controller = mainWindowController()<br/>mainController = controller
    Del->>MWC: init() → convenience init(analyzer:) → init(window:)
    Note over MWC: 创建 NSWindow(1100×760)<br/>window.title = "rawViewer"<br/>window.minSize = (760, 520)<br/>window.center()<br/>self.init(window: window)  ← designated init<br/>showStart()
    MWC->>MWC: showStart()
    Note over MWC: navigationViewModel.showStart()<br/>applyScreenState()<br/>controller = startViewController()<br/>controller.onFolderSelected = { url in<br/>  self?.startAnalysis(folderUrl: url)<br/>}<br/>window.contentViewController = controller<br/>window.makeKeyAndOrderFront(nil)
    MWC->>Win: contentViewController = startViewController
    MWC->>Win: makeKeyAndOrderFront(nil)
    Del->>MWC: showWindow(self)
    Note over Del: NSApp.activate(ignoringOtherApps: true)
```

**对应代码：**

| 步骤 | 文件 | 关键代码 |
|------|------|----------|
| 入口 | `main.swift` | `let app = NSApplication.shared` / `app.run()` |
| 代理回调 | `appDelegate.swift:13` | `func applicationDidFinishLaunching(_:)` |
| 窗口创建 | `mainWindowController.swift:42-54` | `convenience init(analyzer:)` 创建 NSWindow，调用 designated init |
| 首屏展示 | `mainWindowController.swift:68-78` | `showStart()` 设置 startViewController |
| 启动完成 | `appDelegate.swift:24-25` | `controller.showWindow(self)` / `NSApp.activate(...)` |

---

### 2.2 导航状态 (windowScreenState)

> **注意：** `appNavigationViewModel` 与 `mainWindowController` 各自持有相同的 `screenState`、`records`、`selectedGroup`、`currentFolderUrl`，存在状态冗余。实际导航由 `mainWindowController` 驱动——它先调用 `navigationViewModel.xxx()` 更新状态，再通过 `applyScreenState()` 把 `screenState` 同步回自身。`navigationViewModel` 中存储的 `records`/`groups`/`selectedGroup`/`currentFolderUrl` 在 `mainWindowController` 中基本未被读取。

> **注意：** `appNavigationViewModel` 中的 `backToStart()` 和 `backToGroups()` 方法从未被 `mainWindowController` 调用。实际的回退导航由 `mainWindowController` 直接调用自身的 `showStart()` / `showGroups(records:)` 方法驱动。

```mermaid
stateDiagram-v2
    [*] --> start : init()

    start --> progress : startAnalysis(folderUrl)
    progress --> groups : showGroups(records)
    progress --> error : showError(message)
    groups --> browser : openGroup(group) !isDuplicate
    groups --> duplicateCompare : openGroup(group) isDuplicate
    groups --> start : showStart() (onBack)
    browser --> groups : showGroups(records) (onBack)
    duplicateCompare --> groups : showGroups(records) (onBack / onFinished)

    state start {
        [*] --> 清空状态
        note right of 清空状态
          selectedGroup = nil
          records = []
          groups = []
          currentFolderUrl = nil
        end note
    }

    state progress {
        [*] --> 保存folderUrl
        note right of 保存folderUrl
          currentFolderUrl = folderUrl
          selectedGroup = nil
          screenState = .progress
        end note
    }

    state groups {
        [*] --> 构建分组
        note right of 构建分组
          records = newRecords
          groups = makeVisiblePhotoGroups(from:)
          selectedGroup = nil
          screenState = .groups
        end note
    }

    state browser {
        [*] --> 打开浏览器
        note right of 打开浏览器
          selectedGroup = group
          screenState = .browser
        end note
    }

    state duplicateCompare {
        [*] --> 打开对比
        note right of 打开对比
          selectedGroup = group
          screenState = .duplicateCompare
        end note
    }
```

**对应代码：**

| 状态转换 | 实际调用的 ViewModel 方法 | 文件 |
|----------|------|------|
| `→ .start` | `showStart()` | `appNavigationViewModel.swift:23-29` |
| `start → .progress` | `startAnalysis(folderUrl:)` | `appNavigationViewModel.swift:31-35` |
| `.progress → .groups` | `showGroups(records:)` | `appNavigationViewModel.swift:37-42` |
| `.groups → .browser` | `openGroup(_:)` 非 duplicate | `appNavigationViewModel.swift:44-47` |
| `.groups → .duplicateCompare` | `openGroup(_:)` 是 duplicate | `appNavigationViewModel.swift:44-47` |
| `.groups → .start` | `showStart()`（由 onBack 回调触发） | `appNavigationViewModel.swift:23-29` |
| `.browser → .groups` | `showGroups(records:)`（由 onBack 回调触发） | `appNavigationViewModel.swift:37-42` |
| `.duplicateCompare → .groups` | `showGroups(records:)`（由 onBack/onFinished 回调触发） | `appNavigationViewModel.swift:37-42` |
| `* → .error` | `showError(message:)` | `appNavigationViewModel.swift:64-66` |

---

### 2.3 mainWindowController 屏幕切换逻辑

```mermaid
flowchart TD
    A["showStart()"] -->|"创建 startViewController"| A1["controller.onFolderSelected = { url in<br/>  self?.startAnalysis(folderUrl: url)<br/>}"]
    A1 --> A2["window.contentViewController = controller<br/>window.makeKeyAndOrderFront(nil)"]

    B["startAnalysis(folderUrl:)"] --> B0["navigationViewModel.startAnalysis(folderUrl:)"]
    B0 --> B0a["applyScreenState()"]
    B0a --> B1["window.contentViewController = progressViewController()"]
    B1 --> B2{"缓存 .cache/analysis.json<br/>存在？"}
    B2 -->|"是"| B3["analyzer.loadAnalysisResult(folderUrl:)"]
    B2 -->|"否"| B4["analyzer.startAnalysis(folderUrl:configUrl:progress:)"]
    B4 --> B5["progressController.update(progress:)<br/>← 回调更新 UI"]
    B4 --> B3
    B3 --> B6["showGroups(records:)"]
    B3 -->|"catch"| B7["showError(message:)"]
    B4 -->|"catch"| B7

    C["showGroups(records:)"] --> C0["navigationViewModel.showGroups(records:)"]
    C0 --> C0a["applyScreenState()"]
    C0a --> C1["viewModel = groupGridViewModel(groups:)"]
    C1 --> C2["controller = groupGridViewController(viewModel:imageService:)"]
    C2 --> C3["controller.onBack = { self?.showStart() }"]
    C2 --> C4["controller.onSelectGroup = { group in<br/>  self?.showGroup(group: group)<br/>}"]
    C4 --> C5["window.contentViewController = controller"]

    D["showGroup(group:)"] --> D0["navigationViewModel.openGroup(group)"]
    D0 --> D0a["applyScreenState()"]
    D0a --> D1{"group.kind.isDuplicate？"}
    D1 -->|"是"| D2["duplicateCompareViewModel(photos:store:)"]
    D2 --> D3["duplicateCompareViewController(viewModel:imageService:)"]
    D3 --> D4["onBack/onFinished = {<br/>  self.showGroups(records: self.records)<br/>}"]
    D1 -->|"否"| D5["photoBrowserViewModel(photos:store:displaySource:)"]
    D5 --> D6["photoBrowserViewController(viewModel:imageService:)"]
    D6 --> D7["onBack = {<br/>  self.showGroups(records: self.records)<br/>}"]
    D4 --> D8["window.contentViewController = ..."]
    D7 --> D8

    E["showError(message:)"] --> E0["navigationViewModel.showError(message:)"]
    E0 --> E0a["applyScreenState()"]
    E0a --> E1["setContent(title: message)<br/>→ 创建 NSViewController + 居中 label"]
```

**对应代码：**

| 方法 | 文件:行 | 核心逻辑 |
|------|---------|----------|
| `showStart()` | `mainWindowController.swift:68-78` | 创建 startViewController，绑定 onFolderSelected |
| `startAnalysis(folderUrl:)` | `mainWindowController.swift:80-100` | 检查缓存 → 异步分析 → showGroups / showError |
| `showGroups(records:)` | `mainWindowController.swift:102-115` | 构建 groupGridViewModel → groupGridViewController |
| `showGroup(group:)` | `mainWindowController.swift:117-145` | 按 isDuplicate 分流到 browser 或 duplicateCompare |
| `showError(message:)` | `mainWindowController.swift:147-151` | 简单文本页 |

---

### 2.4 数据流：从文件夹到 UI

```mermaid
flowchart LR
    subgraph 输入["📂 输入"]
        FOLDER["folderUrl<br/>(用户点击选择)"]
    end

    subgraph 分析["⚙️ 分析层"]
        CACHE_CHECK{"FileExists<br/>.cache/analysis.json"}
        LOAD["analyzer.loadAnalysisResult(folderUrl:)"]
        ANALYZE["analyzer.startAnalysis(folderUrl:configUrl:)<br/>→ async Task"]
        PROGRESS_CB["progress(progress)<br/>→ progressViewController.update()"]
    end

    subgraph 转换["🔄 模型转换"]
        OBJC["rwPhotoRecord (ObjC++)"]
        ITEM["photoItem (Swift)"]
        FILTER["filter: reviewStatus != .passed/.trashed"]
        GROUP["makeVisiblePhotoGroups(from:)"]
    end

    subgraph 分组["📊 分组结果"]
        G_OVER["photoGroup(.overexposed)"]
        G_UNDER["photoGroup(.underexposed)"]
        G_BLUR["photoGroup(.blurry)"]
        G_NORM["photoGroup(.normal)"]
        G_DUP["photoGroup(.duplicate(id))"]
    end

    subgraph 展示["🖥️ UI 展示"]
        GRID["groupGridViewController<br/>→ groupCardView × N"]
        BROWSER["photoBrowserViewController<br/>→ metalPhotoView + thumbnailView"]
        DUP_VC["duplicateCompareViewController<br/>→ leftPhotoView + rightPhotoView"]
    end

    subgraph 持久化["💾 持久化"]
        JSON_FILE[".cache/analysis.json"]
        REVIEW_STORE["jsonReviewStateStore<br/>mark(photoId:status:)<br/>setTemplate(reviewGroupId:templatePhotoId:)"]
    end

    FOLDER -->|"startAnalysis"| CACHE_CHECK
    CACHE_CHECK -->|"存在"| LOAD
    CACHE_CHECK -->|"不存在"| ANALYZE
    ANALYZE -->|"进度回调"| PROGRESS_CB
    ANALYZE -->|"完成"| LOAD
    ANALYZE -->|"写入"| JSON_FILE
    LOAD -->|"读取"| JSON_FILE
    LOAD --> OBJC
    OBJC -->|"photoAnalyzerBridge.swift: map"| ITEM
    ITEM --> FILTER
    FILTER --> GROUP
    GROUP --> G_OVER & G_UNDER & G_BLUR & G_NORM & G_DUP
    G_OVER & G_UNDER & G_BLUR & G_NORM & G_DUP -->|"groupGridViewModel"| GRID
    GRID -->|"onSelectGroup<br/>!isDuplicate"| BROWSER
    GRID -->|"onSelectGroup<br/>isDuplicate"| DUP_VC

    BROWSER -->|"delete (mark .trashed)"| REVIEW_STORE
    DUP_VC -->|"keepLeft / keepRight / keepBoth"| REVIEW_STORE
    REVIEW_STORE -->|"updateJson → 写回"| JSON_FILE
```

**对应代码：**

| 环节 | 文件 | 关键代码 |
|------|------|----------|
| 缓存检查 | `mainWindowController.swift:88` | `FileManager.default.fileExists(atPath: .cache/analysis.json)` |
| 异步分析 | `photoAnalyzerBridge.swift:16-43` | `withCheckedThrowingContinuation` 包装 ObjC++ callback |
| 模型转换 | `photoAnalyzerBridge.swift:45-62` | `rwPhotoRecord → photoItem` map |
| 分组构建 | `photoModels.swift:111-126` | `makeVisiblePhotoGroups(from:)` |
| 分组过滤 | `photoModels.swift:112` | `filter { reviewStatus != .passed && != .trashed }` |
| 状态持久化 | `jsonReviewStateStore.swift:25-44` | `mark(photoId:status:)` / `setTemplate(...)` |
| JSON 读写 | `jsonReviewStateStore.swift:48-56` | `updateJson(_:)` 读取 → mutate → 原子写回 |

---

### 2.5 回调链与闭包绑定关系

```mermaid
flowchart TD
    subgraph startVC["startViewController 回调"]
        CB1["onFolderSelected: (URL) -> Void"]
    end

    subgraph groupsVC["groupGridViewController 回调"]
        CB2["onBack: () -> Void"]
        CB3["onSelectGroup: (photoGroup) -> Void"]
    end

    subgraph browserVC["photoBrowserViewController 回调"]
        CB4["onBack: () -> Void"]
    end

    subgraph dupVC["duplicateCompareViewController 回调"]
        CB5["onBack: () -> Void"]
        CB6["onFinished: () -> Void"]
    end

    subgraph mwc["mainWindowController 绑定"]
        B1["onFolderSelected → startAnalysis(folderUrl:)"]
        B2["onBack → showStart()"]
        B3["onSelectGroup → showGroup(group:)"]
        B4["onBack → showGroups(records: self.records)"]
        B5["onBack → showGroups(records: self.records)"]
        B6["onFinished → showGroups(records: self.records)"]
    end

    CB1 --> B1
    CB2 --> B2
    CB3 --> B3
    CB4 --> B4
    CB5 --> B5
    CB6 --> B6
```

**对应代码：**

| 绑定 | 文件:行 |
|------|---------|
| `onFolderSelected → startAnalysis` | `mainWindowController.swift:72-74` |
| `groups.onBack → showStart` | `mainWindowController.swift:108-110` |
| `groups.onSelectGroup → showGroup` | `mainWindowController.swift:111-113` |
| `browser.onBack → showGroups` | `mainWindowController.swift:139-142` |
| `duplicate.onBack → showGroups` | `mainWindowController.swift:125-128` |
| `duplicate.onFinished → showGroups` | `mainWindowController.swift:129-132` |

---

### 2.6 windowScreenState 状态枚举与冗余同步机制

> **问题：** `mainWindowController` 和 `appNavigationViewModel` 各自持有 `screenState`，形成"先写 ViewModel → 再同步回 Controller"的冗余链路。`navigationViewModel` 中的 `records`/`groups`/`selectedGroup`/`currentFolderUrl` 与 `mainWindowController` 的同名属性重复存储，且后者几乎不读取前者的这些值。

```mermaid
flowchart LR
    subgraph enumDef["windowScreenState 定义"]
        E1[".start"]
        E2[".progress"]
        E3[".groups"]
        E4[".browser"]
        E5[".duplicateCompare"]
        E6[".error(String)"]
    end

    subgraph sync["冗余同步机制"]
        NVM["appNavigationViewModel.screenState"]
        APPLY["applyScreenState():<br/>screenState = navigationViewModel.screenState"]
        MWC_STATE["mainWindowController.screenState"]
    end

    NVM -->|"每次 showXxx() 后<br/>调用 applyScreenState()"| MWC_STATE

    enumDef -.->|"定义于<br/>mainWindowController.swift:14-21"| E1 & E2 & E3 & E4 & E5 & E6
```

**对应代码：**

| 项 | 文件:行 |
|----|---------|
| 枚举定义 | `mainWindowController.swift:14-21` |
| ViewModel 中的 screenState | `appNavigationViewModel.swift:15` |
| Controller 中的 screenState | `mainWindowController.swift:24` |
| 同步方法 | `mainWindowController.swift:153-155` — `applyScreenState()` |
| 冗余属性对比 | `mainWindowController.swift:24-27` vs `appNavigationViewModel.swift:15-19` |
