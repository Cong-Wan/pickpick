/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明 RAW 转 JPG 转换接口、转换任务和转换结果
 */

#pragma once

#include "taskState.h"

class RawConverter {
public:
    RawConvertResult convert(const RawConvertTask& task, const AppConfig& config) const;
};
