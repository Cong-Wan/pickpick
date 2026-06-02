/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 声明解码图片内存转 OpenCV JPG 写入矩阵的辅助函数，确保 RGB 数据按 BGR 写出
 */

#pragma once

#include <opencv2/core.hpp>

cv::Mat makeJpgWriteMatFromDecodedImage(int height, int width, int colors, const void* data);
