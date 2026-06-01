/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 提供基于 steady_clock 的轻量阶段耗时计时器，用于记录图片处理性能瓶颈
 */

#pragma once

#include <chrono>
#include <cstdint>

class PerfTimer {
public:
    PerfTimer() : start_(std::chrono::steady_clock::now()) {
    }

    int64_t elapsedMs() const {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start_).count();
    }

    void reset() {
        start_ = std::chrono::steady_clock::now();
    }

private:
    std::chrono::steady_clock::time_point start_;
};
