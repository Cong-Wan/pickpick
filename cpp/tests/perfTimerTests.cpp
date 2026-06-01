/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-01
 * Description: 验证性能计时器和图片处理结果结构的阶段耗时默认值
 */

#include "testAssert.h"
#include "perfTimer.h"
#include "taskState.h"
#include <thread>
#include <vector>

static bool perfTimerElapsedIsNonNegative() {
    PerfTimer timer;
    TEST_REQUIRE(timer.elapsedMs() >= 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    TEST_REQUIRE(timer.elapsedMs() >= 0);
    return true;
}

static bool rawConvertTimingDefaultsAreZero() {
    RawConvertResult result;
    TEST_REQUIRE(result.elapsedMs == 0);
    TEST_REQUIRE(result.openFileMs == 0);
    TEST_REQUIRE(result.unpackMs == 0);
    TEST_REQUIRE(result.processMs == 0);
    TEST_REQUIRE(result.makeImageMs == 0);
    TEST_REQUIRE(result.writeJpgMs == 0);
    return true;
}

static bool analyzeTimingDefaultsAreZero() {
    AnalyzeResult result;
    TEST_REQUIRE(result.readImageMs == 0);
    TEST_REQUIRE(result.grayMs == 0);
    TEST_REQUIRE(result.laplacianMs == 0);
    TEST_REQUIRE(result.statsMs == 0);
    TEST_REQUIRE(result.histogramMs == 0);
    return true;
}

std::vector<TestCase> makePerfTimerTests() {
    return {
        {"perfTimer.elapsedIsNonNegative", perfTimerElapsedIsNonNegative},
        {"perfTimer.rawConvertTimingDefaultsAreZero", rawConvertTimingDefaultsAreZero},
        {"perfTimer.analyzeTimingDefaultsAreZero", analyzeTimingDefaultsAreZero},
    };
}
