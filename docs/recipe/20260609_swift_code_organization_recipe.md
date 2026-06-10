# rawViewer Swift 代码目录整理方案

**Date:** 2026-06-09  
**Scope:** `rawViewer/rawViewer/` 下全部 Swift / Objective-C / Objective-C++ 源码文件  
**Goal:** 将当前平铺的 29 个源文件按职责分层归入子目录，提升可维护性

---

## 现状

当前 `rawViewer/rawViewer/` 目录下所有文件平铺：

```
rawViewer/
├── main.swift
├── appDelegate.swift
├── mainWindowController.swift
├── appCoordinator.swift
├── photoModels.swift
├── photoImageCache.swift
├── jsonReviewStateStore.swift
├── photoAnalyzerBridge.swift
├── photoAnalyzerBridge.h
├── photoAnalyzerBridge.mm
├── rawViewerBridgingHeader.h
├── photoImageService.swift
├── photoDisplayService.swift
├── photoThumbnailService.swift
├── photoTrashService.swift
├── metalPhotoView.swift
├── photoMetalViewController.swift
├── photoThumbnailView.swift
├── photoThumbnailCellView.swift
├── groupCardView.swift
├── groupCollectionViewItem.swift
├── startViewController.swift
├── progressViewController.swift
├── groupGridViewController.swift
├── groupGridViewModel.swift
├── photoBrowserViewController.swift
├── photoBrowserViewModel.swift
├── duplicateCompareViewController.swift
└── duplicateCompareViewModel.swift
```

**问题：**
- 职责混杂，找文件困难
- 业务页面（Browser / Duplicate / GroupGrid）的 ViewController 与 ViewModel 散落在同级目录
- 可复用视图组件与页面控制器混在一起
- 桥接文件（.h/.mm）与 Swift 业务代码混放

---

## 目标目录结构

```
rawViewer/
├── main.swift                          # AppKit 显式入口
├── appDelegate.swift                   # NSApplicationDelegate
├── mainWindowController.swift          # 窗口创建与生命周期
├── appCoordinator.swift                # 全局导航协调器（单一数据源）
│
├── models/                             # 数据模型与状态存储
│   ├── photoModels.swift               # photoItem / photoGroup / 分组逻辑
│   ├── photoImageCache.swift           # photoImageKind / photoCachedImage
│   └── jsonReviewStateStore.swift      # JSON review 状态持久化
│
├── bridge/                             # Swift ↔ C++ 桥接层
│   ├── photoAnalyzerBridge.swift       # Swift async facade
│   ├── photoAnalyzerBridge.h           # Objective-C++ 头文件
│   ├── photoAnalyzerBridge.mm          # Objective-C++ 实现
│   └── rawViewerBridgingHeader.h       # 桥接头
│
├── services/                           # 业务服务层（无 UI）
│   ├── photoImageService.swift         # 图像加载 Facade
│   ├── photoDisplayService.swift       # 大图（JPG/RAW）加载与缓存
│   ├── photoThumbnailService.swift     # 降采样缩略图加载与缓存
│   └── photoTrashService.swift         # 废纸篓操作
│
├── views/                              # 可复用 UI 组件与独立小页面
│   ├── metalPhotoView.swift            # MTKView 子类（Metal 渲染）
│   ├── photoMetalViewController.swift  # Metal 视图控制器包装
│   ├── photoThumbnailView.swift        # 缩略图列表（NSTableView）
│   ├── photoThumbnailCellView.swift    # 缩略图单元格
│   ├── groupCardView.swift             # 分组卡片
│   ├── groupCollectionViewItem.swift   # NSCollectionViewItem 封装
│   ├── startViewController.swift       # 起始页（含 folderDropZone）
│   └── progressViewController.swift    # 分析进度页
│
├── groupGrid/                          # 分组网格业务页面（MVVM）
│   ├── groupGridViewController.swift
│   └── groupGridViewModel.swift
│
├── browser/                            # 照片浏览业务页面（MVVM）
│   ├── photoBrowserViewController.swift
│   └── photoBrowserViewModel.swift
│
└── duplicate/                          # 重复对比业务页面（MVVM）
    ├── duplicateCompareViewController.swift
    └── duplicateCompareViewModel.swift
```

---

## 分层说明

| 目录 | 职责 | 包含文件数 |
|------|------|-----------|
| 根目录 | App 入口、窗口、全局导航协调 | 4 |
| `models/` | 纯数据模型、枚举、状态存储协议与实现 | 3 |
| `bridge/` | 所有与 C++ 后端交互的桥接代码 | 4 |
| `services/` | 图像加载、缩略图、废纸篓等无 UI 业务服务 | 4 |
| `views/` | 可跨页面复用的 UI 组件 + 独立小页面 | 8 |
| `groupGrid/` | 分组网格页面（VC + VM 内聚） | 2 |
| `browser/` | 照片浏览页面（VC + VM 内聚） | 2 |
| `duplicate/` | 重复对比页面（VC + VM 内聚） | 2 |

---

## 迁移原则

1. **零代码改动** — 仅移动文件，不修改任何 `.swift` / `.h` / `.mm` 内容（除桥接头路径外）。
2. **Xcode Group 同步** — 文件系统目录变更后，需在 Xcode 中创建对应的 Group 并重新引用，保持编译通过。
3. **Build Settings 更新** — `Objective-C Bridging Header` 路径需从 `rawViewer/rawViewerBridgingHeader.h` 更新为 `rawViewer/bridge/rawViewerBridgingHeader.h`。
4. **渐进迁移** — 建议分 3 批执行，每批验证编译通过后再继续：
   - Batch 1: `models/` + `bridge/` + `services/`（低风险，无 UI）
   - Batch 2: `views/`（可复用组件）
   - Batch 3: `groupGrid/` + `browser/` + `duplicate/`（业务页面）

---

## 验收标准

- [ ] 所有源文件按上述目录结构就位
- [ ] Xcode 工程编译通过（无文件丢失引用）
- [ ] Bridging Header 路径已更新
- [ ] App 运行时行为与整理前完全一致
