# 详情图方向与配置打包修复方案

## 背景

当前需要解决两个已确认的问题：

1. `test_bak4 / P1000860` 在 Normal 分组中，缩略图方向正常，但详情页看起来上下翻转。该照片原本属于 Normal，不是 Duplicate 回流照片。
2. 分析参数没有使用项目内的 `rawViewer/config.yaml`，而是回退到了 `analysisConfig.defaults`，导致欠曝判断仍使用旧严格参数。

本方案只覆盖这两个问题，不处理 Duplicate 组级旋转语义调整。

## 已确认事实

### P1000860 不是业务旋转导致

在本机缓存中查到：

```text
analysis.json:
~/Library/Application Support/rawViewer/CD306E087974A458/analysis.json

folderPath: /Users/wilbur/Downloads/test_bak4
photoId: P1000860
reviewStatus: active
reviewGroupId:
exposureStatus: normal
analysisSource: raw
rotationDegrees: 0
jpgPath: /Users/wilbur/Downloads/test_bak4/P1000860.JPG
rawPath: /Users/wilbur/Downloads/test_bak4/P1000860.RW2
```

因此 `P1000860` 详情页方向异常不是 `rotationDegrees` 写成 180 导致。

### 源图 orientation 正常

`P1000860.JPG` 元数据：

```text
CGImageSource orientation = 1
CIImage properties orientation = 1
pixelWidth = 6000
pixelHeight = 4000
```

因此源 JPG 本身没有 EXIF 旋转要求。

### Metal 渲染链路上下翻转

用 `metalPhotoView` 当前 transform 方式渲染同一张图时，像素角落对比为：

```text
源图 top-left     ≈ (234, 243, 250)
源图 bottom-left  ≈ (186, 187, 182)

Metal texture top-left    ≈ (184, 185, 179)
Metal texture bottom-left ≈ (234, 243, 250)
```

源图顶部被渲染到了 texture 底部，说明详情页 Metal 渲染存在 Y 轴方向差异。

### config.yaml 没有进入 app bundle

构建产物：

```text
pickpick.app/Contents/Resources
- AppIcon.icns
- Assets.car
- default.metallib
```

没有：

```text
config.yaml
```

工程文件证据：

```text
rawViewer.xcodeproj/project.pbxproj
membershipExceptions = (
    config.yaml,
);
```

并且 Resources build phase 为空：

```text
PBXResourcesBuildPhase
files = (
);
```

### test_bak4 使用了 defaults，不是 rawViewer/config.yaml

`test_bak4` 的 `configSnapshot`：

```json
{
  "exposure": {
    "underexposePixelThreshold": 0.04,
    "underexposeRatioLimit": 0.05,
    "overexposeRatioLimit": 0.05,
    "overexposePixelThreshold": 0.96
  },
  "metalConcurrency": 2
}
```

这与 `analysisConfig.defaults` 一致，不是当前源码 `rawViewer/config.yaml` 中的：

```yaml
overexpose_pixel_threshold: 0.975
underexpose_pixel_threshold: 0.025
metal_concurrency: 6
```

## 目标

1. Normal 详情页与缩略图方向一致，`P1000860` 不再上下翻转。
2. `rawViewer/config.yaml` 被编译进 `pickpick.app/Contents/Resources/config.yaml`。
3. 分析时优先使用 app bundle 中的 `config.yaml`。
4. fallback defaults 与 `rawViewer/config.yaml` 保持一致，避免 bundle 配置缺失时静默回退到旧严格阈值。
5. 已有 `analysis.json` 缓存不会自动改写；需要重新分析或清缓存后才能看到新曝光参数。

## 非目标

1. 不修改 Duplicate 保留照片进入 Normal 后是否继承旋转角度的语义。
2. 不在本任务中新增曝光诊断字段，例如每张照片的 `underRatio` / `overRatio`。
3. 不新增测试 target。
4. 不改变缩略图加载策略，除非详情页修复后仍有明确不一致。

## 方案概览

采用三处小范围修改：

1. 修复 `metalPhotoView` 的 CoreImage 到 Metal texture 渲染坐标映射。
2. 修复 Xcode 工程资源配置，让 `rawViewer/config.yaml` 打进 app bundle。
3. 调整 `configLoader` 与 `analysisConfig.defaults`，确保运行时配置来源明确且 fallback 不偏离源码配置。

## 详细设计

### 1. 修复详情页 Y 轴翻转

涉及文件：

```text
rawViewer/views/metalPhotoView.swift
```

当前代码在 render 时使用：

```swift
let transform = CGAffineTransform(translationX: x, y: y)
    .scaledBy(x: effectiveScale, y: effectiveScale)
```

该 transform 只做正向缩放和平移，没有处理 CoreImage 坐标系与 Metal texture 显示坐标系的 Y 轴方向差异。

设计改为显式构造 affine transform，让源图顶部映射到 drawable 顶部：

```swift
let imageLeft = (Double(target.width) - width) / 2 + panOffset.x
let imageTop = (Double(target.height) - height) / 2 + panOffset.y
let transform = CGAffineTransform(
    a: effectiveScale,
    b: 0,
    c: 0,
    d: -effectiveScale,
    tx: imageLeft - extent.minX * effectiveScale,
    ty: imageTop + extent.maxY * effectiveScale
)
```

关键点：

- `d: -effectiveScale` 负责 Y 轴翻转。
- `ty: imageTop + extent.maxY * effectiveScale` 负责翻转后的顶部对齐。
- 保留现有 `displayImage(from:)` 的 90 / 180 / 270 业务旋转逻辑。
- 保留现有 zoom / pan 行为，只调整基础坐标映射。

### 2. 将 config.yaml 打进 app bundle

涉及文件：

```text
rawViewer.xcodeproj/project.pbxproj
```

优先修改：从 `membershipExceptions` 删除 `config.yaml`：

```text
membershipExceptions = (
    config.yaml,
);
```

改为不排除 `config.yaml`。

如果 Xcode file system synchronized group 仍未把 `config.yaml` 复制到 bundle，则显式将 `rawViewer/config.yaml` 加入 Resources build phase。

成功标准是构建后存在：

```text
pickpick.app/Contents/Resources/config.yaml
```

并且 bundle 中的配置与源码一致：

```bash
shasum -a 256 rawViewer/config.yaml
shasum -a 256 "$APP/Contents/Resources/config.yaml"
```

两个 hash 必须一致。

### 3. 调整配置加载顺序

涉及文件：

```text
rawViewer/services/configLoader.swift
```

当前加载顺序：

```text
folderUrl/config.yaml > Bundle.main/config.yaml > analysisConfig.defaults
```

目标加载顺序：

```text
Bundle.main/config.yaml > analysisConfig.defaults
```

理由：

- 用户期望使用当前项目的 `rawViewer/config.yaml` 编译进 app 后统一生效。
- 照片文件夹内的 `config.yaml` 不应该影响 app 的全局分析参数。
- 这样每次分析的配置来源更可控。

实现时只删除 folder config 优先逻辑，不引入新的配置搜索路径。

### 4. 同步 defaults 到 rawViewer/config.yaml

涉及文件：

```text
rawViewer/services/analysisConfig.swift
rawViewer/config.yaml
```

`analysisConfig.defaults` 必须与 `rawViewer/config.yaml` 保持一致。

如果只修复“配置没被用”，保持当前源码配置即可：

```yaml
overexpose_pixel_threshold: 0.975
underexpose_pixel_threshold: 0.025
overexpose_ratio_limit: 0.05
underexpose_ratio_limit: 0.05
metal_concurrency: 6
```

对应 defaults：

```swift
overexposePixelThreshold: 0.975
underexposePixelThreshold: 0.025
overexposeRatioLimit: 0.05
underexposeRatioLimit: 0.05
metalConcurrency: 6
```

如果同时处理“欠曝判断太严格”，推荐后续单独调整为：

```yaml
underexpose_pixel_threshold: 0.02
underexpose_ratio_limit: 0.15
```

本方案建议先确保配置真实生效，再根据重新分析结果决定是否继续放宽欠曝阈值。

## 数据流

### 详情图显示

```text
analysis.json photoItem.rotationDegrees
→ photoBrowserViewController.show(...)
→ photoMetalViewController.load(image:rotationDegrees:)
→ metalPhotoView.setImage(...)
→ metalPhotoView.displayImage(from:) 处理业务旋转
→ metalPhotoView.draw(...) 使用修正后的 Y 轴 transform 渲染到 offscreen texture
→ blit 到 drawable
```

### 配置加载

```text
photoAnalysisService.analyze(folderUrl:)
→ configLoader.load(for: folderUrl)
→ Bundle.main/config.yaml
→ parse yaml
→ analysisConfig
→ rawBayerAnalyzer / jpgAnalyzer
→ analysisStore.save(..., config: config)
→ analysis.json.configSnapshot
```

## 验证方案

### 1. 构建验证

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

预期：构建成功。

### 2. config bundle 验证

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/rawViewer-hanoqkjmyestuveeygokcbvdwvnd/Build/Products/Debug/pickpick.app"
ls "$APP/Contents/Resources/config.yaml"
shasum -a 256 rawViewer/config.yaml
shasum -a 256 "$APP/Contents/Resources/config.yaml"
```

预期：

- `config.yaml` 存在。
- 两个 hash 一致。

### 3. configSnapshot 验证

删除或隔离 `test_bak4` 对应旧缓存后重新分析。

`test_bak4` 当前非容器缓存路径：

```text
~/Library/Application Support/rawViewer/CD306E087974A458/analysis.json
```

重新分析后检查：

```bash
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/Library/Application Support/rawViewer/CD306E087974A458/analysis.json')
d = json.load(open(p))
print(d['configSnapshot'])
PY
```

预期：`configSnapshot` 与 bundle `config.yaml` 一致，不再是旧 defaults。

### 4. P1000860 渲染像素验证

用临时 Swift 脚本按 `metalPhotoView` 新 transform 渲染：

- 源图 top-left 应与 texture top-left 接近。
- 源图 bottom-left 应与 texture bottom-left 接近。

预期：不再出现源图 top-left 被渲染到 texture bottom-left 的情况。

### 5. 手动验证

1. 启动 app。
2. 打开 `/Users/wilbur/Downloads/test_bak4`。
3. 进入 Normal 分组。
4. 打开 `P1000860`。
5. 对比左侧缩略图和右侧详情图方向。

预期：缩略图和详情图方向一致。

### 6. 业务旋转回归

1. 在 Browser 或 Duplicate 中点击右旋。
2. 确认详情图旋转 90°。
3. 再点击右旋，确认详情图旋转 180°。
4. 返回再进入，确认持久化旋转仍生效。

预期：修复 Y 轴后，业务旋转仍按 `rotationDegrees` 工作。

## 风险与处理

### 风险 1：Y 轴修复影响 pan 手感

原因：pan offset 被加入顶部坐标后，视觉方向可能需要确认。

处理：保留 `panOffset.x / panOffset.y` 的现有含义，手动验证拖拽方向。如果方向反了，只调整 panOffset 的 y 号，不改渲染核心逻辑。

### 风险 2：业务 90 / 270 旋转与 Y 轴修复组合异常

原因：`displayImage(from:)` 先改变 CIImage orientation，再套用新的 Y 轴 transform。

处理：手动验证 90 / 180 / 270；如有异常，仅在 `displayImage(from:)` 后统一读取 `imageToRender.extent`，继续使用渲染后 extent 计算 transform。

### 风险 3：Resources 同步机制未自动复制 config.yaml

原因：Xcode synchronized group 对非源码资源的行为可能受 project.pbxproj 结构影响。

处理：如果删除 exception 后 bundle 仍没有 config，则显式添加 PBXFileReference / PBXBuildFile 到 Resources build phase。

### 风险 4：旧 analysis.json 继续显示旧曝光结果

原因：启动时如果已有缓存，`appCoordinator.startAnalysis` 会直接加载缓存，不重新分析。

处理：验证 config 变更时必须删除或隔离对应 folder hash 的旧 `analysis.json`，再重新分析。

## 实施文件清单

预计修改：

```text
rawViewer/views/metalPhotoView.swift
rawViewer.xcodeproj/project.pbxproj
rawViewer/services/configLoader.swift
rawViewer/services/analysisConfig.swift
```

可能修改：

```text
rawViewer/config.yaml
```

仅当本轮决定同步放宽欠曝阈值时修改。

## 自我复审

1. 占位符扫描：本文没有 TODO、TBD、稍后实现等占位内容。
2. 内部一致性：详情图修复聚焦 `metalPhotoView` transform；配置修复聚焦 bundle resource、加载顺序与 defaults 同步。
3. 范围检查：本文只覆盖详情图方向与 config 生效，不包含 Duplicate 旋转语义变更。
4. 歧义检查：配置加载顺序明确为 `Bundle.main/config.yaml > defaults`；旧缓存必须重新分析才能体现新配置。
