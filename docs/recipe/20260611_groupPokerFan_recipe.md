# 分组缩略图扑克牌散开展示 Recipe

## 背景

当前分组展示页的卡片预览图只展示前 3 张缩略图，并通过固定偏移简单叠放。视觉效果偏平、拥挤，不像一组照片的聚合预览。

目标是把分组卡片上方的缩略图区域改成“扑克牌散开”效果：最多展示 5 张，从同一个中心点向左右展开，使用用户确认的 B 方案：宽扇形。

## 已确认决策

- 实现方案：方案 1，在现有 `groupCardView` 内直接改造。
- 视觉方案：B，宽扇形。
- 展示数量：每个分组最多展示 5 张缩略图。
- 行为边界：保留现有网格、点击进入分组、异步缩略图加载和复用清理逻辑。

## 成功标准

1. 分组卡片最多展示 5 张缩略图。
2. 5 张时呈明显的宽扇形扑克牌展开效果。
3. 少于 5 张时按实际数量居中对称展示，不显示空占位。
4. 分组标题和数量仍然可见。
5. 点击分组仍然进入原有详情页面。
6. 缩略图加载失败时保留占位背景，不影响其它卡片或点击。
7. Swift 编译通过。

## 范围

### 包含

- 修改 `rawViewer/views/groupCardView.swift` 的预览图布局。
- 修改 `rawViewer/views/groupCollectionViewItem.swift`，将预览照片数量从 3 张改为 5 张。
- 同步修改 `rawViewer/groupGrid/groupGridViewModel.swift` 的 `previewPhotos(for:)`，避免未来调用时仍返回 3 张。

### 不包含

- 不重构整个分组网格页。
- 不修改分组生成逻辑。
- 不修改缩略图加载服务。
- 不新增动画。
- 不新增配置项。

## 视觉设计

分组卡片保持现有整体结构：上方缩略图预览区域，下方标题和数量。

缩略图改为卡牌式展示：

- 每张图使用圆角。
- 每张图保留浅色边框。
- 每张图添加阴影，增强层级感。
- 所有卡牌围绕同一个下方中心点旋转，形成扑克牌散开效果。
- 5 张时使用最宽展开，形成用户确认的 B 方案。

建议布局参数：

| 数量 | 旋转角度 |
| --- | --- |
| 1 | `0°` |
| 2 | `-12° / 12°` |
| 3 | `-18° / 0° / 18°` |
| 4 | `-24° / -8° / 8° / 24°` |
| 5 | `-24° / -12° / 0° / 12° / 24°` |

位移应与角度保持左右对称。数量越多，水平展开越宽；5 张时最接近视觉伴侣中的 B 方案。

## 组件设计

### `groupCollectionViewItem`

职责保持不变：创建并承载 `groupCardView`。

需要把：

```swift
let previewPhotos = Array(group.photos.prefix(3))
```

改为：

```swift
let previewPhotos = Array(group.photos.prefix(5))
```

### `groupCardView`

职责保持不变：渲染单个分组卡片。

需要调整：

- 最多创建 5 个 `NSImageView`。
- 使用私有布局函数根据 `previewPhotos.count` 返回布局参数。
- 布局参数包含：旋转角度、水平偏移、垂直偏移、层级顺序。
- 继续使用 `imageService.loadThumbnail(for:maxWidth:maxHeight:)` 加载降采样缩略图。
- 缩略图加载失败时保留已有深灰占位背景。

建议新增私有数据结构或元组，例如：

```swift
private struct fanCardLayout {
    let rotationDegrees: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    let zPosition: CGFloat
}
```

如果为减少代码，也可以直接使用元组。优先保持实现简单。

### `groupGridViewModel`

`previewPhotos(for:)` 当前返回前 3 张。虽然当前渲染路径没有使用它，但为了避免同一概念出现两个不同限制，应同步改为前 5 张。

## 数据流

1. `groupGridViewController` 从 `viewModel.groups[indexPath.item]` 获取当前分组。
2. `groupGridViewController` 调用 `groupCollectionViewItem.configure(with:imageService:)`。
3. `groupCollectionViewItem` 从分组中取前 5 张照片作为 `previewPhotos`。
4. `groupCardView` 根据 `previewPhotos.count` 创建缩略图视图。
5. `groupCardView` 根据宽扇形布局表设置每张缩略图的位置、旋转和层级。
6. `groupCardView` 异步加载每张缩略图。

## 错误处理

- 缩略图加载失败：保留深灰占位，不中断其它任务。
- 照片数量为 0：继续依赖 `visibleGroupCards` 过滤空组。
- 照片数量超过 5：只展示前 5 张，数量标签仍显示完整分组数量。
- 卡片复用：继续依赖 `prepareForReuse()` 移除旧卡片，旧卡片 `deinit` 取消加载任务。

## 验证计划

### 编译验证

- 使用 Xcode 或 `xcodebuild` 编译项目，确认 Swift 编译通过。

### 人工视觉验证

打开分组页，检查：

1. 1 张照片的分组：单张居中。
2. 2 张照片的分组：左右轻微展开。
3. 3 张照片的分组：左 / 中 / 右展开。
4. 4 张照片的分组：宽扇形但不留空位。
5. 5 张及以上照片的分组：最多显示 5 张，呈明显宽扇形。
6. 分组标题与数量没有被遮挡。
7. 点击卡片仍进入正确页面。
8. 滚动与窗口 resize 后卡片布局稳定。

## 实施注意事项

- 不引入新文件，除非实现中发现现有 `groupCardView` 明显过大且影响可读性。
- 不新增配置项；布局参数直接作为私有常量或私有函数返回值。
- 不修改 `photoImageService`，避免影响缩略图内存优化。
- 保持现有代码风格和小驼峰命名。
