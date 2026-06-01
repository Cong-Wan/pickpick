# rawViewer macOS App 第一版设计说明

**Author:** wilbur  
**Version:** 1.0  
**Date:** 2026-06-01  
**Description:** macOS App 第一版设计，使用 AppKit 构建界面，通过 Objective-C++ bridge 函数调用 C++ 照片分析流程，并使用 Metal/Core Image 管线显示照片。

## 1. 目标

第一版目标是把当前 C++ 照片分析能力接入 macOS App，并完成基础筛片流程：

1. 用户选择或拖入一个文件夹；
2. App 调用 C++ 分析该文件夹；
3. 分析期间显示极简圆环进度；
4. 分析完成后按结果分组展示；
5. 用户进入任意分组后浏览照片、切换 RAW/JPG 显示源，并删除选中的照片。
6. 用户进入重复组后使用专用双图对比流程，快速选择保留图并删除被淘汰图。

本设计只覆盖当前已确认的第一版范围，不包含重复照片算法实现、复杂筛选、评分、搜索、批量导出等后续功能。

## 2. 已确认假设

- UI 框架使用 AppKit。
- C++ 分析程序不通过命令行二进制调用，而是作为库代码由 App 内部函数调用。
- `cpp/main.cpp` 保留为调试和命令行验证入口。
- App 通过 Objective-C++ `.mm` bridge 调用 C++ `AppRunner`。
- 图片主显示区域第一版就使用 `MTKView + MTLTexture`。
- 图片显示默认使用 JPG。
- `RAW / JPG` 显示源选择是全局浏览偏好，切换后影响后续照片和其他分组，并通过 `UserDefaults` 跨 App 重启保存。
- 删除操作第一版采用移动到系统废纸篓，并在执行前弹出二次确认框。
- 重复组对比流程中被淘汰的照片直接删除，不弹二次确认框。
- App 内所有删除、保留、淘汰操作都必须同步写入 `analysis.json`，避免下次启动时继续加载已不存在的图片路径。

## 3. 软件架构

整体分为三层：

```plain
AppKit UI
  -> Objective-C++ Bridge
    -> C++ Photo Analyzer
  -> Metal/Core Image Photo Viewer
```

### 3.1 C++ 分析层

C++ 侧继续负责：

- 扫描顶层目录；
- RAW 转 JPG；
- 虚焦分析；
- 曝光分析；
- 写入 `<输入文件夹>/.cache/analysis.json`；
- 断点续跑；
- 生成 summary。

App 侧不直接调用命令行程序，而是通过 bridge 调用 `AppRunner::run()` 或后续扩展出的 App 专用入口。

第一版需要给 C++ 流程增加 progress callback，使 UI 能获得：

```plain
阶段：scanning / rawConversion / analysis / organizing / completed
当前数量：completedCount
总数量：totalCount
整体进度：overallProgress，范围 0.0 到 1.0
```

### 3.2 Objective-C++ Bridge

Bridge 负责隔离 Swift/AppKit 和 C++ 类型，避免 UI 直接依赖复杂 C++ 结构。

建议 bridge 暴露：

```plain
startAnalysis(folderPath, progressCallback, completionCallback)
loadAnalysisResult(folderPath)
```

Bridge 内部负责：

- 构造 `RunOptions`；
- 调用 C++ 分析流程；
- 把 C++ 结果转换成 App 可用的 Objective-C/Swift 数据模型；
- 把 C++ 异常转换成 UI 可展示的错误信息；
- 保证回调回到主线程更新 UI。

### 3.3 图片显示层

图片浏览不使用 OpenCV `imread` 作为主显示路径。第一版使用 Apple 图像和 GPU 管线：

```plain
文件路径
  -> ImageIO / Core Image
  -> CIContext(MTLDevice)
  -> MTLTexture
  -> MTKView
```

JPG 显示：

- 读取分析 JSON 中的 `file_path`；
- 使用 ImageIO/Core Image 创建图像；
- 使用 Metal-backed `CIContext` 渲染到 `MTLTexture`；
- `MTKView` 显示 texture。

RAW 显示：

- 优先使用 Core Image RAW 支持读取原始 RAW；
- 如果当前 RAW 格式或相机型号不被 Core Image 支持，则显示错误状态，并允许用户切回 JPG；
- 不在第一版中强行实现所有 RAW 格式兼容。

缩略图显示：

- 左侧缩略图第一版可以异步下采样生成；
- 缩略图需要缓存，避免上下键浏览时重复解码；
- 主图显示仍以 `MTKView` 为准。

## 4. UI 流程

### 4.1 首页

视觉方案选择：宽拖拽区。

首页只有一个核心入口：

- 中央是虚线框；
- 虚线框内有灰色加号；
- 加号下方提示用户可以点击选择文件夹，也可以拖入文件夹；
- 虚线框随窗口变化，但有最小和最大尺寸限制；
- 第一版建议最大尺寸约 `760 x 300`，最小尺寸约 `420 x 230`。

交互：

- 点击虚线框或加号，打开系统文件夹选择面板；
- 拖入文件夹，直接进入分析；
- 拖入非文件夹，显示轻量错误提示。

### 4.2 分析中

视觉方案选择：极简大圆环。

页面中心显示一个大圆环：

- 圆环边缘用蓝色表示已完成进度；
- 圆环中心显示百分比；
- 圆环下方显示当前阶段；
- 当前阶段下方显示当前数量，例如 `36 / 120`。

第一版不显示底部阶段摘要，也不显示右侧调试详情。

阶段文案：

```plain
Scanning folder
Converting RAW
Analyzing photos
Organizing results
Completed
```

### 4.3 结果分组页

视觉方案选择：卡片式分组概览。

分析完成后进入结果页，以卡片展示分组：

- 过曝光；
- 欠曝光；
- 虚焦；
- 正常；
- 重复组。

每张卡片显示：

- 分组名称；
- 照片数量；
- 代表性预览图。

重复组策略：

- 当前 C++ 还未实现重复照片分析；
- 第一版 UI 预留重复组卡片能力；
- 后续 C++ 输出 `duplicateGroupId` 后，App 按 group id 生成多个重复组卡片；
- 如果重复组很多，结果页整体滚动。

### 4.4 照片浏览页

视觉方案选择：顶部工具栏。

普通分组使用通用照片浏览页。普通分组包括：

- 过曝光；
- 欠曝光；
- 虚焦；
- 正常。

页面结构：

```plain
顶部工具栏
  左侧：当前分组名称和数量
  右侧：删除按钮、RAW/JPG segmented control

主体区域
  左侧：缩略图列表
  中间：MTKView 主图显示
```

左侧缩略图列表：

- 竖向列表展示当前组全部照片；
- 每张缩略图左上角有选择框；
- 列表顶部有全选选择框；
- 当前照片有明确选中态；
- 点击缩略图切换主图。

主图区域：

- 默认显示当前组第一张照片；
- 上下键切换上一张和下一张；
- `Backspace` 触发删除当前照片，需要二次确认；
- 主图由 `MTKView` 显示，不使用普通 `NSImageView` 作为第一版主显示控件。

删除：

- 点击顶部删除按钮时，删除已勾选的照片；
- 如果没有勾选照片，则删除当前照片；
- 删除前弹出确认框；
- 确认后移动到系统废纸篓；
- 删除成功后从当前列表移除，并切换到相邻照片。

RAW/JPG 切换：

- 使用 segmented control，而不是普通开关；
- 默认选中 JPG；
- 用户切换 RAW 后，后续照片和其他分组都继续尝试显示 RAW；
- 用户切回 JPG 后，后续全部显示 JPG；
- 偏好写入 `UserDefaults`；
- 当前照片没有 RAW 时，RAW 选项置灰或显示不可用状态；
- 当前偏好为 RAW 但该照片无法显示 RAW 时，页面显示错误状态，并允许切回 JPG。

### 4.5 重复组对比页

重复组不使用通用照片浏览页，而是使用专用双图对比流程。

页面结构：

```plain
顶部工具栏
  左侧：重复组名称和照片数量
  右侧：Keep both 按钮、RAW/JPG segmented control

主体区域
  左侧：当前主图
  右侧：候选图
```

核心规则：

- 左侧永远代表当前主图；
- 右侧代表当前候选图；
- `RAW / JPG` 使用全局显示偏好，行为和普通浏览页一致；
- 用户选择左图时，左图保持不动，右图被淘汰并删除，右侧加载下一张候选图；
- 用户选择右图时，左图被淘汰并删除，右图通过向左移动动画成为新的主图，右侧加载下一张候选图；
- 被淘汰的图片直接删除，不弹出二次确认框；
- 每次选择后必须先更新 `analysis.json` 的 App 操作状态，再移动文件到废纸篓；
- 如果删除文件失败，不能继续加载下一张，需要显示错误并保留当前对比状态。

快捷键：

- 左方向键：保留左图；
- 右方向键：保留右图；
- `R`：切换到 RAW；
- `J`：切换到 JPG。

`Keep both`：

- 表示当前左右两张都保留；
- 点击后弹出模板图选择弹窗；
- 弹窗要求用户选择左图或右图作为该重复组的模板图；
- 弹窗内左方向键选择左图作为模板图；
- 弹窗内右方向键选择右图作为模板图；
- 两张照片都标记为保留，不删除文件；
- 模板图用于结果分组页卡片的代表性预览。

结束条件：

- 当右侧没有下一张候选图时，对比流程结束；
- 如果只剩一张主图，它自动成为该重复组的保留图和模板图；
- 如果存在多张用户选择保留的照片，使用用户最后一次在 `Keep both` 弹窗中选择的模板图作为该组代表图。

## 5. 数据流

### 5.1 分析数据流

```plain
用户选择文件夹
  -> App 进入分析中页面
  -> Bridge 调 C++ AppRunner
  -> C++ 写 .cache/analysis.json
  -> Bridge 持续回传 progress
  -> 分析完成
  -> App 读取 analysis.json
  -> App 构建结果分组
```

### 5.2 浏览数据流

```plain
用户点击分组卡片
  -> App 根据 analysis.json 找到该组照片
  -> 左侧加载缩略图
  -> 主图加载第一张照片
  -> 根据 UserDefaults 决定 JPG 或 RAW
  -> Photo Viewer 生成 MTLTexture
  -> MTKView 显示
```

### 5.3 重复组操作数据流

```plain
用户进入重复组
  -> App 加载该 duplicateGroupId 下 review_status 可见的照片
  -> 左侧显示主图，右侧显示候选图
  -> 用户按左/右方向键或点击按钮
  -> App 更新 analysis.json 中的 review_status
  -> App 将被淘汰照片移动到系统废纸篓
  -> App 加载下一张候选图
```

## 6. 分组规则

第一版 App 侧根据 `analysis.json` 构建分组：

```plain
is_blurry == true
  -> 虚焦

exposure_status == "overexposed"
  -> 过曝光

exposure_status == "underexposed"
  -> 欠曝光

is_blurry == false 且 exposure_status == "normal"
  -> 正常
```

如果同一张照片同时满足多个异常条件，第一版允许它同时出现在多个分组中。例如一张照片既虚焦又过曝光，则同时出现在虚焦和过曝光分组。

重复组后续由 C++ 输出独立字段驱动，不在第一版算法范围内实现。

## 7. App 操作状态

为了避免删除文件后再次打开 App 时 `analysis.json` 仍然指向不存在的图片，第一版需要在 JSON 中增加 App 操作状态字段。C++ 分析结果仍然保留，App 操作只追加或更新与浏览、保留、删除相关的字段。

建议每张照片增加：

```plain
review_status: active / kept / passed / trashed
review_group_id: string
template_photo_id: string
trashed_at: ISO-8601 timestamp or null
```

字段含义：

- `active`：默认状态，照片仍参与普通分组和重复组展示；
- `kept`：用户明确保留，仍参与展示；
- `passed`：用户在重复组中淘汰该照片，App 不再展示；
- `trashed`：文件已移动到废纸篓，App 不再展示；
- `review_group_id`：重复组 id，用于把照片归入同一个重复组；
- `template_photo_id`：重复组代表图 id，主要写在同组照片上，方便结果页展示；
- `trashed_at`：移动到废纸篓的时间。

加载规则：

- 普通分组默认只加载 `review_status` 为 `active` 或 `kept` 的照片；
- 重复组默认只加载 `review_status` 为 `active` 或 `kept` 的照片；
- `passed` 和 `trashed` 不再进入任何可见列表；
- 如果 JSON 指向的文件路径不存在，但 `review_status` 仍是 `active` 或 `kept`，App 显示缺失文件状态，并允许用户从列表移除该记录。

## 8. 错误处理

第一版只处理会影响主流程的错误：

- 文件夹无权限：提示用户重新选择；
- 文件夹内没有支持的照片：返回首页并提示；
- C++ 分析失败：停留在分析页并显示失败原因；
- `analysis.json` 读取失败：提示结果文件损坏或不可读；
- RAW 显示失败：只影响当前主图显示，不影响 JPG 浏览；
- 删除失败：提示失败原因，并保留列表状态。
- 重复组删除失败：停止本次对比推进，保留当前左右图状态，并提示失败原因。

## 9. 验证标准

第一版完成后应满足：

1. 首页可以点击选择文件夹，也可以拖入文件夹；
2. App 通过函数调用启动 C++ 分析，而不是执行命令行二进制；
3. 分析期间 UI 不阻塞，圆环进度能更新；
4. 分析完成后能读取 `.cache/analysis.json` 并显示卡片式分组；
5. 点击任意分组后能进入照片浏览页；
6. 浏览页默认显示第一张 JPG；
7. `RAW / JPG` 偏好能跨照片、跨分组、跨重启持续；
8. 主图区域使用 `MTKView + MTLTexture`；
9. 上下键可以切换照片；
10. `Backspace` 和删除按钮都会弹出二次确认；
11. 删除确认后照片移动到系统废纸篓，并从当前列表移除。
12. 进入重复组后显示双图对比页，而不是通用照片浏览页；
13. 重复组中左方向键保留左图，右方向键保留右图；
14. 重复组 `Keep both` 弹窗支持左右方向键选择模板图；
15. App 删除或淘汰照片后，`analysis.json` 同步更新 `review_status`，下次启动不会继续加载已删除照片。

## 10. 第一版不做

- 不实现重复照片算法；
- 不实现评分、收藏、标签；
- 不实现复杂筛选器；
- 不实现批量导出；
- 不强制支持所有 RAW 相机型号；
- 不把 OpenCV 解码作为主图显示路径；
- 不通过模拟命令行执行 C++ 分析程序。
