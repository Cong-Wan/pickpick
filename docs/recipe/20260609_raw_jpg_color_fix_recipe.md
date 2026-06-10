# RAW→JPG 色彩发灰修复方案

- **日期**: 2026-06-09
- **主题**: 修复 LibRaw 处理参数缺失导致的 RAW 转 JPG 画面发灰、色彩不准问题
- **决策**: B 方案（全面修复）

## 问题根因

`cpp/src/rawConverter.cpp` 中 LibRaw 处理参数配置不完整，导致：

1. **gamma 曲线未设置** — `gamm[6]` 全为 0，依赖默认行为，某些场景下输出线性或保守 gamma，画面发灰
2. **未启用相机色彩矩阵** — 使用通用近似矩阵，色彩准确度下降
3. **自动亮度过度保守** — 默认启用自动亮度，将最大值缩放到约 75% 白，高光压缩、整体 flat
4. **无 bits 校验** — 未防御性校验 `img->bits`，存在潜在数据不匹配风险

## 修改目标

`cpp/src/rawConverter.cpp` —— LibRaw 处理参数配置

## 具体修改

### 1. Gamma 曲线（核心修复）

```cpp
rawProcessor.imgdata.params.gamm[0] = 0.45;
rawProcessor.imgdata.params.gamm[1] = 4.5;
rawProcessor.imgdata.params.gamm[2] = 0.0;
rawProcessor.imgdata.params.gamm[3] = 0.0;
rawProcessor.imgdata.params.gamm[4] = 0.0;
rawProcessor.imgdata.params.gamm[5] = 0.0;
```

**理由**: `gamm[0]=0.45` 定义 gamma power，`gamm[1]=4.5` 定义 toe slope，这是 LibRaw 标准 sRGB-like gamma 曲线。当前全 0 在某些版本下会导致线性输出或保守 gamma。

### 2. 启用相机色彩矩阵

```cpp
rawProcessor.imgdata.params.use_camera_matrix = 1;
```

**理由**: 使用相机厂商嵌入的色彩转换矩阵，而非 LibRaw 通用近似矩阵，显著提升色彩准确度。

### 3. 关闭自动亮度，固定亮度系数

```cpp
rawProcessor.imgdata.params.no_auto_bright = 1;
rawProcessor.imgdata.params.bright = 1.0f;
```

**理由**: 默认自动亮度将图像缩放到约 75% 白，导致高光压缩、整体发灰。关闭后固定 1.0 保留原始曝光层次。

### 4. 高质量去马赛克

```cpp
rawProcessor.imgdata.params.user_qual = 3;
```

**理由**: `3 = AHD (Adaptive Homogeneity-Directed)`，LibRaw 推荐的高质量去马赛克算法，色彩边缘更准确。

### 5. 防御性 bits 校验

在 `dcraw_make_mem_image` 成功后增加：

```cpp
if (img->bits != 8) {
    result.success = false;
    result.error = "LibRaw output bits mismatch: expected 8, got " + std::to_string(img->bits);
    rawProcessor.dcraw_clear_mem(img);
    return result;
}
```

**理由**: 确保传入 ImageIO 的数据确实是 8-bit，避免潜在的色偏/亮度灾难。

## 参数汇总

| 参数 | 当前值 | 修改后值 | 作用 |
|------|--------|----------|------|
| `use_camera_wb` | 1 | 1 | 保持 |
| `use_auto_wb` | 0 | 0 | 保持 |
| `output_color` | 1 | 1 | 保持（sRGB） |
| `output_bps` | 8 | 8 | 保持 |
| `gamm[0]` | 未设置(0) | **0.45** | gamma power |
| `gamm[1]` | 未设置(0) | **4.5** | gamma slope |
| `use_camera_matrix` | 未设置(0) | **1** | 启用相机色彩矩阵 |
| `no_auto_bright` | 未设置(0) | **1** | 关闭自动亮度 |
| `bright` | 未设置(0) | **1.0f** | 固定亮度系数 |
| `user_qual` | 未设置(0) | **3** | AHD 去马赛克 |
| `img->bits` | 未校验 | **校验 == 8** | 防御性校验 |

## 不修改的内容

- `cpp/src/jpgWriter.mm` —— ImageIO 侧 sRGB 色彩空间声明与当前 `output_color=1` 一致，无需改动
- `cpp/config.yaml` —— 方案 B 采用硬编码最优参数，不新增配置项
- `cpp/src/rawJpgMat.cpp` —— 当前链路未使用，保持不动

## 验证方式

修改后，用同一张 RAW 重新转换 JPG，与修改前对比：
- 中间调不再发灰，对比度提升
- 色彩饱和度更接近相机直出 JPG
- 高光更自然，不再被保守压缩
