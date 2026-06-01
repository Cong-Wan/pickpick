/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 实现轻量测试入口，支持通过 --filter 运行指定测试分组
 */

#include "testAssert.h"
#include <iostream>
#include <string>
#include <vector>

std::vector<TestCase> makePerfTimerTests();

static bool matchesFilter(const std::string& name, const std::string& filter) {
    return filter.empty() || name.find(filter) != std::string::npos;
}

int main(int argc, char** argv) {
    std::string filter;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--filter" && i + 1 < argc) {
            filter = argv[++i];
        }
    }

    std::vector<TestCase> tests;
    auto perfTimerTests = makePerfTimerTests();
    tests.insert(tests.end(), perfTimerTests.begin(), perfTimerTests.end());

    int selected = 0;
    int failed = 0;
    for (const auto& test : tests) {
        if (!matchesFilter(test.name, filter)) {
            continue;
        }

        selected++;
        bool passed = test.fn();
        std::cout << (passed ? "PASS " : "FAIL ") << test.name << std::endl;
        if (!passed) {
            failed++;
        }
    }

    if (selected == 0) {
        std::cerr << "No tests matched filter: " << filter << std::endl;
        return 1;
    }

    std::cout << "Tests run: " << selected << ", failures: " << failed << std::endl;
    return failed == 0 ? 0 : 1;
}
