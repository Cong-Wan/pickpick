# BUG Report — Worker 线程栈溢出导致 SIGBUS

**Author:** wilbur
**Version:** 1.0
**Date:** 2026-06-01
**Status:** 已定位，未修复
**Severity:** High（程序直接崩溃，无法使用）
**Affected:** `cpp/include/threadPool.h`、`cpp/src/appRunner.cpp` 间接相关

---

## 1. 现象

执行如下命令时，进程在 0.01~0.02 秒内崩溃：

```bash
$ ./build/rawViewer ~/Downloads/LUMIX_Backup
[trace] ...
/bin/bash: line 1: 20928 Bus error: 10           ./build/rawViewer ~/Downloads/LUMIX_Backup
exit=138
```

- 退出码 138 = 128 + 10（`SIGBUS`）
- 崩溃发生极早，远在任何 RAW 解码或图像分析完成之前
- 0 张、1 张照片时**不**崩；含真实 RAW 文件时**必**崩

---

## 2. 复现条件

| 条件 | 是否必需 | 说明 |
| --- | --- | --- |
| 至少 1 张真实 `.RW2` / `.CR2` 文件 | 必需 | 触发 RAW 转 JPG 阶段 |
| 线程池 4 worker | 必需 | 增大 worker 线程爆栈概率 |
| macOS Apple Silicon | 当前已知 | 其它平台未验证 |

**对照实验：**

| 测试 | 文件数 | 内容 | 耗时 | 结果 |
| --- | --- | --- | --- | --- |
| `/tmp/empty_test` | 0 | 空目录 | 0.018s | ✅ 正常 |
| `/tmp/one_test` | 1 | 1 张真 JPG | 0.537s | ✅ 正常 |
| `/tmp/ten_test` | 10 | 8 JPG + 1 RW2 + 1 JPG | 0.011s | ❌ SIGBUS |
| `/tmp/clean_test` | 220 | 62 JPG + 158 RW2 | 0.020s | ❌ SIGBUS |
| `/tmp/big` (200 fake JPG) | 200 | 文本假文件 | 0.601s | ✅ 正常 |

> **关键对比**：200 个假文件没事，含 1 张真 RW2 就崩。问题不在文件数量，在 RAW 处理调用链。

---

## 3. 调查过程

### 3.1 粗粒度定位：在哪一步崩

在 `appRunner.cpp::RunSummary AppRunner::run()` 各阶段前后插入 `std::cerr` 标记：

```text
[trace] enter run()
[trace] config loaded
[trace] scanned pairs=168
[trace] jsonManager inited
[trace] mergeScannedPairs done
[trace] markRunningAsPending done
[trace] atomicSave done
[trace] getAllPhotoStates=168
[trace] planner done raw=106 ana=62
[trace] enter RAW phase, tasks=106
[trace] RAW pool constructed
/bin/bash: line 1: 20624 Bus error: 10
```

→ 崩溃发生在 `ThreadPool` 构造完成后、推进 RAW 任务期间。

### 3.2 细粒度定位：循环内哪一行

把 RAW 阶段 for 循环每条语句都包了 trace：

```text
[trace] RAW loop i=0 id=P1000250 pre-getState
[trace] RAW loop i=0 post-getState
[trace] RAW loop i=0 pre-pushTask
[trace] RAW loop i=0 post-pushTask
[trace] RAW loop i=1 id=P1000265 pre-getState
[trace] RAW loop i=1 post-getState
[trace] RAW loop i=1 pre-pushTask
[trace] RAW loop i=1 post-pushTask
[trace] RAW loop i=2 id=P1000268 pre-getState
Process 21007 launched: '.../rawViewer' (arm64)
Process 21007 stopped
* thread #2, stop reason = EXC_BAD_ACCESS ...
```

→ i=0 和 i=1 的 `pre/post-getState` 与 `pre/post-pushTask` 都打出来了。崩溃发生在 i=2 进入循环体的瞬间，并且**打印 `task.photoId` 那一行**的 `<<` 流式写入被截断（log 末尾残留 `[trace] RAW loop i=2 id=` 无后文）。

→ 任务向量 `planned.rawConvertTasks` 的内容已经被破坏。

### 3.3 用 lldb 抓现场

```bash
lldb -o "process handle SIGBUS -s true -p true -n true" \
     -o "run" -o "thread backtrace all" -o "quit" \
     --batch -- ./build/rawViewer ~/Downloads/LUMIX_Backup
```

回溯：

```text
* thread #2, stop reason = EXC_BAD_ACCESS (code=2, address=0x16fe03ff8)
    frame #0: 0x00000001868e0c5c libsystem_pthread.dylib`___chkstk_darwin + 60
```

- `thread #2` 是 worker 线程，**不是主线程**
- `address=0x16fe03ff8` 落在该 worker 线程的 stack guard page
- `___chkstk_darwin` 是函数探测栈空间时的入口
- 一旦函数需要的栈帧 > 当前栈剩余空间，OS 会用这个入口去 probe 下方页面，命中 guard page 立刻 `SIGBUS`

→ **worker 线程栈溢出**。

---

## 4. 根因

### 4.1 直接原因

macOS 给非主线程的默认栈只有 **512 KB**。worker 跑下面这条调用链时，单帧栈需求超过 512 KB：

```text
ThreadPool::workerLoop
  └─ handler_ (lambda, 捕获 this + &config)
       └─ AppRunner::convertWithRetry
            └─ RawConverter::convert
                 ├─ LibRaw::open_file          // ~几十 KB
                 ├─ LibRaw::unpack             // ~几十 KB
                 ├─ LibRaw::dcraw_process      // 内部有较深调用 + 局部 buffer
                 ├─ LibRaw::dcraw_make_mem_image
                 └─ cv::imwrite (JPEG encoder) // 内部 Huffman 表等栈消耗大
```

LibRaw 内部有较深的调用层次，加上 OpenCV JPEG encoder 在编码时需要栈上缓冲，叠加 `std::function`、捕获了引用的 lambda 等 C++ 模板膨胀开销，**实际栈峰值约 500 KB~1 MB**，瞬间打爆 512 KB 限制。

### 4.2 为什么主线程没事

主线程默认栈 8 MB，同一段代码在主线程跑完全正常。这是 macOS 线程模型的差异，不是代码 bug——但写代码时极易忽略。

### 4.3 为什么 0/1 张照片不崩

- 0 张：RAW 队列为空，根本不会进入 `pool.pushTask`
- 1 张：扫描结果只有 1 个 pair，RAW 队列里只有 1 个任务。**关键是**只有 1 个 worker 被唤醒去处理，3 个 worker 还在 `taskCv_.wait()`。处理完一个任务后 worker 回到 wait 状态。但本测试中 1 张是 JPG，所以走的不是 RAW 转换，是 `imageAnalyzer.analyze`。`imread` 栈需求小，不爆。

→ 至少需要 1 张真实 RAW 才会进入爆栈的代码路径。

### 4.4 关键概念澄清（避免后续误解）

| 概念 | 是什么 | 受这次 bug 影响吗 |
| --- | --- | --- |
| **栈（stack）** | 函数局部变量、参数、返回地址；线程创建时固定分配 | ✅ 是的，512KB 不够 |
| **堆（heap）** | 动态数据（`cv::Mat` 数据、30 MB RAW buffer） | ❌ 无关 |
| **文件大小** | 30 MB RAW 文件解出来 36 MB RGB buffer，全在堆上 | ❌ 跟栈没关系 |

栈上 8MB 跟 RAW 30MB 是两件互不相关的事。8MB 指的是函数调用链能用的栈空间，30MB 是 RAW 解码后图像数据占的堆空间。

---

## 5. 修复方向

> 本节只给方向，不动代码。

**思路**：把 worker 线程的栈从 512 KB 提到 8 MB（与主线程对齐）。

**实现要点**：

1. `std::thread` 不直接支持设置 stack size，需绕过：
   - `include/threadPool.h` 引入 `<pthread.h>`
   - 用 `pthread_attr_t` + `pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)` 创建线程
2. `workers_` 不能再用 `std::vector<std::thread>`，因为不能从已有 `pthread_t` 构造 `std::thread`：
   - 改为 `std::vector<pthread_t> workerIds_`
   - `stop()` 中用 `pthread_join` 替代 `worker.join()`
3. worker 入口需要从 lambda 改成 `static void* workerEntry(void*)` + `self->workerLoop()` 的 trampoline 模式

**为什么是 8 MB**：
- 跟主线程一致，最简单
- 实测栈峰值约 1 MB，8 MB 给 8 倍余量
- 单 worker 一次只处理 1 张 RAW（堆上 36 MB RGB buffer 跟栈无关），不会因为换更大 RAW 栈就吃更多

**替代方案**（不推荐）：
- 改用进程池：复杂度高，收益小
- 改用 `std::async` / GCD：跨平台差
- 降低 LibRaw 内部栈使用：改第三方库源码，代价大

---

## 6. 验证方法

修复后用以下命令验证不再崩溃：

```bash
# 回归测试：原崩溃命令
./build/rawViewer ~/Downloads/LUMIX_Backup

# 跑完后检查产物
cat ~/Downloads/LUMIX_Backup/.cache/analysis.json | python3 -m json.tool | head -50
ls ~/Downloads/LUMIX_Backup/.cache/converted/ | head
```

期望：
- 进程不再 SIGBUS
- 30+ MB 的 RW2 在 `LibRaw + imwrite` 流程中正常出 JPG
- `.cache/analysis.json` 中 106 个 RAW 项的 `raw_conversion_status` 从 `pending` 变为 `success`

**回归测试场景**（务必覆盖）：
- 0 张照片：仍能正常退出
- 1 张 JPG：不崩
- 1 张 RW2：能转出 JPG
- 真实混合文件夹（106 RAW + 62 JPG）：不崩且全部完成

---

## 7. 教训

1. **写多线程代码前要意识到默认线程栈只有几百 KB**。涉及第三方库（特别是图像处理、编解码）时，几乎一定要显式调大栈。
2. **SIGBUS 不一定是内存对齐**，在 macOS 上多线程栈溢出也是常见诱因。看到 `___chkstk_darwin` 基本可以直接判定。
3. **崩溃栈回溯一定要看是哪个线程出的错**。这次主线程 i=2 的 trace 看起来像主线程在崩，但 lldb 显示是 thread #2 挂的，是 worker 提前踩了共享堆/共享数据。
4. **用 trace 定位 + lldb 抓现场** 是这种"主线程 trace 看起来正常，但 worker 早挂了"问题的高效组合。

---

## 8. 相关文件

| 文件 | 角色 | 状态 |
| --- | --- | --- |
| `cpp/include/threadPool.h` | 需要改：worker 改 pthread + 8MB 栈 | 未改 |
| `cpp/src/appRunner.cpp` | 不用改 | 未改 |
| `cpp/src/rawConverter.cpp` | 不用改，只是爆栈的源头之一 | 未改 |
| `cpp/src/imageAnalyzer.cpp` | 不用改（当前测试未触发，但分析阶段也存在类似风险） | 未改 |
| `docs/recipe/photo-analyzer-design.md` | 可在"技术约束"章节补充 worker 栈要求 | 未改 |

---

## 9. 时间线

| 时间 | 事件 |
| --- | --- |
| 2026-05-29 | 项目初版提交，引入 `ThreadPool` 用 `std::thread` 启动 4 worker，未设置栈大小 |
| 2026-06-01 10:27 | 用户首次跑 `~/Downloads/LUMIX_Backup`，遗留半成品 `analysis.json` |
| 2026-06-01 11:00+ | 用户报告 bus error；开始排查 |
| 2026-06-01 | 定位为 worker 线程栈溢出，落档本 BUG 文档 |
