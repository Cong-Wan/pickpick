/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 验证 Metal 能力检测接口返回可用于 backend fallback 的明确结果
 */

#include "testAssert.h"
#include "gpuSupport.h"
#include "taskState.h"
#include <vector>

static bool gpuSupportReturnsUsableResult() {
    GpuSupport support = getGpuSupport();
    if (support.hasMetal) {
        TEST_REQUIRE(!support.deviceName.empty());
    } else {
        TEST_REQUIRE(!support.reason.empty());
    }
    return true;
}

static bool cpuBackendIsAlwaysValidFallback() {
    TEST_REQUIRE(imageBackendFromString("cpu") == ImageBackend::Cpu);
    TEST_REQUIRE(toString(ImageBackend::Cpu) == "cpu");
    return true;
}

std::vector<TestCase> makeGpuSupportTests() {
    return {
        {"gpuSupport.returnsUsableResult", gpuSupportReturnsUsableResult},
        {"gpuSupport.cpuBackendIsAlwaysValidFallback", cpuBackendIsAlwaysValidFallback},
    };
}
