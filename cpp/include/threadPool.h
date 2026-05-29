/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 实现模板化固定 4 worker 共享队列线程池；模板逻辑全部在头文件
 */

#pragma once

#include <functional>
#include <queue>
#include <thread>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <atomic>

template <typename Task, typename Result>
class ThreadPool {
public:
    using TaskHandler = std::function<Result(const Task&)>;

    explicit ThreadPool(TaskHandler handler)
        : handler_(handler), stopped_(false), activeTasks_(0) {
        for (int i = 0; i < 4; ++i) {
            workers_.emplace_back([this]() {
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
            });
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
        for (auto& worker : workers_) {
            if (worker.joinable()) {
                worker.join();
            }
        }
    }

private:
    TaskHandler handler_;
    std::vector<std::thread> workers_;
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
