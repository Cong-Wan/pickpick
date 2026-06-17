# Metal CIContext 渲染目标纹理缺少 MTLTextureUsageShaderWrite 修复实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 消除 Xcode 控制台反复打印的 `-[CIRenderDestination initWithMTLTexture:commandBuffer:] texture usage must include MTLTextureUsageShaderWrite.` 与 `The destination is nil.` 警告，恢复 `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` 对 Metal 纹理的正常写入，使大图显示与 JPG 分析不再被静默丢弃。

**架构：** 只修改两处 `ciContext.render(..., to: texture, ...)` 调用所使用的目标纹理 usage：①`metalPhotoView` 在 `viewDidMoveToWindow` 给 CAMetalLayer drawable 纹理补 `.shaderWrite`；②`jpgAnalyzer` 把分析用 RGBA texture 的 usage 从 `.shaderRead` 改为 `[.shaderRead, .shaderWrite]`。不改变渲染流程、不改变分析算法、不改变 UI。

**技术栈：** Swift、Metal `MTLTextureUsage` / `CAMetalLayer.drawableTextureUsage`、CoreImage `CIContext`、AppKit `MTKView`、Xcode `xcodebuild`。

---

## 背景与警告分类

控制台告警分两类，只有第二类是 bug：

| 类别 | 典型日志 | 性质 | 是否处理 |
| --- | --- | --- | --- |
| 系统噪音 | `com.apple.linkd.autoShortcut ... Code=4097`、`Unable to obtain a task name port right`、`deferral block timed out`、`<<<< CMPhotoDecompressionContainer+JFIF >>>> signalled err=0`、`IOSurface creation failed: e00002c2 ... IOSurfaceName = CMPhoto` | macOS/App Intents/CoreMedia 内部诊断，`err=0` 即成功，`linkd` 是 App Intents 注册失败后系统自行放弃。App 代码无法消除，不影响功能 | 不处理 |
| 真 bug | `texture usage must include MTLTextureUsageShaderWrite.` + `The destination is nil.` | `CIContext` 用 `CIRenderDestination` 把画面写到目标纹理时，要求纹理 usage 含 `.shaderWrite`（CI 内部走 compute kernel 写入）。目标纹理缺该标志 → destination 为 nil → `ciContext.render(...to:texture...)` 静默丢弃，大图空白/闪烁、JPG 分析读到的纹理未被写入 | **本次修复** |

全项目仅两处把纹理交给 `CIContext` 当渲染目标（`grep -rn "\.render(.*to:" rawViewer --include=*.swift` 可验证）：

- `rawViewer/views/metalPhotoView.swift:241` — 目标是 `drawable.texture`（CAMetalLayer drawable，默认 usage 不含 `.shaderWrite`）。
- `rawViewer/services/jpgAnalyzer.swift:107` — 目标是 `texDesc.usage = .shaderRead` 的 RGBA texture。

两处根因相同，一并修复。

---

## 文件结构

本计划修改两个文件：

- `rawViewer/views/metalPhotoView.swift` — 显示用 `MTKView` 子类。在 `viewDidMoveToWindow` 给 drawable 纹理补 `.shaderWrite`。
- `rawViewer/services/jpgAnalyzer.swift` — JPG 兜底分析器。把 RGBA texture 的 usage 改为 `[.shaderRead, .shaderWrite]`。

本计划不修改以下文件：

- `rawViewer/views/photoMetalViewController.swift` — 包装 `metalPhotoView` 的控制器，调用方式不变。
- `rawViewer/metal/metalAnalysisContext.swift` — 共享 Metal 设备/管线，不涉及纹理 usage。
- `rawViewer/services/rawBayerAnalyzer.swift` — RAW 分析走 LibRaw + 自建纹理，不经过 `CIContext.render(to:)`，不受影响。
- 任何 UI、缓存、分析结果 schema。

---

### Task 1: 修复两处 CIContext 渲染目标纹理 usage

**目标：** `CIContext.render(_:to:)` 的目标纹理都具备 `.shaderWrite`，渲染不再被 `CIRenderDestination` 拒绝；控制台不再出现 `texture usage must include MTLTextureUsageShaderWrite` 与 `The destination is nil`。

**涉及的文件：**

- `rawViewer/views/metalPhotoView.swift`
- `rawViewer/services/jpgAnalyzer.swift`

------

#### Step 1 — 实现

对 `rawViewer/views/metalPhotoView.swift` 做两处精确编辑。

编辑 1.1 — 文件头版本与描述：

oldText:
```
/*
Author: wilbur
Version: 3.3
Date: 2026-06-16
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；进入窗口或布局变化后强制重绘已有图片避免 drawable 未就绪导致空白
*/
```
newText:
```
/*
Author: wilbur
Version: 3.4
Date: 2026-06-17
Description: 仅用于显示的 MTKView 子类；接收外部传入的 CIImage 或错误信息、清除旧内容、提供缩放与平移交互；进入窗口或布局变化后强制重绘已有图片避免 drawable 未就绪导致空白。v3.4 在 viewDidMoveToWindow 给 drawable 纹理补 .shaderWrite，修复 CIContext 渲染目标被拒导致画面丢弃
*/
```

编辑 1.2 — `viewDidMoveToWindow` 中补 `drawableTextureUsage`：

oldText:
```
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestRedrawIfNeeded()
    }
```
newText:
```
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // drawable 纹理默认 usage 不含 .shaderWrite，CIContext 经 CIRenderDestination 写入会被拒并报
        // "texture usage must include MTLTextureUsageShaderWrite" / "The destination is nil"，导致 ciContext.render(to: drawable.texture) 静默丢弃画面。
        // viewDidMoveToWindow 时 layer 已就绪且早于首次 draw，是设置 drawableTextureUsage 的可靠时机。
        (layer as? CAMetalLayer)?.drawableTextureUsage = [.shaderRead, .shaderWrite]
        requestRedrawIfNeeded()
    }
```

对 `rawViewer/services/jpgAnalyzer.swift` 做两处精确编辑。

编辑 1.3 — 文件头版本与描述：

oldText:
```
/*
Author: wilbur
Version: 1.4
Date: 2026-06-13
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析。v1.4 让 contextProvider 可从后台分析任务调用并标注 task group 捕获安全
*/
```
newText:
```
/*
Author: wilbur
Version: 1.5
Date: 2026-06-17
Description: JPG 兜底分析: CoreImage 渲染到 RGBA texture, Metal 4 kernel 分析。v1.4 让 contextProvider 可从后台分析任务调用并标注 task group 捕获安全。v1.5 给 RGBA texture 补 .shaderWrite，修复 CIContext 渲染目标被拒导致纹理未写入
*/
```

编辑 1.4 — RGBA texture usage 补 `.shaderWrite`：

oldText:
```
        texDesc.usage = .shaderRead
```
newText:
```
        texDesc.usage = [.shaderRead, .shaderWrite]
```

实现说明：

- `metalPhotoView`：`framebufferOnly = false` 已在 init 设置，故 `CAMetalLayer.drawableTextureUsage` 会被尊重；`MTKView` 自身不覆写该属性，故在 `viewDidMoveToWindow` 设置即可生效。设置时机早于 `draw(_:)` 中首次 `currentDrawable` 取用，drawable 纹理会带上 `.shaderWrite`。无需新增 import：`MetalKit` 已间接提供 `CAMetalLayer` 与 `MTLTextureUsage`。
- `jpgAnalyzer`：该纹理既要被 `CIContext` 写入（需 `.shaderWrite`），又要被 `rgbToGrayPipeline` 读取（需 `.shaderRead`），故 usage 为 `[.shaderRead, .shaderWrite]`；`storageMode = .shared` 保持不变。
- 不触碰 `draw(_:)` 内的渲染逻辑、不触碰分析 compute 派发顺序。

------

#### Step 2 — 运行验证

先运行构建验证：

```bash
set -o pipefail
xcodebuild \
  -project rawViewer.xcodeproj \
  -scheme pickpick \
  -configuration Debug \
  -derivedDataPath build/derived \
  build 2>&1 | tee /tmp/metalShaderWriteFix_build.log

grep -q "BUILD SUCCEEDED" /tmp/metalShaderWriteFix_build.log
```

预期：

- 命令退出码为 0；
- `/tmp/metalShaderWriteFix_build.log` 中包含 `BUILD SUCCEEDED`；
- 无编译错误、无 `metalPhotoView.swift` / `jpgAnalyzer.swift` 的 warning。

再运行无头烟雾验证（覆盖 `jpgAnalyzer` 分析路径：`--folder=` 会触发扫描+分析，`test_bak3` 含 62 张 JPG，会进入 `jpgAnalyzer.analyze` 的 `ciContext.render(to: texture)`）：

```bash
APP="build/derived/Build/Products/Debug/pickpick.app/Contents/MacOS/pickpick"
"$APP" --folder=/Users/wilbur/Downloads/test_bak3 --debug > /tmp/metalShaderWriteFix_app.log 2>&1 &
PID=$!
sleep 20
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

grep -q "display groups numberOfItems count=" /tmp/metalShaderWriteFix_app.log || { echo "FAIL: 未到分组页"; exit 1; }
if grep -q "texture usage must include MTLTextureUsageShaderWrite" /tmp/metalShaderWriteFix_app.log; then
  echo "FAIL: 仍出现 shaderWrite 警告（jpgAnalyzer 分析路径未修复）"
  exit 1
fi
if grep -q "The destination is nil" /tmp/metalShaderWriteFix_app.log; then
  echo "FAIL: 仍出现 The destination is nil"
  exit 1
fi
echo "SMOKE OK"
```

预期：

- 命令退出码为 0，末尾打印 `SMOKE OK`；
- app 能启动到分组页，日志含 `display groups numberOfItems count=`；
- 启动+分析期间无 crash；
- 日志中不再出现 `texture usage must include MTLTextureUsageShaderWrite` 与 `The destination is nil`（这两条在分析阶段由 `jpgAnalyzer` 的 `ciContext.render(to:)` 触发，修复后必须消失）。

说明：`metalPhotoView` 的 drawable 路径仅在「查看单张照片」时绘制，启动只到分组页不会触发，故 drawable 修复由下面人工验收确认。

最后进行人工界面验收（覆盖 `metalPhotoView` drawable 路径；`photoBrowserViewController.viewDidAppear` 会自动 `loadCurrentPhoto()` 触发 `metalPhotoView.draw`）：

1. 在 Xcode 中 Run（Debug）app，选择 `/Users/wilbur/Downloads/test_bak3`。
2. 等待分组页出现。
3. 进入任一普通分组，浏览器会自动加载第一张照片 → `metalPhotoView` 绘制。
4. 确认：照片正常显示（非空白、非闪烁）；Xcode 控制台不再出现 `texture usage must include MTLTextureUsageShaderWrite` 与 `The destination is nil`。
5. 切换 JPG / RAW source、放大缩小、左右旋转，确认显示正常且控制台无上述两条警告。
6. 进入「疑似重复」对比页，左右两图均应正常显示、无上述警告。
7. 返回分组页再进入其他分组，app 不应 crash。

如果任一验证失败，必须回到 Step 1 修正后重跑本 Step 2 全部验证。不得跳过构建检查，不得弱化警告检查，不得在两条警告仍出现时进入完成状态。

------

✅ **完成的标志：** Step 2 全部通过：构建 `BUILD SUCCEEDED` 且两文件无 warning；无头烟雾打印 `SMOKE OK` 且日志无 `texture usage must include MTLTextureUsageShaderWrite` / `The destination is nil`；人工界面验收确认查看单张照片/重复对比页时照片正常显示、控制台无上述两条警告、无 crash。

------

## 附录：备选方案 A2（仅当 Step 2 人工验收仍报 shaderWrite 警告时执行）

A1（`drawableTextureUsage`）在当前 `framebufferOnly = false` 配置下应生效。若实测 drawable 路径仍报 `texture usage must include MTLTextureUsageShaderWrite`，改用「中转纹理 + blit」绕开 drawable usage 限制，对 `rawViewer/views/metalPhotoView.swift` 做如下改动（替换 A1 的 `viewDidMoveToWindow` 改动为原样，改走 `draw` 内中转）：

1. 新增属性：`private var offscreenTexture: MTLTexture?`
2. 在 `draw(_:)` 取到 `let target = drawable.texture` 后，按 `target` 尺寸/`colorPixelFormat` 创建/复用 `offscreenTexture`，`desc.usage = [.shaderRead, .shaderWrite]`、`desc.storageMode = .private`。
3. 把 `clearPass` 的 color attachment 目标从 `target` 改为 `offscreenTexture`（保证背景清除也经中转）。
4. 把 `ciContext.render(..., to: target, ...)` 改为 `ciContext.render(..., to: offscreenTexture, ...)`。
5. 渲染后追加 blit：`commandBuffer.makeBlitCommandEncoder()` → `copy(from: offscreenTexture, sourceSlice:0, sourceLevel:0, sourceOrigin:.zero, sourceSize:MTLSize(width:target.width,height:target.height,depth:1), to: target, destinationSlice:0, destinationLevel:0, destinationOrigin:.zero)` → `endEncoding()`。
6. 无图（空态/错误态）分支保持原样直接 clear `target` 并 present，无需中转。

A2 不依赖 layer drawable usage，确定性可用；代价是多一次 blit 与一块与 drawable 等大的私有纹理。仅在 A1 验证失败时采用，避免无谓复杂度。

------

## 自我复审

### 1. 规范覆盖

- `metalPhotoView` drawable 缺 `.shaderWrite`：编辑 1.2 在 `viewDidMoveToWindow` 设置 `drawableTextureUsage = [.shaderRead, .shaderWrite]` 覆盖。
- `jpgAnalyzer` RGBA texture 缺 `.shaderWrite`：编辑 1.4 把 usage 改为 `[.shaderRead, .shaderWrite]` 覆盖。
- 不改渲染流程/分析算法/UI：Step 1 仅动纹理 usage 与文件头，未改 `draw` 渲染逻辑、未改 compute 派发。
- 仅两处 `ciContext.render(to:)`：背景章节已用 grep 命令锁定并说明 `rawBayerAnalyzer` 不受影响。
- 文件头规范：两文件均更新 Version 与 Description（3.3→3.4、1.4→1.5，小版本号）。

### 2. 占位符扫描

计划已完成占位符扫描。Step 1 的四处 oldText/newText 均为当前文件确切文本；A2 为附录备选，仅在 A1 失败时启用，主路径无占位符、无空实现。

### 3. 类型一致性

- `CAMetalLayer.drawableTextureUsage` 类型为 `MTLTextureUsage`，`[.shaderRead, .shaderWrite]` 为合法 `OptionSet` 字面量；`layer as? CAMetalLayer` 失败时安全 no-op。
- `MTLTextureDescriptor.usage` 同为 `MTLTextureUsage`，`jpgAnalyzer` 的 `[.shaderRead, .shaderWrite]` 与后续 `encoder.setTexture(texture, index: 0)`（读）及 `ciContext.render(to: texture)`（写）一致。
- `metalPhotoView` 已 `import MetalKit`，间接提供 `CAMetalLayer`、`MTLTextureUsage`，无需新增 import。
- `viewDidMoveToWindow` 已存在并被 `photoMetalViewController` 间接使用，签名不变。

### 4. 验证完整性

- 构建验证有精确 `xcodebuild` 命令与 `BUILD SUCCEEDED` 断言。
- 无头烟雾覆盖 `jpgAnalyzer`：`--folder=/Users/wilbur/Downloads/test_bak3`（实测含 62 JPG + 158 RW2）触发扫描+JPG 分析，grep 断言两条警告消失，并断言到达分组页。
- drawable 路径覆盖：人工验收步骤明确进入分组触发 `viewDidAppear → loadCurrentPhoto → metalPhotoView.draw`，并要求控制台无两条警告、照片正常显示，覆盖 JPG/RAW source、缩放、旋转、重复对比页。
- 失败处理明确：任一验证失败须回 Step 1 修正并重跑全部 Step 2，不得弱化。
