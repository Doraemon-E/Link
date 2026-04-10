#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const AULlamaRuntimeErrorDomain;

typedef NS_ERROR_ENUM(AULlamaRuntimeErrorDomain, AULlamaRuntimeErrorCode) {
    AULlamaRuntimeErrorCodeInitialization = 1,
    AULlamaRuntimeErrorCodeInference = 2,
};

@interface AULlamaRuntime : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                             contextLength:(NSInteger)contextLength
                                     error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (nullable NSString *)translatePrompt:(NSString *)prompt
                             maxTokens:(NSInteger)maxTokens
                           temperature:(double)temperature
                                  topK:(NSInteger)topK
                                  topP:(double)topP
                     repetitionPenalty:(double)repetitionPenalty
                                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
