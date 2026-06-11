# 去除 cpp 独立分析程序 + Swift 原生分析重构方案

**Date:** 2026-06-10
**Scope:** 移除 `cpp/` 整个目录、移除 `rawViewer/bridge/photoAnalyzerBridge.*`、`rawViewer/bridge/rawViewerBridgingHeader.h`，将 RAW 转 JPG 以外的图像分析逻辑全部迁移到 Swift app 中；分析结果存储路径从目标文件夹的 `.cache/analysis.json` 改为 `~/Library/Application Support/rawViewer/`

---

## 背景

当前架构存在以下问题：

1. **冗余的 cpp 独立分析程序**：所有 RAW→JPG 转换、曝光/虚焦分析、EXIF 重复分组都由一个独立的 C++ 命令行程序完成，通过 ObjC++ bridge 与 Swift app 通信
2. **JPG 转换不再需要**：用户现在希望直接分析 RAW Bayer 原始值，不再预先转 JPG
3. **分析通道错位**：当前 Metal shader 分析的是转码后的 8-bit JPG，无法反映 RAW 真实动态范围
4. **存储位置不当**：`.cache/analysis.json` 写入了用户的目标文件夹中，与 app 自身状态混合，污染了用户目录

新需求：

- 打开 app，选择文件夹后，**不转 JPG**，直接分析已有的图片
- **优先分析 RAW**，没有 RAW 才分析 JPG
- 分析内容：曝光/过曝/欠曝/动态范围/虚焦
- RAW 分析使用 **Bayer CFA 原始数据**（LibRaw 提供的未 demosaic 数据），绿色通道做拉普拉斯
- EXIF 重复分组逻辑从 cpp 移植到 Swift
- 分析数据存到 `~/Library/Application Support/rawViewer/` 而非目标文件夹

---

## 目标

1. 完全删除 `cpp/` 独立分析程序
2. 在 Swift app 中实现 RAW Bayer 原始值分析（LibRaw + Metal GPU）
3. 在 Swift app 中实现 JPG 兜底分析（Metal GPU）
4. 在 Swift app 中实现 EXIF 拍摄时间读取与 3 秒阈值重复分组
5. 将分析结果存储到 app 资源目录 `~/Library/Application Support/rawViewer/{folderHash}/analysis.json`
6. 动态范围计算：
   - `scene_spread_ev = log2(P99.9 / P0.1)`（画面动态跨度）
   - `code_range_ev = log2((whiteLevel - blackLevel) / noiseFloor)`（传感器可用动态范围）
7. 必要环节全部使用 Metal GPU 加速

---

## 非目标

1. 不做 RAW 转 JPG（已彻底移除相关代码）
2. 不在 `config.yaml` 中暴露动态范围/曝光/虚焦阈值
3. 不写测试用例（项目其他部分也未引入测试）
4. 不改 review 流程、废纸篓流程、浏览/重复对比界面的 UI 逻辑
5. 不支持 RAW 的 makernotes 解析、不复制所有 EXIF 字段到分析结果
6. 不暴露 Metal 设备/queue 给 app 其他部分（分析模块独立持有）

---

## 架构总览

```
┌──────────────────────────────────────────────────────────────────┐
│  App UI (appCoordinator / ViewControllers)                        │
│  - 选文件夹 → 调 photoAnalysisService.analyze(folderUrl)          │
│  - 读取 analysis.json → 分组/浏览/重复对比 (现状不变)             │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│  photoAnalysisService (主编排)                                     │
│  - 扫描文件夹 (fileScanner)                                       │
│  - 依次: 读 EXIF → 优先级选择 (RAW 优先) → 分析 → 写 JSON         │
│  - 进度回调                                                        │
│  - 不再走 bridge，全程 Swift                                       │
└─────────┬──────────────────────────┬──────────────────────────────┘
          │                          │
          ▼                          ▼
┌──────────────────┐       ┌──────────────────────────────────────┐
│  exifReader       │       │  rawAnalysisEngine                     │
│  duplicateGrouper │       │  ┌────────────┐    ┌────────────────┐ │
│  (CPU 路径)       │       │  │ libRawBridge│    │ metalAnalysis  │ │
│                   │       │  │ (C++→Swift)│    │ Context        │ │
│                   │       │  └──────┬─────┘    └───────┬────────┘ │
│                   │       │         │                   │          │
│                   │       │         ▼                   ▼          │
│                   │       │  ┌──────────────────────────────────┐ │
│                   │       │  │ RAW: LibRaw → MTLBuffer → GPU    │ │
│                   │       │  │ JPG: CIImage → GPU               │ │
│                   │       │  └──────────────────────────────────┘ │
│                   │       └──────────────────────────────────────┘
          │                          │
          ▼                          ▼
┌──────────────────────────────────────────────────────────────────┐
│  analysisStore                                                     │
│  写入: ~/Library/Application Support/rawViewer/{folderHash}/       │
│        analysis.json                                               │
└──────────────────────────────────────────────────────────────────┘
```

### 与现有 UI 层的接口约定

`photoAnalysisService` 暴露给 `appCoordinator` 的接口与原 `photoAnalyzerBridge` 一致：

```swift
public protocol photoAnalyzing: AnyObject {
    func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> analysisSummary

    func loadRecords(folderUrl: URL) throws -> [photoItem]
}

public struct analysisSummary {
    public var totalPhotos: Int
    public var blurryCount: Int
    public var overexposedCount: Int
    public var underexposedCount: Int
    public var normalCount: Int
}
```

`appCoordinator.startAnalysis` 改为：

```swift
public func startAnalysis(folderUrl: URL) {
    currentFolderUrl = folderUrl
    screenState = .progress
    let progressController = progressViewController()
    window?.contentViewController = progressController

    Task { @MainActor in
        do {
            if analysisStore.hasResults(for: folderUrl) {
                self.records = try analyzer.loadRecords(folderUrl: folderUrl)
                self.trashService.cleanupTrashedPhotos(self.records)
                self.showGroups()
                return
            }
            _ = try await analyzer.analyze(folderUrl: folderUrl) { progress in
                progressController.update(progress: progress)
            }
            self.records = try analyzer.loadRecords(folderUrl: folderUrl)
            self.trashService.cleanupTrashedPhotos(self.records)
            self.showGroups()
        } catch {
            self.showError(message: error.localizedDescription)
        }
    }
}
```

---

## Metal GPU 加速策略（核心）

### 整体原则

**所有像素级并行计算必须在 GPU 上完成；CPU 只做 LibRaw 解码、I/O、配置控制和小数据量后处理。**

### RAW Bayer 分析管线（5 个 GPU dispatch + 1 次同步）

```
CPU:
  LibRaw.open_file() → LibRaw.unpack()
  memcpy raw_image (uint16) → MTLBuffer (rawBuffer)
  记录: rawWidth, rawHeight, topMargin, leftMargin, visibleW, visibleH
  记录: blackLevel, whiteLevel

GPU Dispatch 1: bayerHistogramKernel
  输入:  rawBuffer (uint16, rawWidth × rawHeight)
         config: visibleOffsetX/Y, visibleWidth/Height, blackLevel, whiteLevel, binCount
  输出:  histogramBuffer[4 channels × 4096 bins] (atomic_uint)
         exposureCounts[4 channels × 2 over/under] (atomic_uint)
  每个 thread 处理 visible area 中的 1 个像素:
    - 计算 raw 坐标: y = gid / visibleW + topMargin; x = gid % visibleW + leftMargin
    - 读 uint16 值 v
    - v = max(0, min(whiteLevel, v - blackLevel))
    - 根据 (x%2, y%2) 判 CFA 通道: (0,0)→R, (1,0)→G1, (1,1)→B, (0,1)→G2
    - bin = v * 4096 / (whiteLevel - blackLevel + 1)
    - atomic_fetch_add(histogram[channel][bin])
    - if v >= overThreshold: atomic_fetch_add(exposureCounts[channel][0])
    - if v <= underThreshold: atomic_fetch_add(exposureCounts[channel][1])

GPU Dispatch 2: bayerToGreenPlaneKernel
  输入:  rawBuffer
         config: greenWidth = visibleW/2, greenHeight = visibleH/2, blackLevel
  输出:  greenPlaneBuffer (float, greenWidth × greenHeight)
  每个 thread 处理 1 个 2×2 Bayer block:
    - 读 G1: rawBuffer[(2*gy) * rawWidth + (2*gx+1)]
    - 读 G2: rawBuffer[(2*gy+1) * rawWidth + (2*gx)]
    - greenValue = ((G1 - black) + (G2 - black)) / 2.0
    - greenPlane[gy * greenWidth + gx] = greenValue

GPU Dispatch 3: greenLaplacianKernel
  输入:  greenPlaneBuffer
         config: greenWidth, greenHeight
  输出:  laplacianBuffer (float, greenWidth × greenHeight)
  标准 3×3 Laplacian: center*4 - left - right - up - down

GPU Dispatch 4: reduceLaplacianKernel
  输入:  laplacianBuffer, config
  输出:  partialStatsBuffer (sum, sumSq, min, max per group)
  并行规约, 256 threads/group (与现有 kernel 完全一致)

CPU (commit + waitUntilCompleted 后):
  读取 histogram[4] (4×4096=16K uint32, 64KB) → 计算
  读取 exposureCounts[4][2] (32 字节)
  读取 partialStats (sum/sumSq/min/max)

  计算 1 - 曝光: 合并 4 通道 over/under ratio
  计算 2 - 虚焦: variance = sumSq/total - (sum/total)^2, 阈值判断
  计算 3 - 动态范围:
    对 green 通道直方图做 CDF, 找 P0.1 和 P99.9
    scene_spread_ev = log2(P99.9 / max(1, P0.1))
    code_range_ev   = log2((whiteLevel - blackLevel) / max(1, noiseFloor))
    noiseFloor 估计 (v1 简化): noiseFloor = max(1, P0.1)  // 以 P0.1 作为噪声底近似
    // 原因: 在线性 RAW 域, 暗部主要由 read noise + shot noise 主导;
    //       P0.1 已远低于中间调, 接近噪声底; 不引入额外统计保证公式可解释
    // 后续优化 (非 v1 目标): 用 sensor 标定或 ISO 依赖模型估计 read noise
```

### JPG-only 兜底管线（4 个 GPU dispatch + 1 次同步）

```
CPU:
  CGImageSource 读 EXIF (jpgAnalyzer 复用 exifReader)
  CIImage(path) → CIContext.render(toMTLTexture) → RGBA texture (RGBA8)

GPU Dispatch 1: rgbToGrayKernel (与现有 cpp 复用)
GPU Dispatch 2: histogramKernel + over/under counts (与现有复用)
GPU Dispatch 3: laplacianKernel (与现有复用)
GPU Dispatch 4: reduceLaplacianKernel (与现有复用)

CPU 后处理: 同 RAW 路径, 但直方图用 G 通道计算 DR
```

### Metal 加速分配总结表

| 步骤 | 执行位置 | 数据量 | GPU 加速理由 |
|------|---------|--------|------------|
| LibRaw open/unpack | **CPU** | - | 第三方 C++ 库, 不可 GPU 化 |
| raw_image → MTLBuffer 拷贝 | **CPU** memcpy | W×H×2 bytes | 必须 CPU→GPU 上传 |
| Bayer 4 通道直方图 | **GPU** ✓ | 数百万像素 | 高度并行, 4096 bins/通道 |
| Green plane 提取 | **GPU** ✓ | 1/4 像素 | 每 2×2 block 独立 |
| Laplacian 卷积 | **GPU** ✓ | greenW×H 像素 | 经典 GPU 卷积 |
| Laplacian reduce | **GPU** ✓ | float 数组 | 并行规约 |
| 百分位/曝光/虚焦/DR 计算 | **CPU** | 16KB~ | 数据量小, 串行遍历足够 |
| JPG → RGBA texture | **GPU** via CIContext | RGBA texture | Core Image 已 GPU |
| JPG 灰度/直方图/拉普拉斯/reduce | **GPU** ✓ | 像素 | 同上 |
| EXIF 读取 | **CPU** | 单文件 | I/O + ImageIO, 无 GPU 收益 |
| 重复分组 | **CPU** | N 条记录 | N 通常 < 1000, 排序 + 线性 |

---

## Metal Kernels (`rawViewer/metal/rawAnalysisShaders.metal`)

### Kernel 1: bayerHistogramKernel

```metal
struct BayerHistConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;    // leftMargin
    uint visibleOffsetY;    // topMargin
    uint visibleWidth;
    uint visibleHeight;
    uint blackLevel;
    uint whiteLevel;
    uint binCount;          // 4096
    uint overThreshold;     // 归一化到 binCount 范围的过曝阈值
    uint underThreshold;    // 归一化到 binCount 范围的欠曝阈值
};

kernel void bayerHistogramKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device atomic_uint* histogram    [[buffer(1)]],   // [4 channels × binCount]
    device atomic_uint* exposureCounts [[buffer(2)]], // [4 channels × 2]
    constant BayerHistConfig& config [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
);
```

线程配置：1D, `threadsPerThreadgroup = 256`, dispatch `visibleWidth * visibleHeight / 256` 组。

### Kernel 2: bayerToGreenPlaneKernel

```metal
struct GreenPlaneConfig {
    uint rawWidth;
    uint rawHeight;
    uint visibleOffsetX;
    uint visibleOffsetY;
    uint visibleWidth;
    uint visibleHeight;     // 输入 visible area 大小 (偶数)
    uint greenWidth;        // = visibleWidth / 2
    uint greenHeight;       // = visibleHeight / 2
    uint blackLevel;
};

kernel void bayerToGreenPlaneKernel(
    device const ushort* rawBuffer [[buffer(0)]],
    device float* greenPlane       [[buffer(1)]],
    constant GreenPlaneConfig& cfg [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
);
```

### Kernel 3: greenLaplacianKernel

```metal
struct GreenLaplacianConfig {
    uint width;
    uint height;
    uint padLeft;
    uint padTop;            // 边界 0 填充
};

kernel void greenLaplacianKernel(
    device const float* greenPlane   [[buffer(0)]],
    device float* laplacianBuffer     [[buffer(1)]],
    constant GreenLaplacianConfig& cfg [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
);
```

### Kernel 4: reduceLaplacianKernel (与现有 cpp 复用)

完全复用现有 `reduceLaplacianKernel`, 不做修改。

### JPG 路径 kernels (与现有 cpp 复用)

完全复用现有 `rgbToGrayKernel` / `histogramKernel` / `laplacianKernel` / `reduceLaplacianKernel`。

### Metal Context 管理

`rawViewer/metal/metalAnalysisContext.swift` 持有:
- `MTLDevice`, `MTLCommandQueue` (整个 app 周期单例)
- 4 个 compute pipeline states (bayerHistogram, bayerToGreen, greenLaplacian, reduce)
- 4 个 JPG 路径 pipeline states (rgbToGray, histogram, laplacian, reduce)
- 通过 `metalAnalysisContext.shared` 访问
- 编译 shader 源: 在 app 启动时从 bundle 读取 `rawAnalysisShaders.metal` 编译

---

## 数据模型变更

### `photoItem` 新增/修改字段

```swift
public struct photoItem: Equatable, Identifiable {
    public var photoId: String
    public var jpgPath: String
    public var rawPath: String?
    public var isBlurry: Bool
    public var exposureStatus: String            // "normal" | "overexposed" | "underexposed"
    public var reviewStatus: reviewStatus
    public var reviewGroupId: String
    public var templatePhotoId: String

    // 新增
    public var analysisSource: String            // "raw" | "jpg"
    public var dynamicRange: dynamicRangeData
}

public struct dynamicRangeData: Codable, Equatable {
    public var sceneSpreadEv: Double             // log2(P99.9 / P0.1)
    public var codeRangeEv: Double               // log2((white-black) / noiseFloor)
    public var blackLevel: Int                   // RAW 才有
    public var whiteLevel: Int                   // RAW 才有
}
```

### `analysisProgress` 阶段调整

```swift
public enum analysisPhase: String, Codable {
    case scanning
    case exifReading          // 新增
    case rawAnalysis          // 原 analysis, 改为 raw 优先
    case jpgAnalysis          // 新增
    case duplicateGrouping    // 新增
    case completed
}
```

### `analysisSummary` 删除 (不再需要)

不需要 `analysisSummary` (blurryCount 等), 改为从 JSON 中直接读 `summary` 块。

---

## Config.yaml 设计

### 路径解析顺序

1. 优先读目标文件夹下的 `config.yaml` (用户针对该文件夹调参)
2. 缺失则读 `Bundle.main/config.yaml` (app 默认)
3. 两者都缺失则使用代码内硬编码默认值 (与 schema 中默认值一致)

### Schema

```yaml
# rawViewer 分析参数 (Swift 版, schema 2.0)
# 所有阈值都会连同每张照片分析结果一起存档到 analysis.json
# 的 config_snapshot, 以便以后复查当时的判断依据

exposure_detection:
  # 高亮像素阈值, 归一化 [0, 1]。
  # 像素值 > (blackLevel + threshold × (whiteLevel - blackLevel)) 视为过曝。
  # 调大: 更容易判定为正常曝光 (更宽松);
  # 调小: 更容易判定为过曝 (更严格, 如风景照用 0.92, 室内人像用 0.98)。
  # 默认 0.96 等价于旧 cpp 版本的 245/255。
  overexpose_pixel_threshold: 0.96

  # 暗部像素阈值, 归一化 [0, 1]。
  # 像素值 < (blackLevel + threshold × (whiteLevel - blackLevel)) 视为欠曝。
  # 默认 0.04 等价于旧 cpp 版本的 10/255。
  underexpose_pixel_threshold: 0.04

  # 过曝比例阈值。
  # 高亮像素占比 > 该值时判定为过曝。
  # 0.05 表示超过 5% 像素属于高亮区域。
  overexpose_ratio_limit: 0.05

  # 欠曝比例阈值。
  # 暗部像素占比 > 该值时判定为欠曝。
  underexpose_ratio_limit: 0.05

blur_detection:
  # RAW Bayer Green Plane 拉普拉斯方差阈值。
  # 适用于 RAW 分析路径; 适用于 14-bit 线性空间, black level 已减。
  # variance < 此值时判定为虚焦。
  # 调大: 更容易判定为虚焦 (更严格);
  # 调小: 更宽松。
  # 默认 5000.0 适用于松下 LUMIX 14-bit RAW, 其他传感器需重新校准。
  laplacian_threshold_raw: 5000.0

  # JPG 8-bit 灰度拉普拉斯方差阈值。
  # 适用于 JPG-only 兑底路径; 8-bit gamma 应用后。
  # 默认 10.0 与旧 cpp 版本一致。
  laplacian_threshold_jpg: 10.0

  # 拉普拉斯核大小, 只允许正奇数, 建议 3。
  laplacian_kernel_size: 3

analysis:
  # Metal 并发分析数, 推荐 2~4, 过高会触发 GPU 资源竞争。
  metal_concurrency: 2
```

### 阈值转换示例

**JPG 8-bit 路径 (overexpose_pixel_threshold=0.96):**
- 数据范围: 0~255
- `absoluteOver = round(0.96 × 255) = 245`
- 与旧 cpp 行为完全一致

**RAW 14-bit 路径 (overexpose_pixel_threshold=0.96, whiteLevel=16383, blackLevel=200):**
- black level 减后范围: 0~16183
- `absoluteOver = 200 + round(0.96 × 16183) = 200 + 15536 = 15736`
- GPU kernel 在 atomic binning 前会做 `v = clamp(v - black, 0, whiteLevel-black)`, 然后与 absoluteOver 比较

**调参场景示例:**
- 室内人像: `overexpose_pixel_threshold=0.98, underexpose_pixel_threshold=0.02, laplacian_threshold_raw=4000`
- 风景照: `overexpose_pixel_threshold=0.92, underexpose_pixel_threshold=0.08, laplacian_threshold_raw=6000`
- 街拍快照: `laplacian_threshold_jpg=15.0` (更宽松, 接受轻微虚焦)

---

## 存储格式

### 路径

```
~/Library/Application Support/rawViewer/
  └── {folderHash}/
      └── analysis.json
```

- `folderHash` = SHA256(folderPath.utf8).prefix(16).hex, 大写, 16 个字符
- 例: `A1B2C3D4E5F67890`
- 完整路径: `~/Library/Application Support/rawViewer/A1B2C3D4E5F67890/analysis.json`

### JSON Schema

```json
{
  "schema_version": "2.0",
  "folder_path": "/Users/wilbur/Pictures/2026-05",
  "created_at": "2026-06-10T14:00:00Z",
  "updated_at": "2026-06-10T14:05:30Z",
  "summary": {
    "total_photos": 158,
    "blurry": 5,
    "overexposed": 3,
    "underexposed": 8,
    "normal": 142
  },
  "photos": {
    "DSC_0001": {
      "photo_id": "DSC_0001",
      "file_name": "DSC_0001.JPG",
      "file_path": "/Users/wilbur/Pictures/2026-05/DSC_0001.JPG",
      "raw_file_name": "DSC_0001.RW2",
      "raw_file_path": "/Users/wilbur/Pictures/2026-05/DSC_0001.RW2",
      "shooting_time": "2026-05-12T10:30:15Z",
      "shooting_time_source": "raw",
      "analysis_source": "raw",
      "is_blurry": false,
      "exposure_status": "normal",
      "dynamic_range": {
        "scene_spread_ev": 10.5,
        "code_range_ev": 11.2,
        "black_level": 200,
        "white_level": 16300
      },
      "review_status": "active",
      "review_group_id": "",
      "template_photo_id": "",
      "trashed_at": ""
    }
  }
}
```

### 字段约定

| 字段 | 必选 | 说明 |
|------|------|------|
| `shooting_time` | 是 | ISO8601 UTC 或 `null` |
| `shooting_time_source` | 是 | `"raw"` / `"jpg"` / `"none"` |
| `analysis_source` | 是 | `"raw"` (优先) / `"jpg"` (兜底) |
| `is_blurry` | 是 | bool |
| `exposure_status` | 是 | `"normal"` / `"overexposed"` / `"underexposed"` |
| `dynamic_range` | 否 (JPG-only 时省略) | dict |
| `review_group_id` | 是 | `dup_001` / `""` |
| `config_snapshot` (根级) | 是 | 本次分析时的 config 完整快照, 便于以后复查 |
| `analysis_raw_data` (laplacian/histogram 原始数据) | **删除** | 256 bin 直方图无 UI 用途 |

---

## 各服务详细设计

### 1. `rawViewer/services/fileScanner.swift`

移植 `cpp/src/fileScanner.cpp`, 扫描顶层目录:

```swift
public struct photoFilePair {
    public let photoId: String
    public let jpgPath: String?
    public let rawPath: String?
    public var hasJpg: Bool { jpgPath != nil }
    public var hasRaw: Bool { rawPath != nil }
}

public final class fileScanner {
    public init() {}
    public func scanTopLevel(_ folderUrl: URL) throws -> [photoFilePair]
}
```

支持的扩展名:
- JPG/JPEG
- RAW: RW2 (Panasonic), CR2 (Canon)

### 2. `rawViewer/services/exifReader.swift`

移植 `cpp/src/photoMetadataReader.mm`, 使用 ImageIO:

```swift
public struct shootingTimeResult {
    public let found: Bool
    public let epochSeconds: Int64
    public let isoUtc: String?
    public let source: String    // "raw" / "jpg" / "none"
}

public final class exifReader {
    public init() {}
    public func readBestShootingTime(rawPath: String?, jpgPath: String?) -> shootingTimeResult
    public func readFileShootingTime(filePath: String, source: String) -> shootingTimeResult
}
```

策略: ImageIO 读 EXIF DateTimeOriginal → 失败则用 `kMDItemContentCreationDate` 兜底。

### 3. `rawViewer/services/duplicateGrouper.swift`

移植 `cpp/src/jsonManager.cpp` 中 `recomputeTimeDuplicateGroups` 逻辑:

```swift
public final class duplicateGrouper {
    public init() {}
    /// 输入: 拍摄时间列表 [(photoId, epochSeconds)]
    /// 输出: photoId -> reviewGroupId 映射 (空字符串表示无分组)
    /// 规则: 3 秒阈值, 同组 >= 2 张才分配, ID 形如 dup_001
    public func computeDuplicateGroupIds(
        _ entries: [(photoId: String, epochSeconds: Int64)]
    ) -> [String: String]
}
```

### 4. `rawViewer/bridge/libRawBridge.h` / `libRawBridge.mm`

最小 LibRaw 包装, 只做数据提取, 不做分析:

```c
// libRawBridge.h
typedef struct {
    uint16_t* rawImage;       // 指向 LibRaw 内部数据, 生命周期与 handle 绑定
    int rawWidth;
    int rawHeight;
    int visibleOffsetX;       // leftMargin
    int visibleOffsetY;       // topMargin
    int visibleWidth;
    int visibleHeight;
    int blackLevel;
    int whiteLevel;
} rwRawBayerData;

void* rwRawOpen(const char* path);
rwRawBayerData rwRawGetBayerData(void* handle);
void rwRawClose(void* handle);
```

```objc
// libRawBridge.mm
#include "libRawBridge.h"
#include <libraw.h>

struct RawHandle {
    LibRaw processor;
};

void* rwRawOpen(const char* path) {
    auto* h = new RawHandle;
    int ret = h->processor.open_file(path);
    if (ret != LIBRAW_SUCCESS) { delete h; return nullptr; }
    ret = h->processor.unpack();
    if (ret != LIBRAW_SUCCESS) { delete h; return nullptr; }
    return h;
}

rwRawBayerData rwRawGetBayerData(void* handle) {
    auto* h = static_cast<RawHandle*>(handle);
    auto& sizes = h->processor.imgdata.sizes;
    auto& raw = h->processor.imgdata.rawdata;
    auto& color = h->processor.imgdata.color;
    rwRawBayerData data = {};
    data.rawImage = raw.raw_image;
    data.rawWidth = sizes.raw_width;
    data.rawHeight = sizes.raw_height;
    data.visibleOffsetX = sizes.left_margin;
    data.visibleOffsetY = sizes.top_margin;
    data.visibleWidth = sizes.width;
    data.visibleHeight = sizes.height;
    data.blackLevel = color.black;
    data.whiteLevel = color.maximum;
    return data;
}

void rwRawClose(void* handle) {
    delete static_cast<RawHandle*>(handle);
}
```

注意: `raw.raw_image` 在 `dcraw_process()` 之后会被释放; 我们的新流程不调用 `dcraw_process`, 所以指针在 `rwRawClose` 之前始终有效。

### 5. `rawViewer/metal/metalAnalysisContext.swift`

```swift
public final class metalAnalysisContext {
    public static let shared = metalAnalysisContext()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    // RAW 路径
    public let bayerHistogramPipeline: MTLComputePipelineState
    public let bayerToGreenPlanePipeline: MTLComputePipelineState
    public let greenLaplacianPipeline: MTLComputePipelineState
    public let reducePipeline: MTLComputePipelineState

    // JPG 路径 (复用)
    public let rgbToGrayPipeline: MTLComputePipelineState
    public let jpgHistogramPipeline: MTLComputePipelineState
    public let jpgLaplacianPipeline: MTLComputePipelineState

    private init() {
        // 1. MTLCreateSystemDefaultDevice
        // 2. newCommandQueue
        // 3. 从 Bundle.main 取 rawAnalysisShaders.metal 源, 编译
        // 4. newComputePipelineState 创建所有 pipeline
    }
}
```

shader 源文件需要加到 Xcode project 的 Copy Bundle Resources 阶段。

### 6. `rawViewer/services/rawBayerAnalyzer.swift`

```swift
public struct rawAnalysisResult {
    public let isBlurry: Bool
    public let exposureStatus: String
    public let dynamicRange: dynamicRangeData?
    public let blackLevel: Int
    public let whiteLevel: Int
}

public protocol rawBayerAnalyzing: AnyObject {
    func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

public final class rawBayerAnalyzer: rawBayerAnalyzing {
    public init(context: metalAnalysisContext = .shared) { ... }
    public func analyze(rawPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        // 1. rwRawOpen
        // 2. rwRawGetBayerData → blackLevel, whiteLevel
        // 3. 计算 absolute thresholds (归一化 → 14-bit 范围):
        //    absOver   = blackLevel + round(config.exposure.overexposePixelThreshold × (whiteLevel - blackLevel))
        //    absUnder  = blackLevel + round(config.exposure.underexposePixelThreshold × (whiteLevel - blackLevel))
        //    blurThreshold = config.blur.laplacianThresholdRaw
        // 4. device.newBuffer 分配 rawBuffer, memcpy rawImage
        // 5. commandBuffer 创建 4 个 compute encoder, 依次 dispatch
        // 6. commit + waitUntilCompleted
        // 7. 读 back 4×4096 histogram, 2×4 exposure counts, partialStats
        // 8. CPU 后处理:
        //    overRatio  = sum(exposureCounts[*][0]) / totalPixels
        //    underRatio = sum(exposureCounts[*][1]) / totalPixels
        //    exposureStatus:
        //      overRatio  > config.exposure.overexposeRatioLimit  → "overexposed"
        //      underRatio > config.exposure.underexposeRatioLimit → "underexposed"
        //      else                                                   "normal"
        //    isBlurry = (variance < blurThreshold)
        //    dynamicRange: 从 green 通道直方图算 P0.1/P99.9, 求 scene_spread_ev 和 code_range_ev
        // 9. rwRawClose
    }
}
```

### 7. `rawViewer/services/jpgAnalyzer.swift`

```swift
public protocol jpgAnalyzing: AnyObject {
    func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult
}

public final class jpgAnalyzer: jpgAnalyzing {
    public init(context: metalAnalysisContext = .shared) { ... }
    public func analyze(jpgPath: String, config: analysisConfig) throws -> rawAnalysisResult {
        // 1. CIImage(contentsOf: URL)
        // 2. CIContext(mtlDevice) → render toMTLTexture (RGBA8)
        // 3. 计算 absolute thresholds (归一化 → 8-bit 范围):
        //    absOver  = round(config.exposure.overexposePixelThreshold × 255)
        //    absUnder = round(config.exposure.underexposePixelThreshold × 255)
        //    blurThreshold = config.blur.laplacianThresholdJpg
        // 4. dispatch 4 个 kernel: rgbToGray → histogram+counts → laplacian → reduce
        // 5. CPU 后处理, 逻辑与 rawBayer 一致
        //    注意: JPG 无 blackLevel/whiteLevel, dynamicRange 仅 scene_spread_ev
        //          (scene_spread_ev 仍可计算, 但意义不如 RAW 线性域, UI 可选择不展示)
    }
}
```

### 8. `rawViewer/services/analysisStore.swift`

```swift
public final class analysisStore {
    public static let shared = analysisStore()

    private let appSupportDir: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        // ~/Library/Application Support/rawViewer/
        self.appSupportDir = ...
    }

    public func folderHash(_ folderUrl: URL) -> String
    public func resultsUrl(for folderUrl: URL) -> URL
    public func hasResults(for folderUrl: URL) -> Bool
    public func load(for folderUrl: URL) throws -> [photoItem]
    public func save(folderUrl: URL, records: [photoItem]) throws
}
```

review 状态修改由 `jsonReviewStateStore` 改为复用 `analysisStore.save` (review 状态已在 `photoItem` 中), 删掉 `jsonReviewStateStore` 内部的 `.cache/analysis.json` 路径。

### 9. `rawViewer/services/photoAnalysisService.swift`

主编排器, 替代原 `photoAnalyzerBridge`:

```swift
public protocol photoAnalyzing: AnyObject {
    func analyze(
        folderUrl: URL,
        progress: @escaping (analysisProgress) -> Void
    ) async throws -> Void

    func loadRecords(folderUrl: URL) throws -> [photoItem]
}

public final class photoAnalysisService: photoAnalyzing {
    private let scanner: fileScanner
    private let exif: exifReader
    private let grouper: duplicateGrouper
    private let rawAnalyzer: rawBayerAnalyzing
    private let jpgAnalyzer: jpgAnalyzing
    private let store: analysisStore
    private let configLoader: configLoader

    public init(
        scanner: fileScanner = fileScanner(),
        exif: exifReader = exifReader(),
        grouper: duplicateGrouper = duplicateGrouper(),
        rawAnalyzer: rawBayerAnalyzing = rawBayerAnalyzer(),
        jpgAnalyzer: jpgAnalyzing = jpgAnalyzer(),
        store: analysisStore = .shared,
        configLoader: configLoader = configLoader()
    ) { ... }

    public func analyze(folderUrl: URL, progress: @escaping (analysisProgress) -> Void) async throws {
        // Phase 0: 加载 config (从文件夹或 bundle)
        let config = try configLoader.load(for: folderUrl)
        progress(.scanning)

        // Phase 1: Scanning
        let pairs = try scanner.scanTopLevel(folderUrl)
        progress(.exifReading)

        // Phase 2: EXIF Reading (并行 DispatchQueue)
        var records: [String: photoItem] = [:]
        var shootingTimes: [(photoId: String, epochSeconds: Int64)] = []
        // ... 并行读 EXIF, 进度更新
        progress(.rawAnalysis)

        // Phase 3: Raw/Jpg Analysis
        // 对每对 pair:
        //   优先 rawAnalyzer.analyze(rawPath, config)
        //   失败/无 RAW → jpgAnalyzer.analyze(jpgPath, config)
        // 并发度: config.metalConcurrency (默认 2)
        progress(.jpgAnalysis)

        // Phase 4: Duplicate Grouping
        let groupMap = grouper.computeDuplicateGroupIds(shootingTimes)
        for (photoId, gid) in groupMap { records[photoId]?.reviewGroupId = gid }
        progress(.organizing)

        // Phase 5: Save (含 config_snapshot)
        try store.save(folderUrl: folderUrl, records: Array(records.values), config: config)
        progress(.completed)
    }

    public func loadRecords(folderUrl: URL) throws -> [photoItem] {
        try store.load(for: folderUrl)
    }
}
```

### 9.5. `rawViewer/services/configLoader.swift`

```swift
public final class configLoader {
    public init() {}

    public func load(for folderUrl: URL) throws -> analysisConfig {
        // 优先级: folderUrl/config.yaml > Bundle.main/config.yaml > hardcoded defaults
        let folderConfig = folderUrl.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: folderConfig.path) {
            return try load(from: folderConfig)
        }
        if let bundleConfig = Bundle.main.url(forResource: "config", withExtension: "yaml") {
            return try load(from: bundleConfig)
        }
        return analysisConfig.defaults
    }

    public func load(from url: URL) throws -> analysisConfig {
        // 使用 Yams (SwiftYAML) 解析, 字段缺失时回退默认值
        // (Yams 依赖需加到 Xcode project)
    }
}

extension analysisConfig {
    public static let defaults = analysisConfig(
        exposure: .init(
            overexposePixelThreshold: 0.96,
            underexposePixelThreshold: 0.04,
            overexposeRatioLimit: 0.05,
            underexposeRatioLimit: 0.05
        ),
        blur: .init(
            laplacianThresholdRaw: 5000.0,
            laplacianThresholdJpg: 10.0,
            laplacianKernelSize: 3
        ),
        metalConcurrency: 2
    )
}
```

### 10. `jsonReviewStateStore` 改写

删除原有 `.cache/analysis.json` 路径, 改为:

```swift
public final class jsonReviewStateStore: jsonReviewStateStoring {
    public init(folderUrl: URL? = nil) { self.folderUrl = folderUrl }
    public func mark(photoId: String, status: reviewStatus) throws {
        // 直接调用 analysisStore 更新该 photoId
        guard let folderUrl else { return }
        var records = try analysisStore.shared.load(for: folderUrl)
        // 更新 records[photoId].reviewStatus
        // 更新 trashedAt
        try analysisStore.shared.save(folderUrl: folderUrl, records: records)
    }
    public func setTemplate(reviewGroupId: String, templatePhotoId: String) throws { ... }
    public func clearReviewGroupId(photoId: String) throws { ... }
}
```

---

## 文件清单

### 新增

| 文件 | 用途 |
|------|------|
| `rawViewer/services/photoAnalysisService.swift` | 主编排器, 替代 bridge (含 config 透传) |
| `rawViewer/services/rawBayerAnalyzer.swift` | RAW Metal 分析 (接收 config) |
| `rawViewer/services/jpgAnalyzer.swift` | JPG Metal 分析 (接收 config) |
| `rawViewer/services/exifReader.swift` | EXIF 读取 (移植 photoMetadataReader.mm) |
| `rawViewer/services/duplicateGrouper.swift` | 重复分组 (移植 jsonManager.cpp) |
| `rawViewer/services/analysisStore.swift` | App 资源目录存储 |
| `rawViewer/services/fileScanner.swift` | 文件夹扫描 (移植 fileScanner.cpp) |
| `rawViewer/services/configLoader.swift` | **新增**: config.yaml 加载 (移植 cpp configLoader) |
| `rawViewer/resources/config.yaml` | **新增**: bundle 默认配置文件 |
| `rawViewer/metal/metalAnalysisContext.swift` | Metal 设备/pipeline 单例 |
| `rawViewer/metal/rawAnalysisShaders.metal` | Bayer 直方图 + Green plane + Laplacian kernels |
| `rawViewer/bridge/libRawBridge.h` | LibRaw C 桥接头 |
| `rawViewer/bridge/libRawBridge.mm` | LibRaw ObjC++ 实现 |
| `rawViewer/bridge/rawViewerBridgingHeader.h` | 更新: 包含 libRawBridge.h |

### 修改

| 文件 | 改动 |
|------|------|
| `rawViewer/models/photoModels.swift` | 新增 `dynamicRangeData`, `analysisSource`; 调整 `analysisPhase` |
| `rawViewer/models/jsonReviewStateStore.swift` | 改用 `analysisStore` 路径 |
| `rawViewer/appCoordinator.swift` | 注入 `photoAnalysisService` 替代 `photoAnalyzerBridge` |
| `rawViewer/mainWindowController.swift` | 移除 bridge 依赖 |
| `rawViewer.xcodeproj/project.pbxproj` | 链接 Yams (SwiftYAML), LibRaw, Metal 框架; 加 config.yaml 为 Copy Bundle Resource; 删除 cpp 文件引用, 添加新文件引用 |

### 删除

| 文件/目录 | 原因 |
|-----------|------|
| `cpp/` (整个目录) | 完全迁移到 Swift |
| `rawViewer/bridge/photoAnalyzerBridge.h` | 由 photoAnalysisService 替代 |
| `rawViewer/bridge/photoAnalyzerBridge.mm` | 同上 |
| `rawViewer/bridge/photoAnalyzerBridge.swift` | 同上 |

---

## 实施阶段

### Phase 1: 数据模型与 Metal 上下文
1. 修改 `photoModels.swift` 新增字段 (含 `analysisConfig` 结构)
2. 创建 `metalAnalysisContext.swift`
3. 创建 `rawAnalysisShaders.metal`
4. 验证: Metal kernels 可编译

### Phase 2: 移植 CPU-only 服务
1. `fileScanner.swift` (移植 cpp)
2. `exifReader.swift` (移植 photoMetadataReader.mm)
3. `duplicateGrouper.swift` (移植 jsonManager.cpp)
4. `configLoader.swift` (移植 cpp configLoader) + 加 Yams 依赖
5. 创建 `rawViewer/resources/config.yaml` 默认配置文件
6. 验证: 单元编译通过

### Phase 3: LibRaw 桥接与 RAW 分析器
1. `libRawBridge.h/.mm`
2. `rawBayerAnalyzer.swift` (接收 config 参数)
3. 验证: 用 `LUMIX_Backup` 样本数据能跑通, 对比 cpp 旧实现的曝光判定

### Phase 4: JPG 分析器
1. `jpgAnalyzer.swift` (复用现有 Metal kernel 思路, 重写为 Swift; 接收 config)
2. 验证: JPG-only 文件能分析

### Phase 5: 存储与主编排
1. `analysisStore.swift` (写入 `config_snapshot` 到 JSON 根级)
2. `photoAnalysisService.swift` (Phase 0 加载 config, 透传)
3. 验证: 完整流程跑通, JSON 落盘, config_snapshot 正确

### Phase 6: 集成与清理
1. `appCoordinator.swift` 替换 bridge
2. `mainWindowController.swift` 移除 bridge
3. `jsonReviewStateStore.swift` 改用 analysisStore
4. Xcode project 更新 (添加新文件, 删除 cpp 引用, 链接 Metal + LibRaw + Yams)
5. 删除 `cpp/` 目录
6. 删除 `photoAnalyzerBridge.*` 三个文件
7. 编译验证: `xcodebuild` 跑通

---

## 风险

| 风险 | 等级 | 缓解 |
|------|------|------|
| LibRaw `raw_image` 指针生命周期管理 (dcraw_process 会释放) | 中 | 不调用 dcraw_process; 在 `rwRawClose` 之前完成所有读操作 |
| Metal 共享 device 在多线程并发分析时的资源争用 | 中 | 每次分析独立创建 commandBuffer + 独立 buffer, 仅共享 device/queue/pipeline |
| GPU histogram bin 数量与 P0.1/P99.9 精度 | 低 | 4096 bins 对 14-bit RAW 足够; 实际有效位通常 ≤ 13 bit |
| Green plane 边界 (visible area 奇数尺寸) | 低 | 向上取整, 多余行/列不参与计算 |
| EXIF 时区/格式差异 (DateTimeOriginal 不带时区) | 中 | strptime "%Y:%m:%d %H:%M:%S" + mktime 视为本地时间; 与 cpp 旧实现行为一致 |
| App 资源目录权限/sandbox | 低 | Application Support 不需要额外权限 |
| 不同 RAW 格式 whiteLevel/blackLevel 字段缺失 (部分格式为 0) | 中 | 缺值时 dynamicRange 字段不全, 但不阻塞其他字段 |
| JPG-only 时没有 RAW 的 DR 指标 | 预期 | `dynamicRange` 字段为 nil 或只填 `scene_spread_ev` |
| cpp 旧 `.cache/analysis.json` 迁移 | 低 | **v1 不迁移**: 旧 JSON 留在用户文件夹, 用户重新打开文件夹时自动重新分析并存到新位置 |
| Yams 依赖 | 中 | Xcode project 添加 Swift Package 依赖 `https://github.com/jpsim/Yams`, 与现有项目依赖管理一致 |
| `laplacian_threshold_raw` 默认值需要校准 | 中 | 5000.0 估计适用于松下 LUMIX 14-bit RAW; 其他传感器需重新调参 (这是 config.yaml 设计初衷) |

---

## 验收标准

1. 打开 app, 选择 `LUMIX_Backup` 文件夹 (或任意含 RAW+JPG 的样本), 进度条走完
2. 进度条阶段依次显示: Scanning → Reading EXIF → Analyzing → Grouping → Completed
3. 不生成任何 `.cache/analysis.json` 文件, 也不生成 `_converted` 子文件夹
4. 分析结果存到 `~/Library/Application Support/rawViewer/{hash}/analysis.json`
5. 打开 groups 页面, 曝光/虚焦/重复分组显示与旧 cpp 实现一致
6. RAW 文件 (DSC_*.RW2) 的 `analysis_source` 字段为 `"raw"`, 且 `dynamic_range` 含 `black_level` / `white_level`
7. 仅 JPG 文件的 `analysis_source` 为 `"jpg"`, `dynamic_range` 仅含 `scene_spread_ev`
8. 关闭 app, 重新打开, 选同一文件夹, 跳过分析直接加载记录
9. 删掉 app 资源目录下的 `analysis.json`, 重新打开, 重新分析
10. 跑 `xcodebuild` 能编译通过, 无警告
11. **新验收项**: 在 `LUMIX_Backup/config.yaml` 写入 `exposure_detection.overexpose_pixel_threshold: 0.92`, 重新分析, 该文件夹下照片的 `exposure_status` 分布与默认 0.96 不同 (更严格 → 更多过曝判定)
12. **新验收项**: JSON 根级 `config_snapshot` 字段记录了本次分析的实际 config 值
13. **新验收项**: 改 `laplacian_threshold_raw` 从 5000 → 2000, 重新分析, `is_blurry` 数量增加

---

## 非目标确认 (再列)

- 不做 RAW 转 JPG
- 不在 `config.yaml` 中暴露阈值
- 不写测试用例
- 不改 review 流程 / 废纸篓 / 浏览/重复对比 UI
- 不支持完整 makernotes 解析
- 不暴露 Metal device 给 app 其他模块
