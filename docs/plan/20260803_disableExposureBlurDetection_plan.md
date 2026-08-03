# 彻底关闭曝光/虚焦检测并删除相关代码 — 实现计划

> Plan 文档。实现前需用户复审通过，并经 pi 审核修正。
> 需求：关闭过曝/欠曝/虚焦检测，分组只剩 normal 与 duplicate；彻底删除相关代码（非短路逻辑）。

## 背景

用户要求关闭过曝、欠曝、虚焦检测，分组只保留 normal 与 duplicate，且要**彻底删除相关代码**（不是短路 classify 恒返回 normal，而是把整条像素分析链路删掉）。

### 现状链路

```
扫描 fileScanner → EXIF exifReader(拍摄时间)
   → 像素分析 rawBayerAnalyzer / jpgAnalyzer（Metal kernel 算 histogram/laplacian）
   → 评分 analysisScoring.score()(under/over/blurry) + classify()(过曝>欠曝>虚焦>normal)
   → mapPrimaryToFields → photoItem.exposureStatus / isBlurry
   → duplicate 分组 duplicateGrouper(靠 EXIF 拍摄时间，与像素分析无关)
   → 持久化 analysisStore(含 configSnapshot 校验)
   → 分组 makeVisiblePhotoGroups: overexposed/underexposed/blurry/normal/duplicate
```

### 关键事实（已核实）

- **显示层不依赖分析引擎**：photoDisplayService/photoImageService/photoThumbnailService 零引用曝光/模糊/分析引擎；显示用 CoreImage/ImageIO + MetalKit（`metalPhotoView: MTKView`）。
- **Metal 双用途**：分析用 kernel（`rawAnalysisShaders.metal` + `metalAnalysisContext`，只被 rawBayerAnalyzer/jpgAnalyzer 用）；显示用 MTKView（`metalPhotoView`，保留）。
- **libraw 唯一第三方依赖**：只服务 rawBayerAnalyzer（经 `libRawBridge` 读 Bayer 数据）；opencv 目录**根本没被链接使用**（遗留死目录）。
- **duplicate 检测靠 EXIF 拍摄时间**（`duplicateGrouper`），与像素分析完全独立。
- **缓存校验**：analysisStore 用 `configSnapshot`(analysisConfig) 比对，不一致抛 `staleConfigSnapshot` 触发重分析。

## 目标与非目标

**目标：**

- 分组只剩 normal + duplicate。
- 删除曝光/虚焦的整条像素分析链路：评分引擎、RAW/JPG 分析器、Metal 分析 kernel、分析上下文、LibRaw bridge、相关配置与字段。
- 分析流程简化为：扫描 → EXIF → duplicate 分组 → 持久化 → 展示。
- 保留显示层（CoreImage/ImageIO/MetalKit 显示）与 duplicate 检测。

**非目标：**

- 不动显示/浏览器/duplicate 对比的业务逻辑。
- 不动扫描、EXIF 读取、duplicate 分组逻辑。
- 不重构缓存架构（analysisStore 仍用 configSnapshot 校验，仅精简 config 内容）。
- 不清理与本次无关的既有死代码（如 opencv 目录若用户不确认则仅提及）。

## 设计决策点（需审核确认）

1. **analysisConfig 精简为只含 `analysisAlgorithmVersion`**（bump 到 `"no-analysis-v1"` 让旧缓存失效）。删 exposure/blur/scoring/grid/metalConcurrency。
2. **configLoader 删除**，photoAnalysisService 直接用 `analysisConfig.defaults`（无配置文件需求）。
3. **config.yaml 删除**（不再有任何配置项）。
4. **旧缓存兼容**：删 photoItem 的 exposureStatus/isBlurry/dynamicRange/analysisSource 字段后，旧 analysis.json 解码时 Codable 忽略多余 key，照片自动归入 normal/duplicate 分组；configSnapshot 因 `analysisAlgorithmVersion` 从 `grid-v1` 变 `no-analysis-v1` 不一致 -> 抛 `staleConfigSnapshot` -> 触发重走简化分析（结果一致）。无需数据迁移。（注：`legacyAlgorithmVersion` 仅用于识别旧版本字符串，不参与失效逻辑，无需改动。）
5. **3rdPart/libraw 删除**（不再用，含 22MB 二进制 + 头文件）。
6. **3rdPart/opencv 删除**（本就没被链接使用，遗留死目录，顺手清理）。

> 决策点 5、6 涉及 git 历史与 Xcode 配置，若希望降低本次风险可拆为后续独立 PR；本计划默认一并执行。

## 删除范围

### A. 整文件删除（7 个）

| 文件 | 作用 | 删除理由 |
|---|---|---|
| `rawViewer/services/rawBayerAnalyzer.swift` | RAW 像素分析引擎 | 只被 photoAnalysisService 引用，删除后无引用 |
| `rawViewer/services/jpgAnalyzer.swift` | JPG 像素分析引擎 | 同上 |
| `rawViewer/services/analysisScoring.swift` | 评分/分类/features/score/classify/mapPrimaryToFields | 只被分析器引用 |
| `rawViewer/metal/metalAnalysisContext.swift` | Metal 分析上下文 | 只被 jpgAnalyzer 引用 |
| `rawViewer/metal/rawAnalysisShaders.metal` | 分析用 Metal kernel | 只被 metalAnalysisContext 加载 |
| `rawViewer/bridge/libRawBridge.h` | LibRaw C 桥接头 | 只被 rawBayerAnalyzer 用 |
| `rawViewer/bridge/libRawBridge.mm` | LibRaw ObjC++ 实现 | 同上 |

### B. 修改文件（11 个）

#### B1. `rawViewer/models/photoModels.swift`

- 删 `dynamicRangeData` struct。
- `photoItem`：删字段 `isBlurry`、`exposureStatus`、`dynamicRange`、`analysisSource` 及对应 Codable(init/codingKeys/encode/decode) 与 init 参数；保留 `photoId/jpgPath/rawPath/reviewStatus/reviewGroupId/templatePhotoId/rotationDegrees`。
- 删派生属性 `hasFailedAnalysis`、`isNormalAnalysisResult`；`isNormalDisplayPhoto` 简化为「未被 passed/trashed 且未在有效 duplicate 组」即归 normal（不再判曝光/模糊）。
- `photoGroupKind`：删 `.overexposed`、`.underexposed`、`.blurry` 及 title/id 分支；保留 `.normal`、`.duplicate`。
- `makeVisiblePhotoGroups`：删 overexposed/underexposed/blurry 三个 `appendGroup` 分支；normal 分支改为 `visiblePhotos.filter { !isInValidDuplicateGroup($0) }`（所有非 duplicate 可见照片归 normal）；duplicate 分支不变。
- `analysisPhase`：删 `.rawAnalysis`、`.jpgAnalysis` case。
- 版本号 bump（文件头，按现有规则）。

#### B2. `rawViewer/services/analysisConfig.swift`

- 删 `exposureConfig`、`blurConfig`、`gridAnalysisConfig`、`scoringConfig` 四个 struct。
- `analysisConfig` 精简为只剩 `analysisAlgorithmVersion: String`（默认 `"no-analysis-v1"`）；删 exposure/blur/grid/scoring/metalConcurrency 字段与 Codable/init/defaults 对应部分；`codingKeys` 仅留 `analysisAlgorithmVersion`。
- `currentAlgorithmVersion = "no-analysis-v1"`，保留 `legacyAlgorithmVersion` 用于旧缓存识别。
- 版本号 bump。

#### B3. `rawViewer/services/analysisStore.swift`

- `summaryData`/`summaryCounts`：删 `blurry`、`overexposed`、`underexposed` 字段与统计；保留 `totalPhotos`、`normal`；`normal` 统计改为「非有效 duplicate 组的照片数」。
- 版本号 bump。

#### B4. `rawViewer/services/photoAnalysisService.swift`

- 删依赖 `rawAnalyzer`、`jpgAnalyzerService` 属性与 init 注入。
- 删 `runAnalysisStage`、`makeJpgFallbackRunner`、`writeCalibrationDumpIfDebug`、`centerBrightness`；**整体删除 `analysisStageResult` struct**（其字段 `rawAnalysisResult`+`phase` 全为像素分析服务）；`exifStageResult` 保留。
- exifStage 中 `photoItem(photoId:jpgPath:rawPath:analysisSource: "")` 调用点需同步去掉 `analysisSource:` 参数（字段已删）。
- `analyze` 流程简化为：scanning → exifReading（EXIF+建 photoItem）→ duplicateGrouping → organizing → completed；overallProgress 重新分配（exif 占 0.1→0.8，分组 0.85，organizing 0.9，completed 1.0）。
- `analysisSummary`/`computeSummary`：删 `blurryCount`/`overexposedCount`/`underexposedCount`，保留 `totalPhotos`/`normalCount`。
- `loadRecords`/`loadRecordsAsync`：不再用 cfgLoader，直接 `analysisConfig.defaults` 传给 store。
- 删 `import` 不再需要的（若 jpgAnalyzer/rawBayer 删后无残留）。
- 版本号 bump。

#### B5. `rawViewer/services/configLoader.swift`

- **整文件删除**（决策点 2）。若保留极简壳，则改为返回 `analysisConfig.defaults`；本计划默认删除文件。
- 涉及 photoAnalysisService 不再引用 configLoader。

#### B6. `rawViewer/models/jsonReviewStateStore.swift`

- 删恢复照片时 `items[index].exposureStatus = "normal"`、`items[index].isBlurry = false` 两行（字段已删）；恢复逻辑仅重置 `reviewStatus` 即可。
- 版本号 bump。

#### B7. `rawViewer/views/progressViewController.swift`

- `phaseText`：删 `.rawAnalysis`、`.jpgAnalysis` case。
- 版本号 bump。

#### B8. `rawViewer/browser/photoBrowserViewController.swift`

- `groupKind` switch：删 `.overexposed, .underexposed, .blurry` 分支。
  - **副作用**：`canRestoreNormal` 该 switch 删 case 后恒为 `false`，「Restore Normal」按钮不再显示；`restoreNormal` 整条链路（photoBrowserViewController 的 button/`canRestoreNormal`/`restoreNormalClicked`、photoBrowserViewModel 的 `restoreNormalTargets*`、jsonReviewStateStore 的 `restoreNormal`/`.restoreNormal` 操作枚举）成为不可达死代码。本计划**仅按需删字段与 switch 分支使编译通过，不清理此死代码链路**（符合精准修改原则，留待后续）。
- 版本号 bump。

#### B9. `rawViewer/bridge/rawViewerBridgingHeader.h`

- 删 `#import "libRawBridge.h"`。
- 若 bridging header 清空，可保留空文件或从 Xcode 移除 `SWIFT_OBJC_BRIDGING_HEADER` 配置（见 C2）。

#### B10. `rawViewer/config.yaml`

- **整文件删除**（决策点 3）。config.yaml 经同步组自动打包为 bundle 资源，pbxproj 中无静态资源引用，`git rm` 删除文件后同步组自动停止纳入，**无需手改 pbxproj**（见 C4）。

#### B11. `rawViewer/groupGrid/groupGridViewController.swift`

- `visibleGroupCards`/相关：原逻辑只对 `.normal` 有特殊判断（行 12/16/20），删除其它 kind 后逻辑仍成立，无需改；仅核对无残留对 overexposed/underexposed/blurry 的引用（当前 grep 无）。**预计无需改动**，列入仅核对。

### C. Xcode 项目配置（`rawViewer.xcodeproj/project.pbxproj`）

> **重要**：工程采用 `PBXFileSystemSynchronizedRootGroup`（文件系统同步组），被删文件与 config.yaml **无需手改 pbxproj 的 PBXFileReference/PBXBuildFile/PBXGroup/PBXSourcesBuildPhase/PBXResourcesBuildPhase**——`git rm` 删除文件后同步组自动更新。仅需手改「链接/搜索路径」类 build settings。

1. **文件引用**：无需手改（同步组自动处理）。`git rm` 删除文件即可。
2. **链接/搜索配置**（Debug+Release 两处）：
   - 删 `LIBRARY_SEARCH_PATHS = "$(PROJECT_DIR)/3rdPart/libraw/lib"`
   - 删 `OTHER_LDFLAGS` 中 `-lraw`
   - 删 `HEADER_SEARCH_PATHS` 中 `$(PROJECT_DIR)/3rdPart/libraw/include` **和** `$(PROJECT_DIR)/3rdPart/json` 两个条目
   - **保留** `-framework Metal`、`-framework MetalKit`（显示层 metalPhotoView 仍用）
   - **保留** `-framework Accelerate`/`CoreImage`/`CoreGraphics`/`ImageIO`（显示/缩略图用）
3. **bridging header**：若 `rawViewerBridgingHeader.h` 清空，可删 `SWIFT_OBJC_BRIDGING_HEADER` 配置与文件；或保留空文件不删配置（降低风险）。本计划默认**保留空 header 不删配置**（最小改动）。
4. **config.yaml 资源**：无需手改 pbxproj（同步组自动处理资源引用移除），`git rm` 删除文件即可。

### D. 第三方库目录删除

- `git rm -r 3rdPart/libraw/`（22MB 二进制 + 头文件，不再用）
- `git rm -r 3rdPart/opencv/`（本就没链接使用，遗留死目录）
- `git rm -r 3rdPart/json/`（**已核实无引用**：libRawBridge.mm 不 include json.hpp，全体源码无 include，仅 HEADER_SEARCH_PATHS 残留路径）。

> 删除后同步从 pbxproj `HEADER_SEARCH_PATHS` 移除 json/libraw 条目（见 C2）。

## 缓存与兼容

- 旧 `analysis.json` 含 `exposureStatus`/`isBlurry`/`dynamicRange`/`analysisSource` 字段：新 `photoItem` Codable 解码忽略多余 key，兼容加载。
- 旧 `configSnapshot` 含 exposure/blur/scoring：新 `analysisConfig` Codable 解码忽略多余字段，但因 `analysisAlgorithmVersion` 从 "grid-v1" 变 "no-analysis-v1"，`configSnapshot != expectedConfig` 成立 → 抛 `staleConfigSnapshot` → 触发重走简化分析。
- 重分析结果与旧 duplicate 分组一致（duplicate 靠 EXIF 时间，不受影响）。

## 实施顺序

> 因改动强耦合（删分析引擎后 photoAnalysisService 必须同步改才能编译），中间状态不可编译。按逻辑分组，整体完成后一次编译验证。

1. **类型与模型层**：photoModels.swift（photoItem/photoGroupKind/makeVisiblePhotoGroups/analysisPhase/dynamicRangeData）+ analysisConfig.swift + analysisStore.swift
2. **分析服务层**：photoAnalysisService.swift（简化流程）+ 删 configLoader.swift
3. **视图/状态层**：progressViewController.swift + photoBrowserViewController.swift + jsonReviewStateStore.swift
4. **删分析引擎文件**：rawBayerAnalyzer/jpgAnalyzer/analysisScoring/metal/*2/bridge/*2（git rm）
5. **bridge header**：rawViewerBridgingHeader.h 删 import
6. **config.yaml**：删除
7. **Xcode 项目**：手改 pbxproj 链接/搜索路径配置（见 C2，Debug+Release 两处）；文件/资源引用由同步组自动处理，`git rm` 即可，无需手改
8. **第三方库**：git rm 3rdPart/libraw、3rdPart/opencv（核实 json 去留）
9. **clean build 验证**

## 验证方式

- 不使用测试框架（项目约定）。
- `xcodebuild clean build`（Debug）编译通过。
- 手动验证：
  - 打开 app，拖入含 RAW/JPG 的文件夹，分析流程只走 Scanning→Reading EXIF→Grouping Duplicates→Organizing→Completed（无 Analyzing RAW/JPG 阶段）。
  - 分组页只显示 Normal + Duplicate 分组，无 Overexposed/Underexposed/Blurry。
  - Duplicate 对比页、浏览器、删除/旋转等功能正常。
  - 显示图片正常（CoreImage/MetalKit 显示不受影响）。
  - 旧缓存文件夹打开：自动重分析（configSnapshot 失效），结果一致。
- 体积验证：app 体积显著减小（不再含 libraw 22MB）。

## 风险与注意事项

- **Xcode 配置改动风险**：工程用同步组（PBXFileSystemSynchronizedRootGroup），删文件用 `git rm` 自动更新，风险低；剩余风险在链接/搜索路径类 build settings 手改（Debug+Release 两处需一致），建议改后用 `xcodebuild -list` 与 clean build 验证。
- **canRestoreNormal 死代码链路**：删 groupKind case 后该属性恒 false，「Restore Normal」按钮永不显示，相关链路成不可达死代码（见 B8）；本计划不清理，需知晓。
- **bridging header**：若 libRawBridge 删后 header 空，保留空 header + 配置最稳；若误删配置会编译失败。
- **Metal framework 误删风险**：`-framework Metal/MetalKit` **必须保留**（metalPhotoView 显示用），只删分析 shader 文件。
- **3rdPart/json 去留**：实施前 grep 确认 nlohmann/json 是否被 C++ 代码使用；若仅遗留则一并删。
- **opencv 删除**：本就没链接，删目录不影响编译，但 git 历史变化。
- **analysisPhase 枚举变化**：删 case 后，任何残留引用会编译失败（正向保障，grep 确认无遗漏）。
- **summary 字段**：analysisFile.summary 是持久化字段，删字段后旧 json 解码忽略，新保存不含；若外部脚本依赖 summary 字段会受影响（项目无此依赖）。

## 涉及文件汇总

| 操作 | 文件 |
|---|---|
| 删除 | rawViewer/services/rawBayerAnalyzer.swift |
| 删除 | rawViewer/services/jpgAnalyzer.swift |
| 删除 | rawViewer/services/analysisScoring.swift |
| 删除 | rawViewer/services/configLoader.swift |
| 删除 | rawViewer/metal/metalAnalysisContext.swift |
| 删除 | rawViewer/metal/rawAnalysisShaders.metal |
| 删除 | rawViewer/bridge/libRawBridge.h |
| 删除 | rawViewer/bridge/libRawBridge.mm |
| 删除 | rawViewer/config.yaml |
| 删除 | 3rdPart/libraw/（整目录） |
| 删除 | 3rdPart/opencv/（整目录） |
| 改 | rawViewer/models/photoModels.swift |
| 改 | rawViewer/services/analysisConfig.swift |
| 改 | rawViewer/services/analysisStore.swift |
| 改 | rawViewer/services/photoAnalysisService.swift |
| 改 | rawViewer/models/jsonReviewStateStore.swift |
| 改 | rawViewer/views/progressViewController.swift |
| 改 | rawViewer/browser/photoBrowserViewController.swift |
| 改 | rawViewer/bridge/rawViewerBridgingHeader.h |
| 改 | rawViewer.xcodeproj/project.pbxproj |
| 核对 | rawViewer/groupGrid/groupGridViewController.swift |

## 版本号

按项目约定各文件小版本递增并更新文件头 Description：

- photoModels.swift：bump
- analysisConfig.swift：bump
- analysisStore.swift：bump
- photoAnalysisService.swift：bump
- jsonReviewStateStore.swift：bump
- progressViewController.swift：bump
- photoBrowserViewController.swift：bump
- 删除文件不涉及版本号。
