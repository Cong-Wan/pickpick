# Photo File Name Header Recipe

Date: 2026-06-17

## 背景

用户希望在照片详情显示区域上方显示文件名，重点是 Duplicate 分组左右双图对比页。已通过视觉伴侣确认采用方案 A：在每个图片显示区域顶部增加独立文件名栏，而不是放入 toolbar 或作为图片浮层角标。

## 已确认需求

1. 普通浏览页在主图显示区域顶部显示当前照片文件名。
2. Duplicate 对比页在左右两个图片显示区域顶部各自显示文件名。
3. 文件名不显示后缀，例如 `DSC_1024.ARW` 显示为 `DSC_1024`。
4. 长文件名单行显示，超出区域用省略号截断。
5. 不挤占顶部 toolbar，避免影响 JPG/RAW、旋转、删除、Keep both 等按钮。
6. 文件名随当前照片变化同步刷新。
7. 文件名显示同一照片的基础名称，不随 JPG/RAW 展示源切换而变化。

## UI 方案

### 普通浏览页

当前结构是：顶部 toolbar + 左侧缩略图列表 + 右侧 `photoMetalViewController` 主图区域。

目标效果：

```text
┌ toolbar ───────────────────────────────┐
├ thumbnails ┬ filename bar: DSC_1024 ───┤
│            │                            │
│            │          photo             │
└────────────┴────────────────────────────┘
```

### Duplicate 对比页

当前结构是：顶部 toolbar + 左右两个 `photoMetalViewController`。

目标效果：

```text
┌ toolbar ───────────────────────────────┐
├ left filename: DSC_1024 ┬ right filename: DSC_1025 ┤
│                         │                          │
│       left photo         │       right photo        │
└─────────────────────────┴──────────────────────────┘
```

## 技术设计

### 推荐实现位置

优先在 `photoMetalViewController` 内部增加文件名栏能力，而不是分别在 Browser 和 Duplicate 外层拼 UI。

原因：

- 普通浏览页和 Duplicate 页都复用 `photoMetalViewController`。
- 文件名栏是图片显示区域的一部分，和图片加载、错误态、reset 生命周期绑定更自然。
- 外层控制器只负责传入当前应显示的名称，避免重复布局代码。

### 拟新增能力

在 `photoMetalViewController` 增加：

- 一个顶部 `NSTextField` 文件名 label。
- 一个顶部半透明/深色背景容器，高度约 30pt。
- 一个公开方法，例如：

```swift
public func setDisplayName(_ name: String?)
```

行为：

- `name` 为空时隐藏文件名栏。
- `name` 非空时显示文件名栏。
- `reset()` 时清空并隐藏，防止旧文件名残留。

### 文件名生成规则

新增一个小的文件名辅助逻辑：

- 输入：`photoItem`。
- 优先使用该照片的稳定基础文件名，不随 JPG/RAW 展示源切换而变化。
- 路径优先级：优先使用 `rawPath`，没有 RAW path 时使用 `jpgPath`。
- 使用 `URL(fileURLWithPath:)` 取 `lastPathComponent`。
- 使用 `deletingPathExtension()` 去除后缀。
- 如果路径解析为空，回退到 `photoId` 去后缀。

### Browser 接入点

在 `photoBrowserViewController` 中：

- 当前照片变化时，给 `mainPhotoController` 设置文件名。
- 无当前照片时，reset 后隐藏文件名。
- JPG/RAW 切换不改变文件名。

### Duplicate 接入点

在 `duplicateCompareViewController` 中：

- `loadPhotos()` 每次刷新左右照片时，分别给左右 `photoMetalViewController` 设置文件名。
- 左侧使用 `viewModel.mainPhoto`。
- 右侧使用 `viewModel.candidatePhoto`。
- 任一侧没有照片时，对应文件名栏隐藏。
- Keep left / Keep right / Keep both / rotate / source change 后现有逻辑会触发 `loadPhotos()`，文件名随之同步。

## 非目标

1. 不显示完整路径。
2. 不显示文件后缀。
3. 不把文件名放进全局 toolbar。
4. 不新增文件名编辑能力。
5. 不改照片分组、删除、保留、旋转、加载策略。

## 验证标准

1. Debug 构建通过：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

2. 普通浏览页切换照片时，顶部文件名同步变化且无后缀。
3. 普通浏览页切换 JPG/RAW 时，文件名保持同一照片基础名称且无后缀。
4. Duplicate 页左右两侧分别显示对应照片文件名且无后缀。
5. Duplicate 页执行 Keep 操作后，剩余/替换照片文件名无残留、无错位。
6. 文件名过长时单行省略，不挤压 toolbar。

## 风险与处理

- 风险：reset 后旧文件名残留。
  - 处理：`photoMetalViewController.reset()` 同时清空文件名。
- 风险：Duplicate 左右照片异步加载时文件名错位。
  - 处理：文件名在 `loadPhotos()` 基于当前 viewModel 同步设置，不依赖异步图片加载结果。
- 风险：文件名栏遮挡图片。
  - 处理：采用固定高度顶部栏，和视觉伴侣确认方案一致；不使用图片浮层角标。
