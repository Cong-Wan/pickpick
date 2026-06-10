/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 声明 Objective-C++ 照片分析桥，向 Swift 暴露进度、结果和照片记录
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface rwAnalysisProgress : NSObject
@property (nonatomic, assign) NSInteger phase;
@property (nonatomic, assign) NSInteger completedCount;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) double overallProgress;
- (instancetype)initWithPhase:(NSInteger)phase
               completedCount:(NSInteger)completedCount
                    totalCount:(NSInteger)totalCount
               overallProgress:(double)overallProgress;
@end

@interface rwAnalysisResult : NSObject
@property (nonatomic, assign) NSInteger totalPhotos;
@property (nonatomic, assign) NSInteger blurryCount;
@property (nonatomic, assign) NSInteger overexposedCount;
@property (nonatomic, assign) NSInteger underexposedCount;
@property (nonatomic, assign) NSInteger normalCount;
- (instancetype)initWithTotalPhotos:(NSInteger)totalPhotos
                         blurryCount:(NSInteger)blurryCount
                     overexposedCount:(NSInteger)overexposedCount
                    underexposedCount:(NSInteger)underexposedCount
                          normalCount:(NSInteger)normalCount;
@end

@interface rwPhotoRecord : NSObject
@property (nonatomic, copy) NSString *photoId;
@property (nonatomic, copy) NSString *jpgPath;
@property (nonatomic, copy) NSString *rawPath;
@property (nonatomic, assign) BOOL isBlurry;
@property (nonatomic, copy) NSString *exposureStatus;
@property (nonatomic, copy) NSString *reviewStatus;
@property (nonatomic, copy) NSString *reviewGroupId;
@property (nonatomic, copy) NSString *templatePhotoId;
- (instancetype)initWithPhotoId:(NSString *)photoId
                         jpgPath:(NSString *)jpgPath
                         rawPath:(NSString *)rawPath
                       isBlurry:(BOOL)isBlurry
                  exposureStatus:(NSString *)exposureStatus
                    reviewStatus:(NSString *)reviewStatus
                   reviewGroupId:(NSString *)reviewGroupId
                 templatePhotoId:(NSString *)templatePhotoId;
@end

@interface rwPhotoAnalyzerBridge : NSObject
- (void)startAnalysisAtFolderPath:(NSString *)folderPath
                       configPath:(NSString *)configPath
                         progress:(void (^)(rwAnalysisProgress *progress))progress
                       completion:(void (^)(rwAnalysisResult * _Nullable result, NSError * _Nullable error))completion;

- (NSArray<rwPhotoRecord *> * _Nullable)loadAnalysisResultAtFolderPath:(NSString *)folderPath
                                                                 error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
