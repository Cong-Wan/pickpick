/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 实现 Objective-C++ 照片分析桥，直接调用 AppRunner 和 JsonManager 并转换为 App 模型
*/

#import "photoAnalyzerBridge.h"

#include "appRunner.h"
#include "jsonManager.h"

#include <filesystem>

#import <dispatch/dispatch.h>

static NSString * const rwPhotoAnalyzerErrorDomain = @"rawViewer.photoAnalyzer";

@implementation rwAnalysisProgress
- (instancetype)initWithPhase:(NSInteger)phase
               completedCount:(NSInteger)completedCount
                    totalCount:(NSInteger)totalCount
               overallProgress:(double)overallProgress {
    self = [super init];
    if (self) {
        _phase = phase;
        _completedCount = completedCount;
        _totalCount = totalCount;
        _overallProgress = overallProgress;
    }
    return self;
}
@end

@implementation rwAnalysisResult
- (instancetype)initWithTotalPhotos:(NSInteger)totalPhotos
                         blurryCount:(NSInteger)blurryCount
                     overexposedCount:(NSInteger)overexposedCount
                    underexposedCount:(NSInteger)underexposedCount
                          normalCount:(NSInteger)normalCount {
    self = [super init];
    if (self) {
        _totalPhotos = totalPhotos;
        _blurryCount = blurryCount;
        _overexposedCount = overexposedCount;
        _underexposedCount = underexposedCount;
        _normalCount = normalCount;
    }
    return self;
}
@end

@implementation rwPhotoRecord
- (instancetype)initWithPhotoId:(NSString *)photoId
                         jpgPath:(NSString *)jpgPath
                         rawPath:(NSString *)rawPath
                       isBlurry:(BOOL)isBlurry
                  exposureStatus:(NSString *)exposureStatus
                    reviewStatus:(NSString *)reviewStatus
                   reviewGroupId:(NSString *)reviewGroupId
                 templatePhotoId:(NSString *)templatePhotoId {
    self = [super init];
    if (self) {
        _photoId = [photoId copy];
        _jpgPath = [jpgPath copy];
        _rawPath = [rawPath copy];
        _isBlurry = isBlurry;
        _exposureStatus = [exposureStatus copy];
        _reviewStatus = [reviewStatus copy];
        _reviewGroupId = [reviewGroupId copy];
        _templatePhotoId = [templatePhotoId copy];
    }
    return self;
}
@end

static NSError *rwMakeError(NSString *message) {
    return [NSError errorWithDomain:rwPhotoAnalyzerErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static rwAnalysisProgress *rwProgressFromRunProgress(const RunProgress& progress) {
    return [[rwAnalysisProgress alloc] initWithPhase:static_cast<NSInteger>(progress.phase)
                                     completedCount:progress.completedCount
                                          totalCount:progress.totalCount
                                     overallProgress:progress.overallProgress];
}

static rwAnalysisResult *rwResultFromSummary(const RunSummary& summary) {
    return [[rwAnalysisResult alloc] initWithTotalPhotos:summary.totalPhotos
                                            blurryCount:summary.blurry
                                        overexposedCount:summary.overexposed
                                       underexposedCount:summary.underexposed
                                             normalCount:summary.normal];
}

static rwPhotoRecord *rwRecordFromState(const PhotoTaskState& state) {
    return [[rwPhotoRecord alloc] initWithPhotoId:@(state.photoId.c_str())
                                          jpgPath:@(state.jpgPath.c_str())
                                          rawPath:@(state.rawPath.c_str())
                                         isBlurry:state.isBlurry
                                   exposureStatus:@(state.exposureStatus.c_str())
                                     reviewStatus:@(toString(state.reviewStatus).c_str())
                                    reviewGroupId:@(state.reviewGroupId.c_str())
                                  templatePhotoId:@(state.templatePhotoId.c_str())];
}

@implementation rwPhotoAnalyzerBridge
- (void)startAnalysisAtFolderPath:(NSString *)folderPath
                       configPath:(NSString *)configPath
                         progress:(void (^)(rwAnalysisProgress *progress))progress
                       completion:(void (^)(rwAnalysisResult * _Nullable result, NSError * _Nullable error))completion {
    NSString *folderCopy = [folderPath copy];
    NSString *configCopy = [configPath copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        try {
            RunOptions options;
            options.folderPath = std::string(folderCopy.UTF8String ?: "");
            options.configPath = std::string(configCopy.UTF8String ?: "");
            options.progressCallback = [progress](const RunProgress& runProgress) {
                rwAnalysisProgress *bridgeProgress = rwProgressFromRunProgress(runProgress);
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(bridgeProgress);
                });
            };

            AppRunner runner;
            RunSummary summary = runner.run(options);
            rwAnalysisResult *result = rwResultFromSummary(summary);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result, nil);
            });
        } catch (const std::exception& exception) {
            NSString *message = @(exception.what());
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, rwMakeError(message));
            });
        } catch (...) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, rwMakeError(@"Unknown analyzer error"));
            });
        }
    });
}

- (NSArray<rwPhotoRecord *> * _Nullable)loadAnalysisResultAtFolderPath:(NSString *)folderPath
                                                                 error:(NSError **)error {
    try {
        std::string folder = std::string(folderPath.UTF8String ?: "");
        std::filesystem::path jsonPath = std::filesystem::path(folder) / ".cache" / "analysis.json";
        if (!std::filesystem::exists(jsonPath)) {
            if (error) {
                *error = rwMakeError(@"analysis.json not found");
            }
            return nil;
        }

        JsonManager manager;
        manager.init(folder, "");
        std::vector<PhotoTaskState> states = manager.getAllPhotoStates();
        NSMutableArray<rwPhotoRecord *> *records = [NSMutableArray arrayWithCapacity:states.size()];
        for (const auto& state : states) {
            [records addObject:rwRecordFromState(state)];
        }
        return records;
    } catch (const std::exception& exception) {
        if (error) {
            *error = rwMakeError(@(exception.what()));
        }
        return nil;
    } catch (...) {
        if (error) {
            *error = rwMakeError(@"Unknown analyzer error");
        }
        return nil;
    }
}
@end
