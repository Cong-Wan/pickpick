/*
 * Author: wilbur
 * Version: 1.0
 * Date: 2026-05-29
 * Description: 程序入口；解析命令行；调用 AppRunner；输出摘要
 */

#include "appRunner.h"
#include <iostream>
#include <cstring>
#include <stdexcept>

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << (argc > 0 ? argv[0] : "rawViewer") << " <folder_path> [--config <config_path>] [--resume]" << std::endl;
        return 1;
    }

    RunOptions options;
    options.folderPath = argv[1];
    options.configPath = "config.yaml";
    options.resume = false;

    for (int i = 2; i < argc; ++i) {
        if (std::strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            options.configPath = argv[++i];
        } else if (std::strcmp(argv[i], "--resume") == 0) {
            options.resume = true;
        }
    }

    try {
        AppRunner runner;
        RunSummary summary = runner.run(options);

        std::cout << "\nSummary:" << std::endl;
        std::cout << "  Total photos            : " << summary.totalPhotos << std::endl;
        std::cout << "  RAW conversion success  : " << summary.rawConversionSuccess << std::endl;
        std::cout << "  RAW conversion failed   : " << summary.rawConversionFailed << std::endl;
        std::cout << "  Analysis success        : " << summary.analysisSuccess << std::endl;
        std::cout << "  Analysis failed         : " << summary.analysisFailed << std::endl;
        std::cout << "  Pending                 : " << summary.pending << std::endl;
        std::cout << "  Blurry                  : " << summary.blurry << std::endl;
        std::cout << "  Overexposed             : " << summary.overexposed << std::endl;
        std::cout << "  Underexposed            : " << summary.underexposed << std::endl;
        std::cout << "  Normal                  : " << summary.normal << std::endl;

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
}
