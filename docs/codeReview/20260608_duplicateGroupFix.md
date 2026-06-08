## 代码审核报告 — 重复分组逻辑修复

### 总览
- **审核文件**: 4 个（2 个实现 + 2 个测试）
- **发现问题**: 🔴 0 个 / 🟠 0 个 / 🟡 1 个 / 🔵 2 个
- **整体评价**: 实现逻辑正确，测试覆盖充分。存在一处已存在的历史遗留行为在本次修改后更易触发，建议记录但不强制在本次修复。

---

### 问题清单

### 🟡 Medium — orphan 照片可能同时进入多个常规分组

**位置**: `rawViewer/photoModels.swift` — `makeVisiblePhotoGroups` 函数
**问题**: 当一张 orphan 照片（单张重复组）同时满足多个常规分组条件时（例如 `isBlurry == true` 且 `exposureStatus == "overexposed"`），它会被同时归入 `blurry` 和 `overexposed` 两个分组。这在原始代码中也存在（只要 `reviewGroupId.isEmpty`），但本次修改后更多照片会被归入常规分组，使得该问题更易触发。虽然当前 UI 可能不会出现这种极端重叠，但数据模型层面存在一张照片在多个 group 中重复出现的隐患。
**修复方案**: 这不是本次 bug 修复的引入问题，也不影响当前核心功能。如需修复，可引入优先级机制（如 blurry > exposure > normal），但建议作为独立优化任务处理。

---

### 🔵 Low — `markFinalKept` 语义在 `case 1` 中不一致

**位置**: `rawViewer/duplicateCompareViewModel.swift` — `keepBoth` 方法 `case 1` 分支
**问题**: `case 1` 中调用 `markFinalKept(last)`，如果该照片的 `reviewGroupId` 非空，会将 `templatePhotoId` 设为 `last.photoId`（即最后一张照片自己）。而 `default` 分支中 `setTemplate` 使用的是用户选择的 `templatePhotoId`。两者的模板设定逻辑不一致，但从业务角度这是合理的（单张时无用户选择，只能以自己为模板）。
**修复方案**: 无需修复，当前行为符合产品逻辑。

---

### 🔵 Low — `keepBoth` 中 `mainPhoto` 在 `default` 分支的读取时机

**位置**: `rawViewer/duplicateCompareViewModel.swift` — `keepBoth` 方法 `default` 分支
**问题**: `default` 分支中 `mainPhoto` 是在 `photos.removeAll` 之后、但 `mainIndex` 更新之前读取的。此时 `mainIndex` 仍是旧值（0），而 `photos` 已移除前两张。如果原始 `mainIndex` 不是 0（虽然当前代码中 `keepBoth` 总是在 `mainIndex=0` 时被调用，但未来如果有跳转逻辑），`mainPhoto` 可能指向错误的照片。
**修复方案**: 为增强防御性，可将 `mainIndex` 更新提前到 `setTemplate` 之前：

```swift
mainIndex = 0
if let groupId = photos.first?.reviewGroupId, !groupId.isEmpty {
    try store.setTemplate(reviewGroupId: groupId, templatePhotoId: templatePhotoId)
}
candidateIndex = min(1, photos.count - 1)
return .continueComparing
```

但当前代码在此场景下行为正确，可不改。

---

### 优点记录

1. **`makeVisiblePhotoGroups` 的过滤逻辑清晰兜底**: 通过 `validDuplicateIds` 一次性计算， orphan 照片自然流入常规分组，避免了零散的特殊判断。
2. **`keepBoth` 的三分支 `switch` 语义明确**: `0/1/default` 三种情况分别对应 finished/auto-finish/continue，逻辑边界清晰，测试容易覆盖。
3. **测试覆盖了关键边界**: 包括单张 orphan 的三种属性路径、2/3/4/5 张 keepBoth、混用 keepLeft+keepBoth。

---

### 修复优先级建议

| 优先级 | 问题 | 原因 |
|-------|------|------|
| P1 | 🟡 orphan 重复进入多个分组 | 数据模型层面的隐患，虽不崩溃但可能导致 UI 展示异常；建议在后续迭代中统一处理照片分类优先级 |
| P2 | 🔵 `mainPhoto` 读取时机 | 防御性编程，当前无实际 bug，但可提升代码健壮性 |
