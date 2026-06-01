# Worker 线程栈溢出修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `ThreadPool` worker 线程的栈从 macOS 默认的 512 KB 提到 8 MB，消除在真实 RAW 转换路径上的 `SIGBUS`，并通过轻量测试和端到端回归确认修复。

**Architecture:** 把 `cpp/include/threadPool.h` 内部从 `std::thread` 切换到 `pthread` API：用 `pthread_attr_t` + `pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)` 创建 worker，用 `static void* workerEntry(void*)` 的 trampoline 模式把 lambda 拆出来；`workers_` 容器从 `std::vector<std::thread>` 改为 `std::vector<pthread_t>`，`stop()` 用 `pthread_join`。栈大小提取为 `static constexpr size_t kWorkerStackSize` 常量，便于单元测试断言。`appRunner.cpp` / `rawConverter.cpp` / `imageAnalyzer.cpp` 都不动。

**Tech Stack:** C++17、`<pthread.h>`（macOS/Linux 原生）、CMake。**不**引入任何新测试框架，**不**写任何新的测试代码；所有验证靠直接跑 `rawViewer` 真实数据。

---

## 1. 文件结构总览

### 1.1 修改的运行代码

| 路径 | 责任 |
| --- | --- |
| `cpp/include/threadPool.h` | 模板 ThreadPool 改 pthread + 8MB 栈；`workers_` 改 `std::vector<pthread_t>`；加 trampoline；加 `kWorkerStackSize` 常量 |

### 1.2 新增文件

| 路径 | 责任 |
| --- | --- |
| `docs/flare/20260601_fix_worker_stack_overflow.md` | 本计划文件 |

### 1.3 文档更新

| 路径 | 责任 |
| --- | --- |
| `docs/recipe/photo-analyzer-design.md` | 在"技术约束"或"线程池"小节补充"worker 线程栈必须 ≥ 8 MB" |

---

## 2. 非协商约束

- **不**改 `appRunner.cpp` / `rawConverter.cpp` / `imageAnalyzer.cpp` / `jsonManager.cpp` / `configLoader.cpp` / `resumePlanner.cpp` / `fileScanner.cpp` / `taskState.cpp` 的任何业务逻辑。
- **不**改 `config.yaml`。
- **不**把 `ThreadPool` 的 public 接口（`pushTask` / `tryPopResult` / `waitPopResult` / `waitUntilFinished` / `stop`）的签名改成不向后兼容。
- **不**引入新第三方依赖（GTest、Boost 等）。
- **不**写任何新的测试代码：不写 C++ 测试入口（`testMain.cpp` / `testAssert.h`）、不写线程池单元测试（`threadPoolTests.cpp`）、不写 shell 集成测试脚本（`integration_test.sh`）、不写 mock / fixture / test data 构造工具。所有验证靠 `cd cpp && ./build/rawViewer <真实数据目录>` 直接跑，目视检查输出、退出码、产物 JSON。
- **不**改 `cpp/CMakeLists.txt`（macOS 上 pthread 是系统默认库，无需新增 link 配置；编译会自然过）。
- 栈大小必须是 8 MB（`8 * 1024 * 1024` 字节），不是"调到 4 MB 试试"。理由写在 BUG 文档 §5。
- `ThreadPool` 必须保持模板类（因为 `appRunner.cpp` 用 `ThreadPool<RawConvertTask, RawConvertResult>` 和 `ThreadPool<AnalyzeTask, AnalyzeResult>` 两个实例）。
- worker 数量保持 4（`config.yaml` 的 `worker_count` 注释已说明强制 4）。
- 不在 plan 中添加 git / commit / push 相关步骤。

---

## Task 0: Environment Setup

**Goal:** 确认项目能 baseline 编译并跑起来，且 `pthread` 头文件可用，作为修复的基线。

**Files touched:** 无业务文件。

### Step 1 — 验证工作目录

```bash
$ cd /Users/wilbur/project/rawViewer && pwd
# Expected: /Users/wilbur/project/rawViewer

$ test -d cpp/include && test -d cpp/src && echo "OK cpp layout"
# Expected: OK cpp layout

$ test -f cpp/CMakeLists.txt && echo "OK CMakeLists.txt"
# Expected: OK CMakeLists.txt

$ test -f cpp/include/threadPool.h && echo "OK threadPool.h"
# Expected: OK threadPool.h
```

### Step 2 — 验证 pthread 头文件可用

```bash
$ echo '#include <pthread.h>
int main(){ pthread_attr_t a; pthread_attr_init(&a); pthread_attr_destroy(&a); return 0; }' \
  > /tmp/pthread_check.cpp

$ c++ -std=c++17 /tmp/pthread_check.cpp -pthread -o /tmp/pthread_check && /tmp/pthread_check
# Expected: 无输出，退出码 0
```

如果 `c++` 编译器找不到 `<pthread.h>` 或 `pthread_attr_init`，说明当前 macOS 缺少命令行工具，停止本计划，先安装 `xcode-select --install` 再继续。

### Step 3 — 验证 baseline 构建产物存在

```bash
$ test -x /Users/wilbur/project/rawViewer/cpp/build/rawViewer && echo "OK rawViewer"
# Expected: OK rawViewer
```

如果不存在，跑一次构建以建立基线（不视为修改代码）：

```bash
$ cd /Users/wilbur/project/rawViewer/cpp/build && cmake --build . -j
# Expected: [100%] Built target rawViewer
```

### Step 4 — 验证 baseline 行为：跑空目录

```bash
$ mkdir -p /tmp/rawview_baseline_empty
$ /Users/wilbur/project/rawViewer/cpp/build/rawViewer /tmp/rawview_baseline_empty
# Expected: 输出 Summary 块；进程退出码 0
```

记下 exit code：

```bash
$ echo "baseline exit=$?"
# Expected: baseline exit=0
```

### Step 5 — 复现 baseline 必崩 SIGBUS（修复前的已知状态）

> 本步不修改任何代码，只为了在 plan 里留下"修复前必然崩 SIGBUS"的可观察证据，让 Task 2 的判定标准（exit 不能是 138）不是空话。跑完这步会生成半成品 `.cache/analysis.json`，Task 2 Step 0 会清掉。

测试数据：`/Users/wilbur/Downloads/LUMIX_Backup/`（BUG 文档 §2 表格中的 clean_test 场景：220 个文件 = 62 JPG + 158 RW2）。

```bash
$ rm -rf /Users/wilbur/Downloads/LUMIX_Backup/.cache
$ /Users/wilbur/project/rawViewer/cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup 2>&1 | tail -20
$ echo "baseline exit=$?"
# Expected:
#   包含 "[trace] RAW loop i=2 id=P1000268 post-getState" 后的乱序输出或截断
#   shell 报 "Bus error: 10"
#   baseline exit=138
```

判定：
- `exit` 必须 138（SIGBUS）
- 输出中出现 `Bus error: 10`
- 跟 BUG 文档 §3.2 的 trace 截断现象完全一致（i=0/i=1 正常，i=2 崩）

### ✅ Done when

- Step 1 ~ 4 全部通过，输出符合预期。
- Step 5 跑出 `exit=138` + `Bus error: 10`。
- `cpp/build/rawViewer` 可执行文件存在。
- 进程能正常处理空目录。
- 已确认 baseline 必崩 SIGBUS，让 Task 2 修复后 "exit=0" 的判定有可对比基线。

如果 baseline 构建或运行失败，先解决环境问题再进入 Task 1。

---

## Task 1: 重构 ThreadPool 使用 pthread + 8MB 栈

**Goal:** `ThreadPool` 的 4 个 worker 在创建时使用 8 MB 栈（不是 macOS 默认的 512 KB），通过 `pthread` API 实现；`pushTask` / `tryPopResult` / `waitPopResult` / `waitUntilFinished` / `stop` 的对外行为不变；栈大小是 `static constexpr size_t kWorkerStackSize = 8 * 1024 * 1024`。

**Files touched:**
- `cpp/include/threadPool.h` — 模板 ThreadPool 改用 pthread；模板实现全部在头文件，**这一个文件就完成所有改动**

### Step 1 — 替换 `cpp/include/threadPool.h`

完整重写为以下内容（替换整个文件）：

```cpp
/*
 * Author: wilbur
 * Version: 2.0
 * Date: 2026-06-01
 * Description: 实现模板化固定 4 worker 共享队列线程池；改用 pthread 创建 worker 并显式设置 8 MB 栈，
 *              修复 macOS 上默认 512 KB 栈被 RAW 转换调用链打爆导致的 SIGBUS（详见
 *              docs/20260601_worker_thread_stack_overflow.md）。模板逻辑全部在头文件。
 */

#pragma once

#include <functional>
#include <queue>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <cstddef>
#include <stdexcept>
#include <pthread.h>

template <typename Task, typename Result>
class ThreadPool {
public:
    using TaskHandler = std::function<Result(const Task&)>;

    // 每个 worker 线程的栈大小（字节）。设为 8 MB 与主线程对齐，
    // 给 LibRaw + OpenCV JPEG encoder + std::function 调用链留 8 倍余量。
    // 不要轻易改小，见 docs/20260601_worker_thread_stack_overflow.md §5。
    static constexpr size_t kWorkerStackSize = 8 * 1024 * 1024;

    static constexpr int kWorkerCount = 4;

    explicit ThreadPool(TaskHandler handler)
        : handler_(std::move(handler)), stopped_(false), activeTasks_(0) {
        // 启动前预留 pthread_t 槽位
        workerIds_.resize(kWorkerCount);

        for (int i = 0; i < kWorkerCount; ++i) {
            pthread_attr_t attr;
            int rc = pthread_attr_init(&attr);
            if (rc != 0) {
                throw std::runtime_error("pthread_attr_init failed");
            }

            // 设置栈大小
            rc = pthread_attr_setstacksize(&attr, kWorkerStackSize);
            if (rc != 0) {
                pthread_attr_destroy(&attr);
                throw std::runtime_error("pthread_attr_setstacksize failed");
            }

            // 设置 joinable（pthread 默认就是 joinable，但显式设置更稳）
            rc = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
            if (rc != 0) {
                pthread_attr_destroy(&attr);
                throw std::runtime_error("pthread_attr_setdetachstate failed");
            }

            WorkerContext* ctx = new WorkerContext{this, i};

            rc = pthread_create(&workerIds_[i], &attr, &ThreadPool::workerEntry, ctx);
            pthread_attr_destroy(&attr);
            if (rc != 0) {
                delete ctx;
                throw std::runtime_error("pthread_create failed");
            }
        }
    }

    ~ThreadPool() {
        stop();
    }

    void pushTask(const Task& task) {
        {
            std::unique_lock<std::mutex> lock(taskMutex_);
            taskQueue_.push(task);
        }
        taskCv_.notify_one();
    }

    bool tryPopResult(Result& result) {
        std::unique_lock<std::mutex> lock(resultMutex_);
        if (resultQueue_.empty()) {
            return false;
        }
        result = resultQueue_.front();
        resultQueue_.pop();
        return true;
    }

    Result waitPopResult() {
        std::unique_lock<std::mutex> lock(resultMutex_);
        resultCv_.wait(lock, [this]() { return !resultQueue_.empty(); });
        Result result = resultQueue_.front();
        resultQueue_.pop();
        return result;
    }

    void waitUntilFinished() {
        std::unique_lock<std::mutex> lock(taskMutex_);
        finishedCv_.wait(lock, [this]() { return taskQueue_.empty() && activeTasks_ == 0; });
    }

    void stop() {
        {
            std::unique_lock<std::mutex> lock(taskMutex_);
            if (stopped_) return;
            stopped_ = true;
        }
        taskCv_.notify_all();
        for (auto& worker : workerIds_) {
            if (worker != 0) {
                pthread_join(worker, nullptr);
                worker = 0;
            }
        }
    }

private:
    // worker 入口上下文：把 this 指针带给静态 trampoline
    struct WorkerContext {
        ThreadPool* self;
        int workerIndex;
    };

    // pthread 入口必须是 `void*(void*)` 签名的静态/自由函数
    static void* workerEntry(void* arg) {
        WorkerContext* ctx = static_cast<WorkerContext*>(arg);
        ThreadPool* pool = ctx->self;
        int idx = ctx->workerIndex;
        delete ctx;
        pool->workerLoop(idx);
        return nullptr;
    }

    void workerLoop(int /*workerIndex*/) {
        while (true) {
            Task task;
            {
                std::unique_lock<std::mutex> lock(taskMutex_);
                taskCv_.wait(lock, [this]() { return stopped_ || !taskQueue_.empty(); });
                if (stopped_ && taskQueue_.empty()) {
                    return;
                }
                task = taskQueue_.front();
                taskQueue_.pop();
                activeTasks_++;
            }
            Result result = handler_(task);
            {
                std::unique_lock<std::mutex> lock(resultMutex_);
                resultQueue_.push(std::move(result));
            }
            {
                std::unique_lock<std::mutex> lock(taskMutex_);
                activeTasks_--;
                if (taskQueue_.empty() && activeTasks_ == 0) {
                    finishedCv_.notify_all();
                }
            }
            resultCv_.notify_one();
            taskCv_.notify_one();
        }
    }

    TaskHandler handler_;
    std::vector<pthread_t> workerIds_;
    std::queue<Task> taskQueue_;
    std::queue<Result> resultQueue_;
    std::mutex taskMutex_;
    std::mutex resultMutex_;
    std::condition_variable taskCv_;
    std::condition_variable resultCv_;
    std::condition_variable finishedCv_;
    bool stopped_;
    size_t activeTasks_;
};
```

### Step 2 — 编译验证模板在翻译单元里能正常实例化

```bash
$ cd /Users/wilbur/project/rawViewer/cpp/build && cmake --build . -j 2>&1 | tail -30
# Expected:
#   [ 88%] Building CXX object CMakeFiles/rawViewer.dir/src/appRunner.cpp.o
#   [ 90%] Building CXX object CMakeFiles/rawViewer.dir/src/threadPool.cpp.o
#   [ 92%] Linking CXX executable rawViewer
#   [100%] Built target rawViewer
```

如果出现以下任何一种错误，**先排查再继续**：
- `pthread_create` / `pthread_join` 链接失败 → 在主 CMakeLists.txt 的 `target_link_libraries(rawViewer PRIVATE ...)` 后追加 `${CMAKE_THREAD_LIBS_HINT}` 都不够时，需改为 `find_package(Threads REQUIRED)` + `Threads::Threads`。
- `workerLoop` 找不到 → 检查 `workerEntry` 里的 `pool->workerLoop(idx)` 调用是否漏了 `this->` 之外的可见性（本文件全在 `private:` 后，类内可见，OK）。
- 模板未实例化错误 → 不应该出现，因为 `appRunner.cpp` 已经实例化了 `ThreadPool<RawConvertTask, RawConvertResult>` 和 `ThreadPool<AnalyzeTask, AnalyzeResult>`。

### Step 3 — 不依赖真 RAW 跑空目录，验证未引入回归

```bash
$ mkdir -p /tmp/rawview_task1_empty
$ /Users/wilbur/project/rawViewer/cpp/build/rawViewer /tmp/rawview_task1_empty
# Expected: 输出 Summary 块（totalPhotos=0），进程退出码 0
$ echo "exit=$?"
# Expected: exit=0
```

### ✅ Done when

- `cpp/include/threadPool.h` 全文已替换。
- 编译通过，没有 link 错误，没有 warning 上升（保留现有 warning 水平即可）。
- 空目录跑通，退出码 0。

---

## Task 2: 用真实数据回归验证

**Goal:** 跑 BUG 文档 §2 表格中所有能复现的场景（空目录、1 张 JPG、含真实 RAW 的混合文件夹），验证进程不再 SIGBUS、退出码 0、产物 JSON 状态正确。

**Files touched:** 无代码改动（这是验证任务）。

> **本任务不写任何新的测试代码**。所有验证都通过 `cd cpp && ./build/rawViewer <真实数据目录>` 直接跑，目视检查输出、退出码、产物 JSON 即可。

### Step 1 — 准备测试数据目录

测试数据源：`/Users/wilbur/Downloads/LUMIX_Backup/`（BUG 文档 §2 表格中的 clean_test 场景：220 个文件 = 62 JPG + 158 RW2）。

先清掉 Task 0 Step 5 跑崩时生成的半成品 `.cache/analysis.json`，避免干扰修复后的运行：

```bash
$ rm -rf /Users/wilbur/Downloads/LUMIX_Backup/.cache
$ ls /Users/wilbur/Downloads/LUMIX_Backup/.cache 2>&1
# Expected: ls: /Users/wilbur/Downloads/LUMIX_Backup/.cache: No such file or directory
```

再准备 3 个临时小场景目录：

```bash
$ mkdir -p /tmp/rawview_verify/{empty,one_jpg,one_raw}
$ ls /tmp/rawview_verify
# Expected: empty  one_jpg  one_raw
```

填入数据：

- `empty` — 保持空
- `one_jpg` — 从 LUMIX_Backup 复制 1 张 JPG
- `one_raw` — 从 LUMIX_Backup 复制 1 张真 `.RW2`（与 BUG 文档 §3.2 的 trace i=0 起点 `P1000250.RW2` 保持一致）
- `mix` — 直接用 `/Users/wilbur/Downloads/LUMIX_Backup` 本身（不复制，节省 30+ GB 磁盘空间和 1 小时 IO）

```bash
$ cp /Users/wilbur/Downloads/LUMIX_Backup/P1000027.JPG /tmp/rawview_verify/one_jpg/
$ cp /Users/wilbur/Downloads/LUMIX_Backup/P1000250.RW2 /tmp/rawview_verify/one_raw/
$ ls /tmp/rawview_verify/empty /tmp/rawview_verify/one_jpg /tmp/rawview_verify/one_raw
# Expected:
#   /tmp/rawview_verify/empty:   （无文件）
#   /tmp/rawview_verify/one_jpg: P1000027.JPG
#   /tmp/rawview_verify/one_raw: P1000250.RW2
```

**注意**：`mix` 场景直接用 `/Users/wilbur/Downloads/LUMIX_Backup`，不复制。修复后跑这一个会完整消费 106 个 RAW + 62 个 JPG。任务结束时 `.cache/analysis.json` 会更新到全部 `success` 状态。

### Step 2 — 跑空目录场景（回归基线）

```bash
$ cd /Users/wilbur/project/rawViewer/cpp && \
  ./build/rawViewer /tmp/rawview_verify/empty
# Expected: 输出 Summary 块（totalPhotos=0）；进程不 SIGBUS
$ echo "exit=$?"
# Expected: exit=0
```

判定：
- `exit` 必须 0，**不是 138**（SIGBUS）
- 进程不崩
- 退出后 `/tmp/rawview_verify/empty/.cache/analysis.json` 存在

### Step 3 — 跑 1 张 JPG 场景

```bash
$ cd /Users/wilbur/project/rawViewer/cpp && \
  ./build/rawViewer /tmp/rawview_verify/one_jpg
# Expected: 输出 Summary 块（Total photos=1, RAW conversion success=0, Analysis success=1）
$ echo "exit=$?"
# Expected: exit=0

$ ls /tmp/rawview_verify/one_jpg/.cache/
# Expected: analysis.json 存在；converted/ 不存在或为空

$ cat /tmp/rawview_verify/one_jpg/.cache/analysis.json | python3 -m json.tool | head -30
# Expected: 合法 JSON，含 1 条 photo 记录
```

判定：
- `exit` 必须 0
- JSON 中该 JPG 的 `analysis_status = "success"`

### Step 4 — 跑 1 张真 RAW 场景（**关键回归**）

```bash
$ cd /Users/wilbur/project/rawViewer/cpp && \
  ./build/rawViewer /tmp/rawview_verify/one_raw 2>&1 | tail -20
$ echo "exit=$?"
# Expected: exit=0
```

判定：
- `exit` 必须 0，**绝对不能是 138**（这是关键：单张 RAW 走的是 512 KB 栈爆的代码路径，修复前必然 SIGBUS）
- `/tmp/rawview_verify/one_raw/.cache/converted/` 下应有 1 个 `<photoId>.JPG` 文件
- JSON 中该 photo 的 `raw_conversion_status = "success"`

```bash
$ ls /tmp/rawview_verify/one_raw/.cache/converted/
# Expected: 1 个 .JPG 文件

$ python3 -c "
import json
d = json.load(open('/tmp/rawview_verify/one_raw/.cache/analysis.json'))
ok = all(p.get('raw_conversion_status') == 'success' for p in d['photos'].values())
print('all raw_conversion_status success:', ok)
"
# Expected: all raw_conversion_status success: True
```

如果 `exit=138`，立刻停，回到 Task 1 排查栈配置（`kWorkerStackSize` 是不是 8 MB、`pthread_attr_setstacksize` 调用是否成功）。

### Step 5 — 跑混合真实场景（BUG 文档原崩溃命令）

直接用 `/Users/wilbur/Downloads/LUMIX_Backup`，不复制：

```bash
$ cd /Users/wilbur/project/rawViewer/cpp && \
  ./build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup 2>&1 | tail -25
$ echo "exit=$?"
# Expected: exit=0
```

判定：
- `exit` 必须 0
- Summary 中 `raw_conversion_success` 应等于 106（BUG 文档 §1 明确给的数字，"raw=106 ana=62"）
- Summary 中 `analysis_success` 应等于 168（62 张原始 JPG + 106 张 RAW 转出 JPG 全部进入分析阶段）
- 全程不再出现 `Bus error: 10`

验证产物：

```bash
$ ls /Users/wilbur/Downloads/LUMIX_Backup/.cache/converted/ | wc -l
# Expected: 数字 > 0（应等于 106，只转 RAW）

$ python3 -c "
import json
d = json.load(open('/Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.json'))
photos = d['photos']
total = len(photos)
raw_ok = sum(1 for p in photos.values() if p.get('raw_conversion_status') == 'success' or p.get('raw_conversion_status') == 'skipped')
ana_ok = sum(1 for p in photos.values() if p.get('analysis_status') == 'success')
print(f'total={total} raw_ok={raw_ok} ana_ok={ana_ok}')
"
# Expected: total=168 raw_ok=168 ana_ok=168
```

如果这一步崩溃，等于 BUG 文档 §2 表格里"❌ SIGBUS"的两行（10 张和 220 张）都没修好，回到 Task 1。

### ✅ Done when

- 4 个场景全部跑通：`empty` exit=0、`one_jpg` exit=0、`one_raw` exit=0、`mix`（LUMIX_Backup 220 个文件）exit=0。
- **没有任何一个场景的 exit code 是 138**。
- `one_raw` 场景下 `/tmp/rawview_verify/one_raw/.cache/converted/` 里有 `P1000250.JPG`，JSON 中 `raw_conversion_status=success`。
- `mix` 场景下 `/Users/wilbur/Downloads/LUMIX_Backup/.cache/converted/` 里有 106 个 JPG；JSON 中 `raw_ok=168 ana_ok=168`。
- 整个验证过程没写过任何新的测试代码，只跑了 `./build/rawViewer <真实数据目录>` 这一种命令。

---

## Task 3: 更新设计文档

**Goal:** 把"worker 线程栈必须 ≥ 8 MB"这条约束写进 `docs/recipe/photo-analyzer-design.md`，让未来维护者不会把 `kWorkerStackSize` 改回去或退回到 `std::thread` 默认栈。

**Files touched:**
- `docs/recipe/photo-analyzer-design.md` — 在"线程池"小节或"技术约束"小节追加

### Step 1 — 定位插入点

```bash
$ grep -n "线程池\|worker\|stack\|栈" /Users/wilbur/project/rawViewer/docs/recipe/photo-analyzer-design.md | head -20
```

找一个合适的章节标题（建议在"线程池"小节或"技术约束"小节）。如果没有"技术约束"小节，就在文末"附录"前加一节。

### Step 2 — 追加内容

在该小节下加一段：

```markdown
> **技术约束：worker 线程栈必须 ≥ 8 MB**
>
> macOS 给非主线程默认栈只有 512 KB。LibRaw 解码 + OpenCV JPEG encoder + `std::function`
> 调用链实测栈峰值约 500 KB ~ 1 MB，512 KB 必爆。`ThreadPool` 必须用 `pthread` API 显式
> `pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)` 创建 worker。
>
> 相关代码：
> - `cpp/include/threadPool.h` 中 `static constexpr size_t kWorkerStackSize = 8 * 1024 * 1024;`
>
> 详细 BUG 定位：`docs/20260601_worker_thread_stack_overflow.md`。
```

### Step 3 — 检查无格式错

```bash
$ grep -n "8 \* 1024 \* 1024\|kWorkerStackSize\|worker 线程栈" \
    /Users/wilbur/project/rawViewer/docs/recipe/photo-analyzer-design.md
# Expected: 至少 1 行命中
```

### ✅ Done when

- 文档里有明确"worker 线程栈必须 ≥ 8 MB"约束。
- 指向 BUG 定位文档。
- 指向 `kWorkerStackSize` 常量，未来如果有人改小，review 时能直接发现。

---

## 3. 自检清单（执行前最后过一遍）

- [x] **Spec 覆盖**：BUG 文档 §5 提到的三个实现要点（pthread 头、workerIds 改 pthread_t、trampoline 模式）都在 Task 1 落地；§6 验证方法被 Task 2 用真实数据回归覆盖（4 个场景：空、1 JPG、1 RAW、混合真实文件夹）。
- [x] **占位符扫描**：无 TODO / TBD / "类似 Task N" / "添加适当错误处理"。
- [x] **类型一致**：`TaskHandler` / `Result` / `kWorkerStackSize` / `kWorkerCount` / `WorkerContext` / `workerEntry` / `workerLoop` 全文命名一致。
- [x] **无新测试代码**：本计划不写 `testMain.cpp` / `testAssert.h` / `threadPoolTests.cpp` / `integration_test.sh` / mock / fixture / test data 构造工具。所有验证靠直接跑 `rawViewer` 真实数据看退出码、产物 JSON。
- [x] **每个 Task 都有 ✅ Done 条件**，且都是可观察的（编译过、空目录跑通、真实 RAW 跑通 exit=0、JSON 状态对、文档约束写明）。
- [x] **无 git 相关步骤**。

---

## 4. 执行 Handoff

计划已保存到 `docs/flare/20260601_fix_worker_stack_overflow.md`。

**两种执行方式：**

1. **Subagent-Driven（推荐）** — 每个 Task 派一个新 subagent 去做，主 session 在 Task 之间做 review。适合这个修复：每步粒度清晰、Task 1 是核心改动、Task 2 是真实数据回归、Task 3 是文档。

2. **Inline Execution** — 在当前 session 用 executing-plans 一次性批量执行，遇到检查点停下 review。

**选哪种？**
