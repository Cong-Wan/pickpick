/*
 * Author: wilbur
 * Version: 2.1
 * Date: 2026-06-01
 * Description: 实现模板化固定 4 worker 共享队列线程池；改用 pthread 创建 worker 并显式设置 8 MB 栈，
 *              修复 macOS 上默认 512 KB 栈被 RAW 转换调用链打爆导致的 SIGBUS（详见
 *              docs/20260601_worker_thread_stack_overflow.md）。2.1：清理死代码，移除未使用的
 *              `<atomic>` 头与 `WorkerContext::workerIndex` 字段及其在 trampoline / workerLoop 中的传递。
 *              模板逻辑全部在头文件。
 */

#pragma once

#include <functional>
#include <queue>
#include <vector>
#include <mutex>
#include <condition_variable>
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

            WorkerContext* ctx = new WorkerContext{this};

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
    };

    // pthread 入口必须是 `void*(void*)` 签名的静态/自由函数
    static void* workerEntry(void* arg) {
        WorkerContext* ctx = static_cast<WorkerContext*>(arg);
        ThreadPool* pool = ctx->self;
        delete ctx;
        pool->workerLoop();
        return nullptr;
    }

    void workerLoop() {
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
