/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-06-02
 * Description: 实现解码图片内存到 OpenCV JPG 写入矩阵的转换，RGB 输入转换为 BGR，灰度输入复制保留
 */

#include "rawJpgMat.h"
#include <opencv2/imgproc.hpp>
#include <stdexcept>

cv::Mat makeJpgWriteMatFromDecodedImage(int height, int width, int colors, const void* data) {
    if (height <= 0 || width <= 0) {
        throw std::invalid_argument("Decoded image size must be positive");
    }
    if (data == nullptr) {
        throw std::invalid_argument("Decoded image data must not be null");
    }

    if (colors == 3) {
        cv::Mat rgb(height, width, CV_8UC3, const_cast<void*>(data));
        cv::Mat bgr;
        cv::cvtColor(rgb, bgr, cv::COLOR_RGB2BGR);
        return bgr;
    }

    if (colors == 1) {
        cv::Mat gray(height, width, CV_8UC1, const_cast<void*>(data));
        return gray.clone();
    }

    throw std::invalid_argument("Decoded image must have 1 or 3 channels");
}
