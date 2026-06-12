# pickpick

> 一款为摄影工作流设计的 macOS 照片初筛工具：自动找出过曝、欠曝、虚焦和疑似重复照片，让你把时间花在挑好片上，而不是机械翻片。

pickpick 适合一次拍摄后面对大量 RAW/JPG 素材的场景。你只需要选择照片文件夹，它会完成 GPU 加速分析、自动分组、重复照片对比和安全删除，帮助你更快清理废片、保留值得继续后期的照片。

---

## 为什么值得下载？

- **自动初筛废片**：按过曝、欠曝、虚焦、正常、疑似重复照片自动分组，打开后就能直奔问题照片。
- **RAW 友好**：使用 LibRaw 读取 RAW Bayer 原始数据，并用 Metal 在 GPU 上做曝光直方图与虚焦检测；RAW 不可用时自动回退 JPG 分析。
- **重复照片专用对比**：左右并排查看相似照片，用方向键快速保留左边或右边，也可以选择两张都保留。
- **原生 macOS 体验**：AppKit 界面、Metal 图片显示、系统废纸篓删除，不破坏 macOS 用户习惯。
- **更安全的整理方式**：删除照片会移动到系统废纸篓；审核状态写入本地分析缓存，可随时回到分组继续处理。
- **为大批量照片优化**：缩略图降采样加载、JPG/RAW 分离缓存、并发 GPU 分析，减少等待和卡顿。
- **可按项目调参**：每个照片文件夹都可以放置自己的 `config.yaml`，针对不同相机、题材或容忍度调整曝光/虚焦阈值。

---

## 界面预览

> 这里预留截图位置，你可以后续替换为真实 App 截图。

### 1. 选择照片文件夹

![image-20260612142515223](/Users/wilbur/Library/Application Support/typora-user-images/image-20260612142515223.png)

### 2. 自动分析进度

![image-20260612142812599](/Users/wilbur/Library/Application Support/typora-user-images/image-20260612142812599.png)

### 3. 分组结果：像扑克牌一样快速浏览

![image-20260612142823631](/Users/wilbur/Library/Application Support/typora-user-images/image-20260612142823631.png)

### 4. 单组照片浏览与批量删除

![image-20260612143049003](/Users/wilbur/Library/Application Support/typora-user-images/image-20260612143049003.png)

### 5. 重复照片左右对比

![image-20260612143143255](/Users/wilbur/Library/Application Support/typora-user-images/image-20260612143143255.png)

---

## 核心功能

### 智能照片分析

pickpick 会扫描所选文件夹顶层的照片文件，并识别：

- `jpg` / `jpeg`
- `rw2` / `cr2`
- 同名 JPG + RAW 会自动配对为同一张照片

分析结果包括：

- 过曝检测
- 欠曝检测
- 虚焦检测
- 动态范围数据
- 基于拍摄时间的疑似重复分组

### 分组式工作流

分析完成后，照片会进入清晰的分组：

- **Overexposed**：疑似过曝
- **Underexposed**：疑似欠曝
- **Blurry**：疑似虚焦
- **Normal**：正常照片
- **Duplicate**：疑似重复照片组

你可以先处理问题组，再处理正常组，避免在成百上千张照片里来回迷路。

### 快速浏览与安全删除

普通分组内支持：

- 左侧缩略图列表
- 主区域大图预览
- JPG / RAW 显示源切换
- 旋转显示
- 多选与全选
- 删除确认
- 删除时移动到 macOS 系统废纸篓
- 对误判照片执行 **Restore Normal**，让它回到正常状态

常用快捷键：

| 操作 | 快捷键 |
| --- | --- |
| 上一张 | ↑ |
| 下一张 | ↓ |
| 删除当前/选中照片 | Backspace |
| 放大 | `+` / `=` |
| 缩小 | `-` |
| 重置缩放 | `R` |

### 重复照片对比

重复照片组会进入专门的左右对比界面：

| 操作 | 方式 |
| --- | --- |
| 保留左侧，删除右侧 | ← |
| 保留右侧，删除左侧 | → |
| 两张都保留 | 点击 `Keep both` |
| JPG / RAW 切换 | 顶部 Segment |
| 同时旋转左右照片 | 顶部旋转按钮 |

当一组重复照片处理完成后，pickpick 会自动回到分组页。

---

## 使用说明

### 下载安装

1. 下载 `pickpick.dmg`。
2. 打开 DMG，把 `pickpick.app` 拖到 `Applications`。
3. 启动 pickpick。
4. 点击首页的文件夹选择区域，选择你的照片文件夹。

### 推荐文件夹结构

pickpick 当前扫描所选文件夹的**顶层文件**，推荐这样组织：

```text
myShoot/
├── DSC001.jpg
├── DSC001.rw2
├── DSC002.jpg
├── DSC002.rw2
└── config.yaml   # 可选
```

同名 JPG/RAW 会自动配对；只有 RAW 或只有 JPG 的照片也可以参与分析。

### 可选：自定义分析参数

如果你想按某次拍摄单独调整阈值，可以在照片文件夹里放一个 `config.yaml`。文件夹内配置优先级高于 App 内置默认配置。

```yaml
exposure_detection:
  overexpose_pixel_threshold: 0.96
  underexpose_pixel_threshold: 0.04
  overexpose_ratio_limit: 0.05
  underexpose_ratio_limit: 0.05

blur_detection:
  laplacian_threshold_raw: 5000.0
  laplacian_threshold_jpg: 10.0

analysis:
  metal_concurrency: 6
```

---

## 本地数据与隐私

pickpick 是本地照片分析工具：

- 照片分析在本机完成。
- 分析结果保存在本机 Application Support 目录下。
- 删除操作使用 macOS 系统废纸篓。
- 不需要上传照片到云端。

---

## 开发与打包

### 打开项目

```bash
open rawViewer.xcodeproj
```

选择 `pickpick` scheme 后运行或构建。

### 命令行构建 Release

```bash
xcodebuild \
  -project rawViewer.xcodeproj \
  -scheme pickpick \
  -configuration Release \
  -derivedDataPath build/derived
```

### 打包 DMG

Release 构建完成后执行：

```bash
./scripts/buildDmg.sh
```

生成的 DMG 会输出到 `build/` 目录。

---

## 技术亮点

- **Swift + AppKit**：保持轻量、原生、直接的 macOS 桌面体验。
- **Metal Compute**：RAW/JPG 分析走 GPU kernel，加速直方图、曝光统计和拉普拉斯虚焦检测。
- **LibRaw Bridge**：通过 Objective-C++ C bridge 读取 RAW 原始 Bayer 数据。
- **CoreImage / ImageIO**：用于 RAW/JPG 显示和缩略图降采样。
- **JSON 状态持久化**：保存分析结果、审核状态、旋转角度和重复组处理状态。
- **安全删除策略**：先移动到系统废纸篓，再更新本地审核状态。

---

## 当前支持格式

| 类型 | 扩展名 |
| --- | --- |
| JPG | `.jpg`, `.jpeg` |
| RAW | `.rw2`, `.cr2` |

---

## 一句话总结

如果你经常拍完一堆照片后，还要手动排查废片、误焦、曝光问题和连拍重复图，pickpick 可以把这一步变成一个更快、更清晰、更安全的 macOS 原生工作流。
