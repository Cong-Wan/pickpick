# Recipe — RAW 按钮可用性与本地日志修复方案

## 背景

当前 App 在进入分组查看图片时，部分只有 JPG 的照片仍可点击 `RAW`。前置审查已落档在：

`docs/codeReview/260611_rawSegmentAvailability.md`

审查结论是：数据层已经能表达“没有 RAW”（`photoItem.rawPath == nil`），加载层也能返回 `RAW missing`，但 UI 层没有把 RAW 可用性映射到 `NSSegmentedControl` 的 enabled 状态；同时展示层在 RAW 加载失败时静默 fallback 到 JPG，导致用户误以为 RAW 可用。

本方案选择 **方案 2：目标完整修复**。

用户确认的产品规则：

1. 普通浏览器中，RAW 按钮可用性按 `rawPath` 非空且磁盘文件存在判断。
2. 重复照片对比页中，只要左右任意一侧存在 RAW 文件，RAW 按钮就可点击。
3. RAW 文件存在但解码失败或过大时，静默回退 JPG。
4. App 需要记录本地日志，方便排查。
5. 日志系统采用通用文件日志，按天分文件，保留最近 7 天。

---

## 目标

### 功能目标

- 只有 JPG 的照片，RAW 按钮灰色，不可点击。
- `rawPath` 非空但文件不存在时，RAW 按钮灰色。
- 普通浏览器中，如果当前偏好是 RAW，但当前照片 RAW 不可用，自动切回 JPG。
- 重复对比页中，只要左右任意一侧有真实存在的 RAW 文件，RAW 按钮可点击。
- RAW 加载失败时继续静默回退 JPG。
- RAW fallback、RAW 缺失、RAW 解码失败、source 切换等事件写入本地日志。

### 非目标

- 不修改扫描规则，不新增 RAW 扩展名。
- 不修改 RAW/JPG 分析算法。
- 不修改缩略图逻辑。
- 不改变 `displaySourceStore` 的全局偏好存储方式。
- 不新增 toast、弹窗、toolbar 状态文案或日志查看 UI。
- 不新增完整 XCTest target。

---

## 方案选择

采用 **目标完整修复**，覆盖当前用户反馈的普通分组浏览器，也同步处理同类的重复照片对比页。

不采用最小 UI 修复，因为它无法覆盖重复对比页，也缺少日志排查能力。

不采用体验增强版，因为用户确认 RAW 失败时静默回退 JPG，不需要 UI 提示。

---

## 架构与组件设计

### 1. 新增通用本地文件日志 `appFileLogger`

新增文件：

`rawViewer/services/appFileLogger.swift`

职责：

- 写入本地日志文件。
- 按天分文件，例如 `2026-06-11.log`。
- 保留最近 7 天，清理更早日志。
- 对外提供简单日志 API。
- 日志写入失败不能影响 App 主流程。

建议 API：

```swift
public enum appLogLevel: String {
    case info
    case warning
    case error
}

public enum appFileLogger {
    public static func log(_ message: String, level: appLogLevel = .info)
}
```

日志目录：

```text
~/Library/Application Support/rawViewer/logs/
```

日志格式：

```text
2026-06-11T10:20:30Z [warning] RAW unavailable, fallback to JPG photoId=<photoId> reason=RAW missing
```

实现约束：

- 内部使用串行队列异步写文件，避免阻塞 UI。
- 首次写入或初始化时清理 7 天前日志。
- 如果创建目录、写文件或清理失败，最多 fallback 到 `NSLog`，不能抛错给调用方。
- 本轮不替换 `appDebugLogger`，两者并存：`appDebugLogger` 仍用于 `--debug` 控制台调试，`appFileLogger` 用于用户环境问题追踪。

---

### 2. 增加 RAW 文件存在性判断

在 `photoItem` 上增加小 helper，建议放在 `rawViewer/models/photoModels.swift` 的 extension 中：

```swift
public extension photoItem {
    func hasExistingRawFile(fileManager: FileManager = .default) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        return fileManager.fileExists(atPath: rawPath)
    }
}
```

用途：

- 普通浏览器判断 RAW segment 是否 enabled。
- 重复对比页判断 RAW segment 是否 enabled。
- 后续其他 UI 如果需要 RAW 可用性，可复用同一语义。

该函数只判断“路径是否存在且文件存在”，不做 RAW 解码。文件存在但无法解码时仍允许用户点击 RAW，加载失败后 fallback JPG 并写日志。

---

### 3. 普通浏览器 `photoBrowserViewController`

修改文件：

`rawViewer/browser/photoBrowserViewController.swift`

新增私有方法：

```swift
private func updateSourceControlAvailability()
```

职责：

1. 读取 `viewModel.currentPhoto`。
2. 调用 `photo.hasExistingRawFile()` 判断当前图 RAW 是否可用。
3. 使用 `sourceControl.setEnabled(hasRaw, forSegment: 1)` 控制 RAW segment。
4. 如果当前 source 是 `.raw`，但当前图不能显示 RAW：
   - 切回 `.jpg`。
   - 更新 `sourceControl.selectedSegment`。
   - 更新 `displaySourceStore().current`。
   - 更新 `viewModel.displaySource`。

调用点：

- `loadView()` 初始化 `sourceControl` 后、首次 `loadCurrentPhoto()` 前。
- `loadCurrentPhoto()` 每次加载当前照片前。
- 删除照片并更新列表后。
- 缩略图选择、上下键切换最终都经过 `loadCurrentPhoto()`，因此不需要重复接入。

`sourceChanged(_:)` 增加防御式 guard：

- 如果用户或未来代码试图切到 RAW，但当前图没有真实存在的 RAW 文件，则立即切回 JPG，不发起 RAW 加载。
- 记录一条 warning 日志，说明 RAW segment change 被拒绝。

注意事项：

- `viewModel.setDisplaySource` 会递增 `currentRequestId`。实现时必须先完成 source 修正，再读取 `requestId` 发起异步加载，避免异步请求被误判为陈旧。

---

### 4. 重复图对比页 `duplicateCompareViewController`

修改文件：

`rawViewer/duplicate/duplicateCompareViewController.swift`

当前 `sourceControl` 是 `loadView()` 内局部变量，需提升为属性：

```swift
private var sourceControl = NSSegmentedControl(labels: ["JPG", "RAW"], trackingMode: .selectOne, target: nil, action: nil)
```

新增私有方法：

```swift
private func updateSourceControlAvailability()
```

规则：

```swift
let leftHasRaw = viewModel.mainPhoto?.hasExistingRawFile() == true
let rightHasRaw = viewModel.candidatePhoto?.hasExistingRawFile() == true
let canSelectRaw = leftHasRaw || rightHasRaw
```

行为：

- `canSelectRaw == true`：RAW segment 可点击。
- `canSelectRaw == false`：RAW segment 灰色。
- 如果当前 `sourceStore.current == .raw` 但 `canSelectRaw == false`，自动切回 JPG。

调用点：

- `loadView()` 初始化 toolbar 后。
- `loadPhotos()` 每次左右照片变化时。
- `handleActionResult(.continueComparing)` 间接调用 `loadPhotos()` 即可。

`sourceChanged(_:)` 增加防御式 guard：

- 如果两侧都没有真实存在的 RAW 文件，却试图切 RAW，则恢复 JPG 并记录日志。

---

### 5. 展示 fallback 日志

保留现有静默 fallback 行为，但增加日志。

普通浏览器位置：

`photoBrowserViewController.show(pair:source:)`

重复对比页位置：

`duplicateCompareViewController.show(pair:source:isLeft:)`

当 `source == .raw` 且 RAW 结果不是 `.image` 时：

- 如果 JPG 可用并 fallback：写 warning 日志。
- 如果 JPG 也不可用：写 error 日志，并继续展示现有错误态。

日志内容至少包含：

- 页面：browser / duplicateCompare。
- photoId。
- side：重复对比页中 left / right；普通浏览器可省略或写 current。
- raw failure reason：来自 `.unavailable(String)`。
- fallback result：fallbackToJpg / noImageAvailable。

示例：

```text
2026-06-11T10:20:30Z [warning] RAW unavailable, fallback to JPG page=browser photoId=A reason=RAW missing
2026-06-11T10:20:31Z [warning] RAW unavailable, fallback to JPG page=duplicate side=right photoId=B reason=Missing RAW
2026-06-11T10:20:32Z [error] RAW unavailable and JPG unavailable page=browser photoId=C rawReason=Cannot decode RAW
```

---

## 数据流

### 普通浏览器

```text
current photoItem
  -> hasExistingRawFile()
  -> updateSourceControlAvailability()
    -> RAW enabled / disabled
    -> 必要时 source 从 RAW 修正为 JPG
  -> loadCurrentPhoto()
    -> imageService.preloadDisplayPair(for: photo)
      -> loadDisplayJpg()
      -> loadDisplayRaw()
    -> show(pair, source)
      -> RAW 成功：显示 RAW
      -> RAW 失败：静默 fallback JPG + 写日志
      -> JPG 也失败：显示 No image available + 写日志
```

### 重复照片对比页

```text
mainPhoto + candidatePhoto
  -> left.hasExistingRawFile || right.hasExistingRawFile
  -> updateSourceControlAvailability()
    -> RAW enabled / disabled
  -> loadPhotos()
    -> 左右分别 preloadDisplayPair()
    -> show(pair, source, isLeft)
      -> 当前侧 RAW 成功：显示 RAW
      -> 当前侧 RAW 缺失或失败：静默 fallback JPG + 写日志
```

---

## 错误处理

### RAW 文件不存在

- 普通浏览器：RAW segment 灰色。
- 重复对比页：如果另一侧有 RAW，RAW segment 仍可点；缺失的一侧加载时 fallback JPG 并写日志。
- 如果两侧都无 RAW，RAW segment 灰色。

### RAW 解码失败或文件过大

- RAW segment 是否可点不受解码能力影响，只看文件是否存在。
- 点击 RAW 后加载失败，静默 fallback JPG。
- 写入 warning 日志。

### JPG 也不可用

- 保持现有错误展示：`No image available`。
- 写入 error 日志。

### 日志失败

- 日志写入失败不能影响图片显示。
- 失败时最多 `NSLog` 一次。
- 不向 UI 抛错。

---

## 并发与线程

- UI segment 状态更新只在控制器主线程路径执行。
- JPG/RAW 图片加载仍由 `photoDisplayService` 在后台队列执行。
- `appFileLogger` 内部用串行队列异步写文件，避免 UI 卡顿和多线程 append 交错。
- 不改变现有 `Task` 取消和 `currentRequestId` 防陈旧请求逻辑。

---

## 验证方案

### 构建验证

实施后运行：

```bash
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build
```

成功标准：Debug build 通过。

### 手工验收数据

准备测试目录：

```text
A.jpg              # 无 RAW
B.jpg
B.cr2              # 有 RAW 且可解码
C.jpg
C.cr2              # RAW 文件存在但可人为损坏，模拟解码失败
D.jpg
D.cr2              # 初次分析后删除 D.cr2，模拟 rawPath 存在但文件不存在
```

### 普通浏览器验收

1. 打开 `A.jpg`：RAW 灰色。
2. 打开 `B.jpg`：RAW 可点，点击后显示 RAW。
3. 打开 `C.jpg`：RAW 可点，点击后静默回退 JPG，并写日志。
4. 打开 `D.jpg`：RAW 灰色，因为文件不存在。
5. 从 `B.jpg` 切到 `A.jpg`：RAW 从可点变灰色。
6. 如果全局偏好之前是 RAW，打开 `A.jpg` 时自动切回 JPG。

### 重复对比页验收

1. 左右都无 RAW：RAW 灰色。
2. 左有 RAW、右无 RAW：RAW 可点。
3. 点击 RAW 后：
   - 左侧显示 RAW。
   - 右侧静默显示 JPG。
   - 日志记录右侧 fallback。
4. 左右都有 RAW：RAW 可点，两侧尽量显示 RAW。
5. 某一侧 RAW 解码失败：该侧 fallback JPG，并写日志。

### 日志验收

1. 日志目录存在：

```text
~/Library/Application Support/rawViewer/logs/
```

2. 当天日志文件存在：

```text
YYYY-MM-DD.log
```

3. RAW fallback 时有类似记录：

```text
2026-06-11T10:20:30Z [warning] RAW unavailable, fallback to JPG photoId=C reason=Cannot decode RAW
```

4. 8 天前日志会被清理。

---

## 实施顺序建议

1. 新增 `appFileLogger`。
2. 在 `photoItem` 增加 `hasExistingRawFile(fileManager:)`。
3. 修普通浏览器 RAW segment 可用性和 source guard。
4. 修重复对比页 RAW segment 可用性和 source guard。
5. 在两个 `show(...)` fallback 路径接入日志。
6. 运行 Debug build。
7. 按手工验收场景检查 UI 和日志。

---

## 风险与缓解

### 风险 1：文件存在检查发生在主线程

`FileManager.fileExists` 是轻量检查，当前只在照片切换时调用，风险可接受。不要在滚动缩略图热路径中调用。

### 风险 2：自动切回 JPG 影响全局偏好

按当前设计，如果当前照片不能显示 RAW，会把 `displaySourceStore` 写回 JPG。这符合“不能让 RAW 保持选中”的体验，但意味着用户下次打开有 RAW 的照片时默认也是 JPG。若未来希望保留用户偏好和当前可显示 source 分离，需要单独设计。

### 风险 3：重复对比页左右显示源不一致

用户选择规则 B 后，这是预期行为：一侧可显示 RAW，另一侧 fallback JPG。日志必须记录每侧实际 fallback，方便排查。

### 风险 4：日志文件无限增长

按天分文件且保留最近 7 天可控制长期增长。单日超大日志不在本轮处理；如后续需要，可追加按大小轮转。
