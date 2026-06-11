# Recipe — 使用 Icon.png 作为 App 图标

## 背景

项目是 macOS Xcode App，当前 target 已配置 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。项目内已有 `rawViewer/Assets.xcassets/AppIcon.appiconset/Contents.json`，但该 appiconset 目前只有尺寸声明，没有实际 PNG 图标文件。根目录存在用户提供的 `Icon.png`，尺寸为 `1254x1254`，是正方形图片，适合作为源图生成标准 App 图标资源。

## 目标

- 将根目录 `Icon.png` 接入为 App 图标源图。
- 生成 macOS AppIcon 所需的标准尺寸 PNG 文件。
- 更新 `rawViewer/Assets.xcassets/AppIcon.appiconset/Contents.json`，让每个 size/scale 引用对应文件。
- 不修改无关 Xcode 用户状态文件。
- 保留 `Icon.png` 作为源图并纳入版本控制。

## 非目标

- 不改 App 名称、Bundle Identifier、版本号或签名配置。
- 不新增额外 asset catalog。
- 不重命名现有 `AppIcon`，因为 target 已经指向该名称。
- 不提交 `rawViewer.xcodeproj/project.xcworkspace/xcuserdata/wilbur.xcuserdatad/UserInterfaceState.xcuserstate`。

## 推荐方案

采用现有 `rawViewer/Assets.xcassets/AppIcon.appiconset`。使用 `sips` 从 `Icon.png` 生成以下像素尺寸文件：

- `appIcon16.png` — 16x16
- `appIcon32.png` — 32x32
- `appIcon64.png` — 64x64
- `appIcon128.png` — 128x128
- `appIcon256.png` — 256x256
- `appIcon512.png` — 512x512
- `appIcon1024.png` — 1024x1024

`Contents.json` 映射关系：

- `16x16` `1x` → `appIcon16.png`
- `16x16` `2x` → `appIcon32.png`
- `32x32` `1x` → `appIcon32.png`
- `32x32` `2x` → `appIcon64.png`
- `128x128` `1x` → `appIcon128.png`
- `128x128` `2x` → `appIcon256.png`
- `256x256` `1x` → `appIcon256.png`
- `256x256` `2x` → `appIcon512.png`
- `512x512` `1x` → `appIcon512.png`
- `512x512` `2x` → `appIcon1024.png`

## 实施步骤

1. 使用 `sips` 生成各尺寸图标文件到 `rawViewer/Assets.xcassets/AppIcon.appiconset`。
2. 覆盖更新 `Contents.json`，补充每个 image 条目的 `filename`。
3. 检查生成文件与 `git status`，确认只包含图标相关资源、recipe 文档和源图。
4. 可选验证：运行 Xcode 构建或至少检查 asset catalog 文件结构。

## 风险与处理

- `Icon.png` 原始尺寸为 `1254x1254`，生成 `1024x1024` 会缩小，不会放大，质量风险较低。
- 如果用户希望不提交根目录源图，可以后续删除或移入文档/资源目录；本次默认保留作为源图。
- 如果 Xcode 缓存旧图标，可能需要 Clean Build Folder 或重新安装 App 才能看到 Dock/Finder 图标更新。

## 成功标准

- `rawViewer/Assets.xcassets/AppIcon.appiconset` 中存在 7 个 PNG 图标文件。
- `Contents.json` 中 10 个 macOS image 条目都包含正确 `filename`。
- `ASSETCATALOG_COMPILER_APPICON_NAME` 仍为 `AppIcon`。
- `git status` 不包含被暂存或计划提交的 Xcode 用户状态文件。

## 规范自检

- 无 TODO 或占位符。
- 方案范围集中于 App 图标资源接入。
- 不修改工程 target 配置，因为现有配置已满足需求。
- 源图是否提交已明确：默认保留并纳入版本控制。
