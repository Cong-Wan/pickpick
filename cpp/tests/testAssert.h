/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 提供轻量测试断言宏，避免为当前 C++ 项目引入额外测试框架
 */

#pragma once

#include <iostream>
#include <string>

#define TEST_REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "Assertion failed: " << #condition << " at " << __FILE__ << ":" << __LINE__ << std::endl; \
            return false; \
        } \
    } while (0)

using TestFn = bool (*)();

struct TestCase {
    std::string name;
    TestFn fn;
};
