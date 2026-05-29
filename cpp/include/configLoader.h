/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 声明 YAML 配置读取与校验接口
 */

#pragma once

#include "taskState.h"
#include <string>

class ConfigLoader {
public:
    AppConfig loadFromFile(const std::string& configPath) const;
};
