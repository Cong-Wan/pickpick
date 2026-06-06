# rawViewer 照片浏览与显示设计文档

**Author:** wilbur
**Version:** 1.0
**Date:** 2026-06-03
**Description:** 定义 rawViewer 各页面的详细布局结构、GPU 图片显示方案、进度回调定义、分组卡片叠放效果的数据策略，以及各组件的尺寸约束。

## 1. 设计确认项

### 1.1 界面总览

| 页面 | 用途 | 布局 |
|------|------|------|
| 首页（Start） | App 启动入口 | 中央虚线拖拽区 |
| 分析中（Progress） | C++ 分析进度展示 | 中央大圆环 + 阶段文字 |
| 分组卡片（Groups） | 展示分析结果分组 | 网格卡片，每张卡片叠放 1~3 张预览图 |
| 普通浏览（Browser） | overexposed/underexposed/blurry/normal | 左侧缩略图列表 + 右侧 MTKView 主图 |
| 重复对比（Duplicate） | duplicated 分组双图对比 | 左右等宽双图 |

**界面设计 HTML 参考：**
- 普通浏览页 + 重复对比页布局：`docs/recipe/20260603_photo_viewer_display_recipe/browser-and-duplicate-layout.html`
- 首页 + 进度页 + 分组卡片页布局：`docs/recipe/20260603_photo_viewer_display_recipe/start-progress-groups-layout.html`
- 分组卡片叠放效果：`docs/recipe/20260603_photo_viewer_display_recipe/group-card-stack-effect.html`

### 1.2 尺寸约束（防止窗口缩放变形）

**窗口级约束：**
- 最小窗口：`760 x 520`
- 最大窗口：无硬性上限，但建议内容区不超过 `1800 x 1200`
- 首页拖拽区：`420 x 230`（最小）~ `760 x 300`（最大）

**分组卡片页（Groups）：**
- 卡片容器最小宽度：`200px`
- 卡片容器最大宽度：`320px`
- 卡片最小高度：`140px`
- 卡片最大高度：`200px`
- 叠放图片区域高度：`100px`
- 网格列数：2 列，列间距 `12px`，行间距 `12px`

**普通浏览页（Browser）：**
- 左侧缩略图列表宽度：固定 `150px`（不随窗口缩放变化）
- 缩略图框高度：固定 `56px`
- 缩略图列表顶部全选区高度：固定 `28px`
- 右侧主图区域：填充剩余空间
- 顶部工具栏高度：固定 `29px`

**重复对比页（Duplicate）：**
- 左右两个图片区域：等宽，各 `50%`
- 顶部工具栏高度：固定 `29px`

**图片显示（metalPhotoView）：**
- 图片按等比缩放，居中显示
- 不拉伸、不变形
- 图片小于显示区域时居中，大于时等比缩小

### 1.3 图片显示方案

**metalPhotoView** 已具备 GPU 渲染能力（`MTKView + CIContext + MTLTexture`），需增强以下能力：

1. **JPG 显示**：使用 `CIImage(contentsOf:)` 直接加载 JPG 文件路径
2. **RAW 显示**：使用 Core Image RAW 滤镜读取原始 RAW 文件（`CIFilter(rawImageURL:)`），回退到 JPG 如果 RAW 加载失败
3. **等比缩放 + 居中 + 透明背景**：draw 方法中计算 `scale = min(viewW/imgW, viewH/imgH)`，居中偏移；图片未覆盖区域保持透明（`MTKView` 的 `clearColor` 设为透明），绝不拉伸图片
4. **错误状态**：加载失败时在 view 上叠加 `NSTextField` 显示 "Cannot load image"，不抛异常导致页面崩溃
5. **显示源切换**：全局 `displaySource`（`.jpg` / `.raw`），通过 `UserDefaults` 持久化，切换后即时刷新当前显示
6. **缩放交互**：
   - `Cmd +` / `Cmd -`：放大 / 缩小当前主图（步进 1.2x）
   - `r` 键：重置缩放为 1.0x
   - 触控板双指张开（pinch out）：放大，双指聚拢（pinch in）：缩小
   - 缩放级别范围：`0.1x` ~ `10.0x`
   - 缩放以图片中心为锚点

**RAW → JPG 回退策略：**
- 用户偏好为 RAW 时，先尝试 RAW
- RAW 加载失败 → 自动回退到 JPG（如果该照片有 JPG）
- 回退后在该 metalPhotoView 实例上标记 `rawUnavailable = true`，工具栏 RAW 按钮置灰
- 无 JPG 时显示 "No image available"

---

## 2. 进度回调定义

C++ `AppRunner::run()` 已按阶段计算 `overallProgress`，Swift 侧直接使用，无需额外计算。

### 2.1 阶段映射

| 阶段 | overallProgress 范围 | C++ RunPhase |
|------|----------------------|--------------|
| Scanning folder | 0% → 10% | `Scanning` |
| Converting RAW | 10% → 45% | `RawConversion` |
| Analyzing photos | 45% → 90% | `Analysis` |
| Organizing results | 90% → 98% | `Organizing` |
| Completed | 100% | `Completed` |

### 2.2 回调数据结构

```cpp
struct RunProgress {
    RunPhase phase;        // 当前阶段枚举
    int completedCount;    // 当前阶段已完成数量
    int totalCount;        // 当前阶段总数量
    double overallProgress;// 0.0 ~ 1.0 总进度
};
```

Bridge 已转换为 Swift 可用的 `rwAnalysisProgress`：
- `phase: NSInteger`（0=Scanning, 1=RawConversion, 2=Analysis, 3=Organizing, 4=Completed）
- `completedCount: NSInteger`
- `totalCount: NSInteger`
- `overallProgress: Double`

### 2.3 进度页显示规则

- 圆环填充比例 = `overallProgress * 100`%（四舍五入到整数）
- 圆环中心文字 = 百分比整数（如 "45%"）
- 圆环下方阶段文字 = 按 `phase` 映射到文案：
  - `Scanning` → "Scanning folder"
  - `RawConversion` → "Converting RAW"
  - `Analysis` → "Analyzing photos"
  - `Organizing` → "Organizing results"
  - `Completed` → "Completed"
- 阶段文字下方数量 = `"completedCount / totalCount"`（仅 `RawConversion` 和 `Analysis` 阶段显示，其他阶段隐藏）

---

## 3. 分组卡片叠放效果数据策略

### 3.1 视觉效果

每个分组卡片内展示 1~3 张该分组的预览图，以不同角度和偏移量交错叠放，像"搓开一叠纸"的效果：

- 第 1 张：`rotate(-4deg)`，左上角偏移
- 第 2 张：`rotate(3deg)`，右下偏移
- 第 3 张：`rotate(-1deg)`，继续偏移

图片之间无灰色底层矩形，仅图片本身交错。

### 3.2 数据加载策略

**预览图数据来源：**
- 叠放图片使用 JPG 路径（`photoItem.jpgPath`）
- 不加载 RAW 作为预览图（RAW 解码开销大，且预览只需快速展示）

**加载数量规则：**
- 取该分组前 `min(3, 分组照片数量)` 张照片的 JPG 路径
- 照片数量 ≥ 3：展示 3 张
- 照片数量 = 2：展示 2 张
- 照片数量 = 1：展示 1 张

**加载时机：**
- 进入分组卡片页时，异步加载预览图
- 使用 `NSCollectionView` 或自定义 `NSView` 渲染
- 每张预览图通过 `CIImage(contentsOf:)` 生成缩略图，尺寸限制在 `120x90` 以内，避免大图解码
- 加载失败时显示占位色块（`#2a2a2a`），不阻塞卡片渲染

**卡片文字布局：**
- 叠放图片区域下方显示分组名（左对齐）和数量（右对齐）
- 数量只显示纯数字，不带 "photos" 后缀
- 字体：分组名 `13px semibold`，数量 `11px regular`，颜色跟随系统主题

---

## 4. 普通浏览页详细布局

### 4.1 顶部工具栏

- 左侧：当前分组名称 + 数量（如 "Overexposed · 12"）
- 右侧：
  - `JPG | RAW` segmented control（默认 JPG，RAW 不可用时置灰）
  - 删除按钮（🗑 图标）

### 4.2 左侧缩略图列表

- 宽度固定 `150px`
- 顶部全选 checkbox（`NSButton` checkbox 样式）+ "全选" 文字
- 每个缩略图项：
  - 高度 `56px`，圆角 `4px`
  - 左上角 checkbox（`8px` 边距）
  - 缩略图通过 `CIImage` 下采样生成，尺寸 `150x56` 比例裁剪
  - 当前选中项边框高亮（`var(--accent)` 颜色，2px）
  - 点击缩略图 → 切换右侧主图

### 4.3 右侧主图区域

- 使用 `metalPhotoView` 填充剩余空间
- 根据全局 `displaySource` 加载 JPG 或 RAW
- 图片等比缩放，不足区域透明，绝不拉伸
- 键盘快捷键：
  - `↑ / ↓`：切换上一张/下一张照片（循环到边界停止）
  - `Backspace`：删除当前照片（弹出二次确认框）

### 4.4 删除逻辑

- 有勾选照片 → 删除所有勾选照片
- 无勾选照片 → 删除当前显示照片
- 删除前弹出 `NSAlert` 二次确认
- 确认后：
  1. 调用 `jsonReviewStateStore.mark(photoId, .trashed)`
  2. 调用 `NSWorkspace.shared.recycle([url])` 移动到废纸篓
  3. 从列表移除对应照片
  4. 自动切换到相邻照片

---

## 5. 重复对比页详细布局

### 5.1 顶部工具栏

- 左侧：重复组名称 + 数量（如 "Duplicate G7 · 5"）
- 右侧：
  - `Keep both` 按钮（蓝色高亮样式）
  - `JPG | RAW` segmented control

### 5.2 主体区域

- 左右等宽（各 `50%`），无边框分隔线
- 左侧：`metalPhotoView` 显示 `mainPhoto`
- 右侧：`metalPhotoView` 显示 `candidatePhoto`
- 两张图各自独立等比缩放 + 居中

### 5.3 操作逻辑

- `←` 方向键 / "Keep Left" 按钮：保留左图，淘汰右图
  - 右图标记 `trashed`，移入废纸篓
  - 右侧加载下一张候选图
- `→` 方向键 / "Keep Right" 按钮：保留右图，淘汰左图
  - 左图标记 `trashed`，移入废纸篓
  - 右图左滑成为新的主图，右侧加载下一张候选图
- `Keep both` 按钮：两张都保留，弹出模板图选择弹窗
  - 弹窗中 `←` 选左图为模板，`→` 选右图为模板
  - 两张都标记 `kept`，写入 `templatePhotoId`

### 5.4 结束条件

- 只剩一张图时：自动标记为 `kept`，自动成为模板图
- 无候选图时：对比流程结束，返回分组卡片页

---

## 6. 首页布局

### 6.1 中央虚线拖拽区

- 虚线边框（`2px dashed var(--border)`）
- 圆角 `12px`
- 内部：大号加号（`48px`）+ 提示文字
- 文字："点击选择文件夹" / "或拖入文件夹"

### 6.2 交互

- 点击 → 打开 `NSOpenPanel`，选择文件夹
- 拖入文件夹 → 直接进入分析
- 拖入非文件夹 → 显示轻量错误提示（红色 toast）

---

## 7. 现有代码改动清单

### 7.1 需要修改的文件

| 文件 | 改动内容 |
|------|---------|
| `metalPhotoView.swift` | 增加 RAW 加载能力、显示源切换、错误状态显示、等比缩放 |
| `photoBrowserViewController.swift` | 实现完整浏览页：工具栏、缩略图列表、主图、删除逻辑 |
| `duplicateCompareViewController.swift` | 实现双图对比页：左右图、操作按钮、键盘事件 |
| `groupGridViewController.swift` | 改为网格卡片布局，实现叠放预览图 |
| `mainWindowController.swift` | 无改动，已有正确的页面路由 |

### 7.2 新增文件（如需）

| 文件 | 用途 |
|------|------|
| `photoThumbnailCell.swift` | 缩略图列表的自定义 NSCollectionViewItem |
| `groupCardView.swift` | 分组卡片的自定义 NSView（含叠放效果） |
| `keepBothSheet.swift` | Keep both 模板图选择弹窗 |

---

## 8. 验证标准

1. 首页拖拽区正常显示，点击/拖入文件夹进入分析
2. 分析中圆环进度随 C++ 回调实时更新
3. 分析完成后显示分组卡片，卡片有叠放预览图效果
4. 点击普通分组进入浏览页：左侧缩略图 + 右侧主图
5. 缩略图有 checkbox，顶部有全选 checkbox
6. 点击重复分组进入双图对比页
7. 左右方向键可执行 keepLeft/keepRight 操作
8. 主图使用 Metal 渲染，JPG/RAW 切换正常，图片等比缩放不拉伸
9. Cmd +/- 可缩放主图，r 键重置缩放，触控板 pinch 手势可缩放
10. 删除操作有二次确认，文件移入废纸篓，JSON 同步更新
11. 窗口缩放时各组件不变形，保持最小尺寸约束
