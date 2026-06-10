# Swift 代码目录整理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `rawViewer/rawViewer/` 下平铺的 29 个源文件按职责分层迁入子目录，不修改任何源码逻辑，更新 Xcode bridging header 路径，确保编译通过。

**Architecture:** 利用 Xcode 16 `PBXFileSystemSynchronizedRootGroup` 特性——文件系统目录结构会自动同步到 Xcode 工程中，因此只需在磁盘上创建目录并移动文件，再更新 `SWIFT_OBJC_BRIDGING_HEADER` 路径即可。

**Tech Stack:** Swift / Objective-C++ / Xcode 16 / macOS

---

### 目录对照表（迁移前 → 迁移后）

| 原路径 | 新路径 |
|--------|--------|
| `rawViewer/photoModels.swift` | `rawViewer/models/photoModels.swift` |
| `rawViewer/photoImageCache.swift` | `rawViewer/models/photoImageCache.swift` |
| `rawViewer/jsonReviewStateStore.swift` | `rawViewer/models/jsonReviewStateStore.swift` |
| `rawViewer/photoAnalyzerBridge.swift` | `rawViewer/bridge/photoAnalyzerBridge.swift` |
| `rawViewer/photoAnalyzerBridge.h` | `rawViewer/bridge/photoAnalyzerBridge.h` |
| `rawViewer/photoAnalyzerBridge.mm` | `rawViewer/bridge/photoAnalyzerBridge.mm` |
| `rawViewer/rawViewerBridgingHeader.h` | `rawViewer/bridge/rawViewerBridgingHeader.h` |
| `rawViewer/photoImageService.swift` | `rawViewer/services/photoImageService.swift` |
| `rawViewer/photoDisplayService.swift` | `rawViewer/services/photoDisplayService.swift` |
| `rawViewer/photoThumbnailService.swift` | `rawViewer/services/photoThumbnailService.swift` |
| `rawViewer/photoTrashService.swift` | `rawViewer/services/photoTrashService.swift` |
| `rawViewer/metalPhotoView.swift` | `rawViewer/views/metalPhotoView.swift` |
| `rawViewer/photoMetalViewController.swift` | `rawViewer/views/photoMetalViewController.swift` |
| `rawViewer/photoThumbnailView.swift` | `rawViewer/views/photoThumbnailView.swift` |
| `rawViewer/photoThumbnailCellView.swift` | `rawViewer/views/photoThumbnailCellView.swift` |
| `rawViewer/groupCardView.swift` | `rawViewer/views/groupCardView.swift` |
| `rawViewer/groupCollectionViewItem.swift` | `rawViewer/views/groupCollectionViewItem.swift` |
| `rawViewer/startViewController.swift` | `rawViewer/views/startViewController.swift` |
| `rawViewer/progressViewController.swift` | `rawViewer/views/progressViewController.swift` |
| `rawViewer/groupGridViewController.swift` | `rawViewer/groupGrid/groupGridViewController.swift` |
| `rawViewer/groupGridViewModel.swift` | `rawViewer/groupGrid/groupGridViewModel.swift` |
| `rawViewer/photoBrowserViewController.swift` | `rawViewer/browser/photoBrowserViewController.swift` |
| `rawViewer/photoBrowserViewModel.swift` | `rawViewer/browser/photoBrowserViewModel.swift` |
| `rawViewer/duplicateCompareViewController.swift` | `rawViewer/duplicate/duplicateCompareViewController.swift` |
| `rawViewer/duplicateCompareViewModel.swift` | `rawViewer/duplicate/duplicateCompareViewModel.swift` |

根目录保留（不移动）：
- `main.swift`
- `appDelegate.swift`
- `mainWindowController.swift`
- `appCoordinator.swift`
- `Assets.xcassets/`
- `config.yaml`

---

### Task 1: 迁移模型层与桥接层文件

**Goal:** `models/` 与 `bridge/` 目录存在，且 7 个对应文件已迁入。

**Files touched:**

- `rawViewer/models/` — 新建目录，存放数据模型
- `rawViewer/bridge/` — 新建目录，存放 Swift/C++ 桥接代码

------

#### Step 1 — Implement

```bash
# 基于项目根目录执行
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

# 创建目录
mkdir -p "$RAWVIEWER_DIR/models"
mkdir -p "$RAWVIEWER_DIR/bridge"

# 迁移 models
mv "$RAWVIEWER_DIR/photoModels.swift" "$RAWVIEWER_DIR/models/photoModels.swift"
mv "$RAWVIEWER_DIR/photoImageCache.swift" "$RAWVIEWER_DIR/models/photoImageCache.swift"
mv "$RAWVIEWER_DIR/jsonReviewStateStore.swift" "$RAWVIEWER_DIR/models/jsonReviewStateStore.swift"

# 迁移 bridge
mv "$RAWVIEWER_DIR/photoAnalyzerBridge.swift" "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.swift"
mv "$RAWVIEWER_DIR/photoAnalyzerBridge.h" "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.h"
mv "$RAWVIEWER_DIR/photoAnalyzerBridge.mm" "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.mm"
mv "$RAWVIEWER_DIR/rawViewerBridgingHeader.h" "$RAWVIEWER_DIR/bridge/rawViewerBridgingHeader.h"
```

------

#### Step 2 — Write tests (验证文件存在性)

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

# models 文件
test -f "$RAWVIEWER_DIR/models/photoModels.swift" && echo "PASS: photoModels.swift" || echo "FAIL: photoModels.swift"
test -f "$RAWVIEWER_DIR/models/photoImageCache.swift" && echo "PASS: photoImageCache.swift" || echo "FAIL: photoImageCache.swift"
test -f "$RAWVIEWER_DIR/models/jsonReviewStateStore.swift" && echo "PASS: jsonReviewStateStore.swift" || echo "FAIL: jsonReviewStateStore.swift"

# bridge 文件
test -f "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.swift" && echo "PASS: photoAnalyzerBridge.swift" || echo "FAIL: photoAnalyzerBridge.swift"
test -f "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.h" && echo "PASS: photoAnalyzerBridge.h" || echo "FAIL: photoAnalyzerBridge.h"
test -f "$RAWVIEWER_DIR/bridge/photoAnalyzerBridge.mm" && echo "PASS: photoAnalyzerBridge.mm" || echo "FAIL: photoAnalyzerBridge.mm"
test -f "$RAWVIEWER_DIR/bridge/rawViewerBridgingHeader.h" && echo "PASS: rawViewerBridgingHeader.h" || echo "FAIL: rawViewerBridgingHeader.h"

# 旧位置不应再存在
test ! -f "$RAWVIEWER_DIR/photoModels.swift" && echo "PASS: old photoModels.swift removed" || echo "FAIL: old photoModels.swift still exists"
test ! -f "$RAWVIEWER_DIR/rawViewerBridgingHeader.h" && echo "PASS: old rawViewerBridgingHeader.h removed" || echo "FAIL: old rawViewerBridgingHeader.h still exists"
```

------

#### Step 3 — Run tests and confirm all pass

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

results=0
for f in models/photoModels.swift models/photoImageCache.swift models/jsonReviewStateStore.swift bridge/photoAnalyzerBridge.swift bridge/photoAnalyzerBridge.h bridge/photoAnalyzerBridge.mm bridge/rawViewerBridgingHeader.h; do
  if [ -f "$RAWVIEWER_DIR/$f" ]; then
    echo "PASS: $f"
  else
    echo "FAIL: $f missing"
    results=1
  fi
done

for old in photoModels.swift photoImageCache.swift jsonReviewStateStore.swift photoAnalyzerBridge.swift photoAnalyzerBridge.h photoAnalyzerBridge.mm rawViewerBridgingHeader.h; do
  if [ -f "$RAWVIEWER_DIR/$old" ]; then
    echo "FAIL: old $old still exists"
    results=1
  else
    echo "PASS: old $old removed"
  fi
done

exit $results
```

**Expected output:**
```
PASS: models/photoModels.swift
PASS: models/photoImageCache.swift
PASS: models/jsonReviewStateStore.swift
PASS: bridge/photoAnalyzerBridge.swift
PASS: bridge/photoAnalyzerBridge.h
PASS: bridge/photoAnalyzerBridge.mm
PASS: bridge/rawViewerBridgingHeader.h
PASS: old photoModels.swift removed
PASS: old photoImageCache.swift removed
PASS: old jsonReviewStateStore.swift removed
PASS: old photoAnalyzerBridge.swift removed
PASS: old photoAnalyzerBridge.h removed
PASS: old photoAnalyzerBridge.mm removed
PASS: old rawViewerBridgingHeader.h removed
```

✅ **Done when:** 所有 14 个检查项输出 PASS。

---

### Task 2: 迁移服务层文件

**Goal:** `services/` 目录存在，且 4 个服务文件已迁入。

**Files touched:**

- `rawViewer/services/` — 新建目录，存放业务服务

------

#### Step 1 — Implement

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

mkdir -p "$RAWVIEWER_DIR/services"

mv "$RAWVIEWER_DIR/photoImageService.swift" "$RAWVIEWER_DIR/services/photoImageService.swift"
mv "$RAWVIEWER_DIR/photoDisplayService.swift" "$RAWVIEWER_DIR/services/photoDisplayService.swift"
mv "$RAWVIEWER_DIR/photoThumbnailService.swift" "$RAWVIEWER_DIR/services/photoThumbnailService.swift"
mv "$RAWVIEWER_DIR/photoTrashService.swift" "$RAWVIEWER_DIR/services/photoTrashService.swift"
```

------

#### Step 2 — Write tests

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

results=0
for f in services/photoImageService.swift services/photoDisplayService.swift services/photoThumbnailService.swift services/photoTrashService.swift; do
  if [ -f "$RAWVIEWER_DIR/$f" ]; then
    echo "PASS: $f"
  else
    echo "FAIL: $f missing"
    results=1
  fi
done

for old in photoImageService.swift photoDisplayService.swift photoThumbnailService.swift photoTrashService.swift; do
  if [ -f "$RAWVIEWER_DIR/$old" ]; then
    echo "FAIL: old $old still exists"
    results=1
  else
    echo "PASS: old $old removed"
  fi
done

exit $results
```

------

#### Step 3 — Run tests and confirm all pass

```bash
cd /Users/wilbur/project/rawViewer/rawViewer
bash -c '
results=0
for f in services/photoImageService.swift services/photoDisplayService.swift services/photoThumbnailService.swift services/photoTrashService.swift; do
  if [ -f "$f" ]; then echo "PASS: $f"; else echo "FAIL: $f missing"; results=1; fi
done
for old in photoImageService.swift photoDisplayService.swift photoThumbnailService.swift photoTrashService.swift; do
  if [ -f "$old" ]; then echo "FAIL: old $old still exists"; results=1; else echo "PASS: old $old removed"; fi
done
exit $results
'
```

**Expected output:**
```
PASS: services/photoImageService.swift
PASS: services/photoDisplayService.swift
PASS: services/photoThumbnailService.swift
PASS: services/photoTrashService.swift
PASS: old photoImageService.swift removed
PASS: old photoDisplayService.swift removed
PASS: old photoThumbnailService.swift removed
PASS: old photoTrashService.swift removed
```

✅ **Done when:** 所有 8 个检查项输出 PASS。

---

### Task 3: 迁移可复用视图组件

**Goal:** `views/` 目录存在，且 8 个视图相关文件已迁入。

**Files touched:**

- `rawViewer/views/` — 新建目录，存放可复用 UI 组件与独立小页面

------

#### Step 1 — Implement

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

mkdir -p "$RAWVIEWER_DIR/views"

mv "$RAWVIEWER_DIR/metalPhotoView.swift" "$RAWVIEWER_DIR/views/metalPhotoView.swift"
mv "$RAWVIEWER_DIR/photoMetalViewController.swift" "$RAWVIEWER_DIR/views/photoMetalViewController.swift"
mv "$RAWVIEWER_DIR/photoThumbnailView.swift" "$RAWVIEWER_DIR/views/photoThumbnailView.swift"
mv "$RAWVIEWER_DIR/photoThumbnailCellView.swift" "$RAWVIEWER_DIR/views/photoThumbnailCellView.swift"
mv "$RAWVIEWER_DIR/groupCardView.swift" "$RAWVIEWER_DIR/views/groupCardView.swift"
mv "$RAWVIEWER_DIR/groupCollectionViewItem.swift" "$RAWVIEWER_DIR/views/groupCollectionViewItem.swift"
mv "$RAWVIEWER_DIR/startViewController.swift" "$RAWVIEWER_DIR/views/startViewController.swift"
mv "$RAWVIEWER_DIR/progressViewController.swift" "$RAWVIEWER_DIR/views/progressViewController.swift"
```

------

#### Step 2 — Write tests

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

files=(
  "views/metalPhotoView.swift"
  "views/photoMetalViewController.swift"
  "views/photoThumbnailView.swift"
  "views/photoThumbnailCellView.swift"
  "views/groupCardView.swift"
  "views/groupCollectionViewItem.swift"
  "views/startViewController.swift"
  "views/progressViewController.swift"
)
olds=(
  "metalPhotoView.swift"
  "photoMetalViewController.swift"
  "photoThumbnailView.swift"
  "photoThumbnailCellView.swift"
  "groupCardView.swift"
  "groupCollectionViewItem.swift"
  "startViewController.swift"
  "progressViewController.swift"
)

results=0
for f in "${files[@]}"; do
  if [ -f "$RAWVIEWER_DIR/$f" ]; then echo "PASS: $f"; else echo "FAIL: $f missing"; results=1; fi
done
for old in "${olds[@]}"; do
  if [ -f "$RAWVIEWER_DIR/$old" ]; then echo "FAIL: old $old still exists"; results=1; else echo "PASS: old $old removed"; fi
done
exit $results
```

------

#### Step 3 — Run tests and confirm all pass

```bash
cd /Users/wilbur/project/rawViewer/rawViewer
bash -c '
files=("views/metalPhotoView.swift" "views/photoMetalViewController.swift" "views/photoThumbnailView.swift" "views/photoThumbnailCellView.swift" "views/groupCardView.swift" "views/groupCollectionViewItem.swift" "views/startViewController.swift" "views/progressViewController.swift")
olds=("metalPhotoView.swift" "photoMetalViewController.swift" "photoThumbnailView.swift" "photoThumbnailCellView.swift" "groupCardView.swift" "groupCollectionViewItem.swift" "startViewController.swift" "progressViewController.swift")
results=0
for f in "${files[@]}"; do if [ -f "$f" ]; then echo "PASS: $f"; else echo "FAIL: $f missing"; results=1; fi; done
for old in "${olds[@]}"; do if [ -f "$old" ]; then echo "FAIL: old $old still exists"; results=1; else echo "PASS: old $old removed"; fi; done
exit $results
'
```

**Expected output:** 16 行 PASS。

✅ **Done when:** 所有 16 个检查项输出 PASS。

---

### Task 4: 迁移业务页面文件

**Goal:** `groupGrid/`、`browser/`、`duplicate/` 目录存在，且 6 个业务页面文件已迁入对应目录。

**Files touched:**

- `rawViewer/groupGrid/` — 分组网格页面
- `rawViewer/browser/` — 照片浏览页面
- `rawViewer/duplicate/` — 重复对比页面

------

#### Step 1 — Implement

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

mkdir -p "$RAWVIEWER_DIR/groupGrid"
mkdir -p "$RAWVIEWER_DIR/browser"
mkdir -p "$RAWVIEWER_DIR/duplicate"

mv "$RAWVIEWER_DIR/groupGridViewController.swift" "$RAWVIEWER_DIR/groupGrid/groupGridViewController.swift"
mv "$RAWVIEWER_DIR/groupGridViewModel.swift" "$RAWVIEWER_DIR/groupGrid/groupGridViewModel.swift"

mv "$RAWVIEWER_DIR/photoBrowserViewController.swift" "$RAWVIEWER_DIR/browser/photoBrowserViewController.swift"
mv "$RAWVIEWER_DIR/photoBrowserViewModel.swift" "$RAWVIEWER_DIR/browser/photoBrowserViewModel.swift"

mv "$RAWVIEWER_DIR/duplicateCompareViewController.swift" "$RAWVIEWER_DIR/duplicate/duplicateCompareViewController.swift"
mv "$RAWVIEWER_DIR/duplicateCompareViewModel.swift" "$RAWVIEWER_DIR/duplicate/duplicateCompareViewModel.swift"
```

------

#### Step 2 — Write tests

```bash
RAWVIEWER_DIR="/Users/wilbur/project/rawViewer/rawViewer"

files=(
  "groupGrid/groupGridViewController.swift"
  "groupGrid/groupGridViewModel.swift"
  "browser/photoBrowserViewController.swift"
  "browser/photoBrowserViewModel.swift"
  "duplicate/duplicateCompareViewController.swift"
  "duplicate/duplicateCompareViewModel.swift"
)
olds=(
  "groupGridViewController.swift"
  "groupGridViewModel.swift"
  "photoBrowserViewController.swift"
  "photoBrowserViewModel.swift"
  "duplicateCompareViewController.swift"
  "duplicateCompareViewModel.swift"
)

results=0
for f in "${files[@]}"; do
  if [ -f "$RAWVIEWER_DIR/$f" ]; then echo "PASS: $f"; else echo "FAIL: $f missing"; results=1; fi
done
for old in "${olds[@]}"; do
  if [ -f "$RAWVIEWER_DIR/$old" ]; then echo "FAIL: old $old still exists"; results=1; else echo "PASS: old $old removed"; fi
done
exit $results
```

------

#### Step 3 — Run tests and confirm all pass

```bash
cd /Users/wilbur/project/rawViewer/rawViewer
bash -c '
files=("groupGrid/groupGridViewController.swift" "groupGrid/groupGridViewModel.swift" "browser/photoBrowserViewController.swift" "browser/photoBrowserViewModel.swift" "duplicate/duplicateCompareViewController.swift" "duplicate/duplicateCompareViewModel.swift")
olds=("groupGridViewController.swift" "groupGridViewModel.swift" "photoBrowserViewController.swift" "photoBrowserViewModel.swift" "duplicateCompareViewController.swift" "duplicateCompareViewModel.swift")
results=0
for f in "${files[@]}"; do if [ -f "$f" ]; then echo "PASS: $f"; else echo "FAIL: $f missing"; results=1; fi; done
for old in "${olds[@]}"; do if [ -f "$old" ]; then echo "FAIL: old $old still exists"; results=1; else echo "PASS: old $old removed"; fi; done
exit $results
'
```

**Expected output:** 12 行 PASS。

✅ **Done when:** 所有 12 个检查项输出 PASS。

---

### Task 5: 更新 Bridging Header Build Setting

**Goal:** `project.pbxproj` 中的 `SWIFT_OBJC_BRIDGING_HEADER` 从 `rawViewer/rawViewerBridgingHeader.h` 更新为 `rawViewer/bridge/rawViewerBridgingHeader.h`，且两处配置（Debug / Release）均生效。

**Files touched:**

- `rawViewer.xcodeproj/project.pbxproj` — 更新 bridging header 路径

------

#### Step 1 — Implement

使用精确文本替换，修改 project.pbxproj 中两处 `SWIFT_OBJC_BRIDGING_HEADER`：

```
SWIFT_OBJC_BRIDGING_HEADER = rawViewer/rawViewerBridgingHeader.h;
```

替换为：

```
SWIFT_OBJC_BRIDGING_HEADER = rawViewer/bridge/rawViewerBridgingHeader.h;
```

------

#### Step 2 — Write tests

```bash
PROJECT_PBXPROJ="/Users/wilbur/project/rawViewer/rawViewer.xcodeproj/project.pbxproj"

# 验证新路径存在且出现 2 次
count=$(grep -c 'SWIFT_OBJC_BRIDGING_HEADER = rawViewer/bridge/rawViewerBridgingHeader.h;' "$PROJECT_PBXPROJ" || true)
if [ "$count" -eq 2 ]; then
  echo "PASS: new path appears exactly 2 times"
else
  echo "FAIL: new path appears $count times, expected 2"
  exit 1
fi

# 验证旧路径不存在
old_count=$(grep -c 'SWIFT_OBJC_BRIDGING_HEADER = rawViewer/rawViewerBridgingHeader.h;' "$PROJECT_PBXPROJ" || true)
if [ "$old_count" -eq 0 ]; then
  echo "PASS: old path removed"
else
  echo "FAIL: old path still appears $old_count times"
  exit 1
fi
```

------

#### Step 3 — Run tests and confirm all pass

```bash
PROJECT_PBXPROJ="/Users/wilbur/project/rawViewer/rawViewer.xcodeproj/project.pbxproj"

count=$(grep -c 'SWIFT_OBJC_BRIDGING_HEADER = rawViewer/bridge/rawViewerBridgingHeader.h;' "$PROJECT_PBXPROJ" || true)
old_count=$(grep -c 'SWIFT_OBJC_BRIDGING_HEADER = rawViewer/rawViewerBridgingHeader.h;' "$PROJECT_PBXPROJ" || true)

if [ "$count" -eq 2 ] && [ "$old_count" -eq 0 ]; then
  echo "PASS: bridging header path updated correctly"
  exit 0
else
  echo "FAIL: count=$count old_count=$old_count"
  exit 1
fi
```

**Expected output:**
```
PASS: bridging header path updated correctly
```

✅ **Done when:** 测试输出 PASS。

---

### Task 6: 编译验证

**Goal:** `pickpick` target 能通过 `xcodebuild` 编译成功，无文件引用丢失或编译错误。

**Files touched:**

- 无文件修改，仅验证编译

------

#### Step 1 — Implement

无需代码实现；本 Task 为验证 Task。

------

#### Step 2 — Write tests

编译本身就是验证。运行以下命令：

```bash
cd /Users/wilbur/project/rawViewer
xcodebuild -project rawViewer.xcodeproj -scheme pickpick -destination 'platform=macOS' build
```

捕获退出码与输出关键字判断结果。

------

#### Step 3 — Run tests and confirm all pass

```bash
cd /Users/wilbur/project/rawViewer

# 运行构建并捕获输出
if xcodebuild -project rawViewer.xcodeproj -scheme pickpick -destination 'platform=macOS' build 2>&1 | tee /tmp/xcodebuild_rawViewer.log; then
  # 二次确认输出中包含 BUILD SUCCEEDED
  if grep -q "BUILD SUCCEEDED" /tmp/xcodebuild_rawViewer.log; then
    echo "PASS: xcodebuild succeeded"
    exit 0
  else
    echo "FAIL: xcodebuild exit 0 but no BUILD SUCCEEDED found"
    exit 1
  fi
else
  echo "FAIL: xcodebuild failed"
  exit 1
fi
```

**Expected output:** 日志末尾包含 `** BUILD SUCCEEDED **` 并输出 `PASS: xcodebuild succeeded`。

✅ **Done when:** 命令输出 `PASS: xcodebuild succeeded`。

---

## Self-Review Checklist

**1. Spec coverage:**
- [x] 创建分层子目录 — Task 1~4
- [x] 迁移全部 25 个需要移动的文件 — Task 1~4
- [x] 根目录保留 4 个入口/协调文件 + Assets.xcassets + config.yaml — 未列入移动列表即保留
- [x] 更新 bridging header 路径 — Task 5
- [x] 编译验证 — Task 6

**2. Placeholder scan:**
- [x] 无 TBD / TODO / "implement later"
- [x] 所有 bash 命令完整可执行
- [x] 所有文件路径精确

**3. Type / Path consistency:**
- [x] 所有新旧路径与 recipe 方案一致
- [x] `rawViewerBridgingHeader.h` 的新路径为 `rawViewer/bridge/rawViewerBridgingHeader.h`，与 project.pbxproj 更新一致
- [x] bridging header 内部的 `#import "photoAnalyzerBridge.h"` 因两者同级于 `bridge/` 目录，路径关系不变

**4. Test completeness:**
- [x] 每个 Task 的 Step 2 验证了新文件存在 + 旧文件已移除（或配置已更新）
- [x] Task 6 验证编译通过
- [x] 每个 Task 的 ✅ Done 条件明确
