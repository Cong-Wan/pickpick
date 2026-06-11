# Scan 阶段 Config 加载 + 并发性能优化 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 让 config.yaml 被打包进 app bundle 使运行时参数生效，同时提高分析并发度缩短 scan 耗时。

**架构：** 三处改动 — pbxproj 添加 exception set 让 yaml 进入 bundle、yaml 中提高并发值、configLoader 放宽并发上限。

**技术栈：** Xcode project.pbxproj (objectVersion 77 / PBXFileSystemSynchronizedRootGroup)、Swift、YAML。

---

## 涉及的文件

| 文件 | 变更类型 | 职责 |
|------|---------|------|
| `rawViewer.xcodeproj/project.pbxproj` | 修改 | 添加 PBXFileSystemSynchronizedBuildFileExceptionSet，让 config.yaml 被复制进 app bundle |
| `rawViewer/config.yaml` | 修改 | metal_concurrency 从 2 改为 6 |
| `rawViewer/services/configLoader.swift` | 修改 | 并发上限从 4 放宽到 8 |

---

### Task 1: 修改 project.pbxproj — 将 config.yaml 加入 Bundle Resources

**目标：** Xcode 构建时将 `rawViewer/config.yaml` 复制进 `pickpick.app/Contents/Resources/`，使运行时 `Bundle.main.url(forResource: "config", withExtension: "yaml")` 返回有效 URL。

**涉及的文件：**

- `rawViewer.xcodeproj/project.pbxproj` — 项目构建配置

---

#### Step 1 — 实现

对 `rawViewer.xcodeproj/project.pbxproj` 做两处精确编辑：

**编辑 A：** 在 `PBXFileSystemSynchronizedRootGroup` section 中，给 rawViewer 组添加 `exceptions` 字段。

将：
```
/* Begin PBXFileSystemSynchronizedRootGroup section */
		D8DB71322FC92FEA00F93F82 /* rawViewer */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = rawViewer;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```

替换为：
```
/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		D8CF00012FC92FEA00F93001 /* Exceptions for "rawViewer" folder in "pickpick" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				config.yaml,
			);
			target = D8DB712F2FC92FEA00F93F82 /* pickpick */;
		};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		D8DB71322FC92FEA00F93F82 /* rawViewer */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				D8CF00012FC92FEA00F93001 /* Exceptions for "rawViewer" folder in "pickpick" target */,
			);
			path = rawViewer;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */
```

注意：新 section `PBXFileSystemSynchronizedBuildFileExceptionSet` 必须插入在 `PBXFileSystemSynchronizedRootGroup` section **之前**，因为 pbxproj 中对象的引用顺序不影响功能，但保持 Xcode 的习惯排序更安全。

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **

$ find ~/Library/Developer/Xcode/DerivedData -name "config.yaml" -path "*/pickpick.app/*" 2>/dev/null
# 预期：输出 pickpick.app/Contents/Resources/config.yaml 的路径
```

如果 BUILD SUCCEEDED 且能在构建产物中找到 config.yaml，说明修改正确。

---

✅ **完成的标志：** xcodebuild 构建成功，且 `pickpick.app/Contents/Resources/config.yaml` 存在。

---

### Task 2: 修改 config.yaml — 提高并发度

**目标：** 将 `metal_concurrency` 从 2 提高到 6，使分析流水线同时处理更多文件。

**涉及的文件：**

- `rawViewer/config.yaml` — 分析参数配置

---

#### Step 1 — 实现

在 `rawViewer/config.yaml` 中，将：

```yaml
  metal_concurrency: 2
```

替换为：

```yaml
  metal_concurrency: 6
```

---

#### Step 2 — 运行验证

```bash
$ grep "metal_concurrency" /Users/wilbur/project/rawViewer/rawViewer/config.yaml
# 预期输出：  metal_concurrency: 6
```

---

✅ **完成的标志：** config.yaml 中 metal_concurrency 值为 6。

---

### Task 3: 修改 configLoader — 放宽并发上限

**目标：** configLoader 中将 metalConcurrency 的安全上限从 4 放宽到 8，否则 Task 2 中设置的 6 会被截断为 4。

**涉及的文件：**

- `rawViewer/services/configLoader.swift` — 配置加载与校验

---

#### Step 1 — 实现

在 `rawViewer/services/configLoader.swift` 中，将：

```swift
        let concurrency = min(max(rawConcurrency, 1), 4)
```

替换为：

```swift
        let concurrency = min(max(rawConcurrency, 1), 8)
```

---

#### Step 2 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **
```

---

✅ **完成的标志：** 构建成功，configLoader 中上限为 8。

---

### Task 4: 集成验证

**目标：** 端到端确认三项改动全部生效：config.yaml 在 bundle 中、并发参数正确读取。

**涉及的文件：**

- 无新文件，验证 Task 1-3 的产物。

---

#### Step 1 — 运行验证

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug build 2>&1 | tail -5
# 预期：** BUILD SUCCEEDED **

$ CONFIG_IN_BUNDLE=$(find ~/Library/Developer/Xcode/DerivedData -name "config.yaml" -path "*/pickpick.app/*" 2>/dev/null | head -1)
$ echo "Bundle config: $CONFIG_IN_BUNDLE"
# 预期：输出非空路径

$ grep "metal_concurrency" "$CONFIG_IN_BUNDLE"
# 预期输出：  metal_concurrency: 6

$ grep "min(max" /Users/wilbur/project/rawViewer/rawViewer/services/configLoader.swift
# 预期输出包含：), 8)
```

---

✅ **完成的标志：** 构建成功、bundle 中 config.yaml 存在且值为 6、configLoader 上限为 8。
