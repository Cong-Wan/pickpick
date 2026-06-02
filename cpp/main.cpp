/*
 * Author: wilbur
 * Version: 1.1
 * Date: 2026-06-02
 * Description: 程序入口；解析命令行；调用 AppRunner；输出阶段进度和最终摘要
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

    options.progressCallback = [](const RunProgress& progress) {
        const char* phaseName = "unknown";
        switch (progress.phase) {
            case RunPhase::Scanning: phaseName = "scanning"; break;
            case RunPhase::RawConversion: phaseName = "raw_conversion"; break;
            case RunPhase::Analysis: phaseName = "analysis"; break;
            case RunPhase::Organizing: phaseName = "organizing"; break;
            case RunPhase::Completed: phaseName = "completed"; break;
        }

        int percent = static_cast<int>(progress.overallProgress * 100.0 + 0.5);
        if (progress.totalCount > 0) {
            std::cout << "[" << phaseName << "] "
                      << progress.completedCount << "/" << progress.totalCount
                      << " overall=" << percent << "%" << std::endl;
        } else {
            std::cout << "[" << phaseName << "] overall=" << percent << "%" << std::endl;
        }
    };

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
