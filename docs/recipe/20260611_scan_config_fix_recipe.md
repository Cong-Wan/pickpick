# Scan 阶段 Config 加载失败 + 性能优化

Author: wilbur
Date: 2026-06-11
Version: 1.0

## 背景

用户上传文件夹后，scan/analysis 流水线有两个问题：

1. **config.yaml 未被打包进 app bundle** — `configLoader` 三级降级链中 Bundle 路径永远返回 nil，实际使用硬编码 `analysisConfig.defaults`。虽然当前默认值与 yaml 一致，但修改 yaml 不会生效。
2. **scan 阶段耗时过长** — `metalConcurrency=2` 限制了 GPU 并发，LibRaw `open_file+unpack` 是同步 CPU 密集操作，每个 RAW 文件串行经历 CPU 解压→memcpy→GPU→同步等待，流水线未充分并行。

## 方案 1：config.yaml 打包进 Bundle

### 根因

项目使用 Xcode 16+ 新格式 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），Xcode 自动扫描 `rawViewer/` 目录。`.swift`、`.metal`、`.xcassets` 等类型自动按角色处理，但 `.yaml` 不在自动识别列表中，被静默忽略。

### 修复

在 `project.pbxproj` 中添加 `PBXFileSystemSynchronizedBuildFileExceptionSet`，显式声明 `config.yaml` 为资源文件。

#### 改动文件

- `rawViewer.xcodeproj/project.pbxproj`

#### 具体改动

1. **新增 section** `PBXFileSystemSynchronizedBuildFileExceptionSet`：

```
D8CF00012FC92FEA00F93001 /* Exceptions for "rawViewer" folder in "pickpick" target */ = {
    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
    membershipExceptions = (
        config.yaml,
    );
    target = D8DB712F2FC92FEA00F93F82 /* pickpick */;
};
```

2. **在 `PBXFileSystemSynchronizedRootGroup`** 中添加 `exceptions` 字段引用上述 exception set：

```
exceptions = (
    D8CF00012FC92FEA00F93001 /* Exceptions for "rawViewer" folder in "pickpick" target */,
);
```

#### 验证

- `xcodebuild build` 编译成功
- 构建产物中 `pickpick.app/Contents/Resources/config.yaml` 存在
- 运行时 `Bundle.main.url(forResource: "config", withExtension: "yaml")` 返回非 nil

### 风险

- pbxproj 手动编辑有风险，但改动极小（新增一个 section + 一行引用），项目已有 `.backup` 可回滚。

## 方案 2：提高 Metal 并发度

### 根因

`config.yaml` 中 `metal_concurrency: 2`，同一时间最多 2 个文件进入 GPU 分析流水线。每个文件的瓶颈是 LibRaw CPU 解压（`open_file` + `unpack`），2 并发不足以充分利用多核 CPU。

### 修复

将 `config.yaml` 中 `metal_concurrency` 从 2 提高到 6。

#### 改动文件

- `rawViewer/config.yaml`

#### 具体改动

```yaml
analysis:
  metal_concurrency: 6  # 原值 2
```

#### 原理

`photoAnalysisService` 中通过 `DispatchSemaphore(value: config.metalConcurrency)` 控制并发数。并发度 6 意味着最多 6 个文件同时处于 LibRaw 解压 + GPU 分析流程中，充分利用 Apple Silicon 的多核 CPU 和 GPU。

`configLoader` 中已有安全边界 `min(max(rawConcurrency, 1), 4)`，需同步放宽上限。

#### 联动改动

- `rawViewer/services/configLoader.swift`：将上限从 4 放宽到 8：

```swift
let concurrency = min(max(rawConcurrency, 1), 8)  // 原上限 4
```

#### 验证

- 对比修改前后同一文件夹的扫描总耗时，预期提升 2-3x。

### 风险

- Apple Silicon GPU 通常 7-10 核，并发 6 完全安全，不会造成资源争抢。
- 如果后续发现内存压力过大，可回调至 4。

## 执行计划

| 步骤 | 改动 | 文件 |
|------|------|------|
| 1 | 添加 exception set + exceptions 引用 | `project.pbxproj` |
| 2 | metal_concurrency 2→6 | `config.yaml` |
| 3 | 并发上限 4→8 | `configLoader.swift` |
| 4 | 编译验证 | `xcodebuild` |
| 5 | 检查 bundle 内 config.yaml | 构建产物 |

## 不在本次范围

- GPU buffer 预分配复用（减少每张照片的 makeBuffer 开销）
- LibRaw 解压与 GPU 分析流水线化（需要较大重构）
