/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 验证 Objective-C++ 测试目标启用 ARC，并确认 autoreleasepool 可正常执行
 */

#include "testAssert.h"
#include <Foundation/Foundation.h>
#include <vector>

#if !__has_feature(objc_arc)
#error "Objective-C ARC must be enabled for rawViewer Objective-C++ sources"
#endif

static bool objcRuntimeArcIsEnabled() {
    @autoreleasepool {
        NSString* value = [NSString stringWithFormat:@"%@", @"arc-enabled"];
        TEST_REQUIRE(value != nil);
        TEST_REQUIRE([[value description] isEqualToString:@"arc-enabled"]);
    }
    return true;
}

std::vector<TestCase> makeObjcRuntimeTests() {
    return {
        {"objcRuntime.arcIsEnabled", objcRuntimeArcIsEnabled},
    };
}
