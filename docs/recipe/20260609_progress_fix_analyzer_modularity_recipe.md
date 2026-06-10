# rawViewer 进度修复与分析器模块化设计

## Date: 2026-06-09

---

## 1. 问题陈述

### 1.1 进度条卡在 10%
选择新文件夹后，UI 显示 "Converting RAW 10%" 并卡很长时间，随后瞬间跳到下一阶段。

**根因**：`appRunner.cpp` 的两个线程池阶段（RAW 转换 + 分析）采用以下模式：

```
pool.waitUntilFinished();          // 阻塞，进度不更新
while (pool.tryPopResult(...)) {   // 完成后一次性消费所有结果
    emitStageProgress(...);        // 进度在这里连发，瞬间跳完
}
```

`waitUntilFinished()` 阻塞期间没有任何进度回调，导致用户看到固定百分比；全部任务完成后 `while` 循环一次性弹出所有结果，进度瞬间从阶段起点冲到阶段终点。

### 1.2 图片分析器缺乏扩展性
当前 `ImageAnalyzer::analyze()` 直接硬编码调用 `analyzeWithMacMetal()`：

```cpp
AnalyzeResult ImageAnalyzer::analyze(...) const {
    return analyzeWithMacMetal(task, config);
}
```

用户计划后续引入**完全不同的分析算法**，但当前没有接口边界，新增算法必须修改 `ImageAnalyzer` 内部，侵入性强。

---

## 2. 设计目标

| 目标 | 约束 |
|---|---|
| 进度实时更新 | 每完成一张照片即时回调，不阻塞在 `waitUntilFinished` |
| 分析器可插拔 | 后续加新算法时零侵入现有代码 |
| 改动最小化 | 不改 ThreadPool、不改 AppConfig、不改分析算法本身 |
| 测试友好 | 分析器接口可 mock，进度回调可断言 |

---

## 3. 方案：进度修复 + IAnalyzer 纯虚接口

### 3.1 IAnalyzer 接口（新增）

```cpp
// cpp/include/iAnalyzer.h
#pragma once
#include "imageAnalyzer.h"

class IAnalyzer {
public:
    virtual ~IAnalyzer() = default;
    virtual AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) = 0;
};
```

### 3.2 MacMetalAnalyzer 实现（改造现有）

将 `macImageAnalyzer.h/.mm` 中的自由函数 `analyzeWithMacMetal` 封装为类：

```cpp
// cpp/include/macImageAnalyzer.h
#include "iAnalyzer.h"

class MacMetalAnalyzer : public IAnalyzer {
public:
    AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) override;
};
```

`macImageAnalyzer.mm` 只需把函数体包进 `MacMetalAnalyzer::analyze`。

### 3.3 AppRunner 依赖注入改造

```cpp
// 改前
using AnalyzeFn = std::function<AnalyzeResult(const AnalyzeTask&, const AppConfig&)>;
AppRunner(RawConvertFn converter, AnalyzeFn analyzer);
AnalyzeFn analyzeFn_;

// 改后
AppRunner(RawConvertFn converter, std::unique_ptr<IAnalyzer> analyzer);
std::unique_ptr<IAnalyzer> analyzer_;
```

内部调用：`analyzer_->analyze(task, config)`

### 3.4 进度修复（两个线程池阶段）

**RAW 转换阶段**

改前：
```cpp
pool.waitUntilFinished();
RawConvertResult rcResult;
while (pool.tryPopResult(rcResult)) {
    // ...处理并 emit
}
```

改后：
```cpp
for (int i = 0; i < rawTotalCount; ++i) {
    RawConvertResult rcResult = pool.waitPopResult();
    // ...处理并 emit（每完成一张即时更新）
}
```

**分析阶段** 同理，改为 `for (int i = 0; i < analysisTotalCount; ++i) + pool.waitPopResult()`。

---

## 4. 文件变更清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `cpp/include/iAnalyzer.h` | **新增** | 纯虚接口定义 |
| `cpp/include/macImageAnalyzer.h` | 修改 | 自由函数 → `MacMetalAnalyzer` 类声明 |
| `cpp/src/macImageAnalyzer.mm` | 修改 | 函数体包进类方法 |
| `cpp/include/appRunner.h` | 修改 | `AnalyzeFn` → `std::unique_ptr<IAnalyzer>` |
| `cpp/src/appRunner.cpp` | 修改 | 进度修复 + `analyzeFn_` → `analyzer_->analyze` |
| `cpp/main.cpp` | 修改 | 注入 `std::make_unique<MacMetalAnalyzer>` |

---

## 5. 数据流

```
[AppRunner::run]
  ├── 阶段1: Scanning (0% → 10%)
  ├── 阶段2: RawConversion (10% → 45%)
  │     └── ThreadPool<RawConvertTask, RawConvertResult>
  │           └── for i in 0..N-1: pool.waitPopResult() → 即时 emit
  ├── Re-plan + 阶段3: Analysis (45% → 90%)
  │     └── ThreadPool<AnalyzeTask, AnalyzeResult>
  │           └── for i in 0..N-1: pool.waitPopResult() → 即时 emit
  │                 └── analyzer_->analyze(task, config)   // IAnalyzer 接口
  ├── 阶段4: Organizing (90% → 98%)
  └── 阶段5: Completed (100%)
```

---

## 6. 错误处理

- `pool.waitPopResult()` 内部使用 `resultCv_.wait`，线程池停止时会正常返回（worker 完成全部任务后 `finishedCv_` 已通知，不会死等）。
- `AppRunner` 析构或异常退出时，需确保 `pool.stop()` 被调用（已有）。
- `IAnalyzer` 实现类异常：由 `workerLoop` 捕获或终止 worker，结果队列中不会收到该任务结果。当前行为与改前一致。

---

## 7. 测试策略

| 测试项 | 方法 |
|---|---|
| 进度回调次数 | mock `progressCallback`，断言回调次数 == totalCount |
| 进度单调递增 | 断言每次回调的 `overallProgress` 严格递增（或 >= 前一次） |
| IAnalyzer 委托 | mock `IAnalyzer` 子类，注入到 `AppRunner`，验证 `analyze()` 被正确调用且结果回写 JSON |

---

## 8. 扩展路径：后续加新算法

```cpp
// 新增一个分析器实现，零侵入现有代码
class MyNewAnalyzer : public IAnalyzer {
public:
    AnalyzeResult analyze(const AnalyzeTask& task, const AppConfig& config) override;
};

// main.cpp 里换一行即可
AppRunner runner(converter, std::make_unique<MyNewAnalyzer>());
```

---

## 9. Spec Self-Review

- **Placeholder scan**: 无 TBD/TODO。
- **内部一致性**: `IAnalyzer` 接口依赖 `imageAnalyzer.h` 中的类型，这些类型不会被删除。`AppRunner` 的 `RawConvertFn` 保持不变，仅替换分析器侧。
- **Scope check**: 聚焦在进度修复 + 分析器接口抽象，不涉及 ThreadPool 改造、不涉及 AppConfig 加字段、不涉及新算法实现本身。
- **Ambiguity check**: `waitPopResult()` 是 ThreadPool 已有方法，非阻塞等结果，语义明确。
