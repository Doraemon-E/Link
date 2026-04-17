#import "LlamaObjectiveCBridge.h"

#import <llama/llama.h>

#include <limits>
#include <vector>

NSErrorDomain const AULlamaRuntimeErrorDomain = @"AULlamaRuntimeErrorDomain";

static NSError *AULlamaMakeError(AULlamaRuntimeErrorCode code, NSString *description) {
    return [NSError errorWithDomain:AULlamaRuntimeErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: description
                           }];
}

static enum llama_flash_attn_type AULlamaFlashAttentionTypeForMode(AULlamaRuntimeFlashAttentionMode mode) {
    switch (mode) {
        case AULlamaRuntimeFlashAttentionModeAuto:
            return LLAMA_FLASH_ATTN_TYPE_AUTO;
        case AULlamaRuntimeFlashAttentionModeDisabled:
            return LLAMA_FLASH_ATTN_TYPE_DISABLED;
    }
    return LLAMA_FLASH_ATTN_TYPE_DISABLED;
}

static enum ggml_type AULlamaGGMLTypeForKVCacheType(AULlamaRuntimeKVCacheType type) {
    switch (type) {
        case AULlamaRuntimeKVCacheTypeF16:
            return GGML_TYPE_F16;
        case AULlamaRuntimeKVCacheTypeQ80:
            return GGML_TYPE_Q8_0;
        case AULlamaRuntimeKVCacheTypeQ4K:
            return GGML_TYPE_Q4_K;
    }
    return GGML_TYPE_F16;
}

static NSString *AULlamaKVCacheTypeName(AULlamaRuntimeKVCacheType type) {
    switch (type) {
        case AULlamaRuntimeKVCacheTypeF16:
            return @"f16";
        case AULlamaRuntimeKVCacheTypeQ80:
            return @"q8_0";
        case AULlamaRuntimeKVCacheTypeQ4K:
            return @"q4_k";
    }
    return @"f16";
}

static BOOL AULlamaKVCacheTypeIsQuantized(AULlamaRuntimeKVCacheType type) {
    return type != AULlamaRuntimeKVCacheTypeF16;
}

static NSInteger AULlamaKVCacheBlockSize(AULlamaRuntimeKVCacheType type) {
    switch (type) {
        case AULlamaRuntimeKVCacheTypeF16:
            return 1;
        case AULlamaRuntimeKVCacheTypeQ80:
            return 32;
        case AULlamaRuntimeKVCacheTypeQ4K:
            return 256;
    }
    return 1;
}

@interface AULlamaRuntime () {
    struct llama_model *_model;
    struct llama_context *_context;
    const struct llama_vocab *_vocab;
}

- (nullable NSString *)metadataValueForKey:(const char *)key;
- (nullable NSNumber *)metadataIntegerForKey:(const char *)key;
- (BOOL)validateKVCacheConfigurationWithFlashAttentionMode:(AULlamaRuntimeFlashAttentionMode)flashAttentionMode
                                                    typeK:(AULlamaRuntimeKVCacheType)typeK
                                                    typeV:(AULlamaRuntimeKVCacheType)typeV
                                                    error:(NSError * _Nullable * _Nullable)error;
- (BOOL)initializeContextWithContextLength:(NSInteger)contextLength
                        flashAttentionMode:(AULlamaRuntimeFlashAttentionMode)flashAttentionMode
                                     typeK:(AULlamaRuntimeKVCacheType)typeK
                                     typeV:(AULlamaRuntimeKVCacheType)typeV
                                     error:(NSError * _Nullable * _Nullable)error;
@end

@implementation AULlamaRuntime

+ (void)initialize {
    if (self == [AULlamaRuntime class]) {
        llama_backend_init();
    }
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                             contextLength:(NSInteger)contextLength
                        flashAttentionMode:(AULlamaRuntimeFlashAttentionMode)flashAttentionMode
                                     typeK:(AULlamaRuntimeKVCacheType)typeK
                                     typeV:(AULlamaRuntimeKVCacheType)typeV
                                     error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    llama_model_params modelParams = llama_model_default_params();
    modelParams.use_mmap = true;
    modelParams.use_mlock = false;
    modelParams.check_tensors = false;
    modelParams.n_gpu_layers = 0;

    _model = llama_model_load_from_file(modelPath.fileSystemRepresentation, modelParams);
    if (_model == nullptr) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInitialization,
                [NSString stringWithFormat:@"Unable to load GGUF model at %@.", modelPath.lastPathComponent]
            );
        }
        return nil;
    }

    if (![self validateKVCacheConfigurationWithFlashAttentionMode:flashAttentionMode
                                                            typeK:typeK
                                                            typeV:typeV
                                                            error:error]) {
        llama_model_free(_model);
        _model = nullptr;
        return nil;
    }

    NSError *requestedConfigurationError = nil;
    if (![self initializeContextWithContextLength:contextLength
                               flashAttentionMode:flashAttentionMode
                                            typeK:typeK
                                            typeV:typeV
                                            error:&requestedConfigurationError]) {
        const BOOL requestedNonBaseline =
            flashAttentionMode != AULlamaRuntimeFlashAttentionModeDisabled ||
            typeK != AULlamaRuntimeKVCacheTypeF16 ||
            typeV != AULlamaRuntimeKVCacheTypeF16;

        if (!requestedNonBaseline) {
            llama_model_free(_model);
            _model = nullptr;

            if (error != nil) {
                *error = requestedConfigurationError;
            }
            return nil;
        }

        NSLog(
            @"AULlamaRuntime: falling back to baseline KV cache for %@ after %@",
            modelPath.lastPathComponent,
            requestedConfigurationError.localizedDescription
        );

        NSError *fallbackError = nil;
        if (![self initializeContextWithContextLength:contextLength
                                   flashAttentionMode:AULlamaRuntimeFlashAttentionModeDisabled
                                                typeK:AULlamaRuntimeKVCacheTypeF16
                                                typeV:AULlamaRuntimeKVCacheTypeF16
                                                error:&fallbackError]) {
            llama_model_free(_model);
            _model = nullptr;

            if (error != nil) {
                *error = fallbackError ?: requestedConfigurationError;
            }
            return nil;
        }
    }

    _vocab = llama_model_get_vocab(_model);
    if (_vocab == nullptr) {
        llama_free(_context);
        llama_model_free(_model);
        _context = nullptr;
        _model = nullptr;

        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInitialization,
                [NSString stringWithFormat:@"Unable to load llama vocabulary for %@.", modelPath.lastPathComponent]
            );
        }
        return nil;
    }

    return self;
}

- (nullable NSString *)metadataValueForKey:(const char *)key {
    char buffer[256] = {0};
    const int32_t length = llama_model_meta_val_str(_model, key, buffer, sizeof(buffer));
    if (length < 0 || buffer[0] == '\0') {
        return nil;
    }

    return [[NSString alloc] initWithUTF8String:buffer];
}

- (nullable NSNumber *)metadataIntegerForKey:(const char *)key {
    NSString *value = [self metadataValueForKey:key];
    if (value == nil) {
        return nil;
    }

    return @([value integerValue]);
}

- (BOOL)validateKVCacheConfigurationWithFlashAttentionMode:(AULlamaRuntimeFlashAttentionMode)flashAttentionMode
                                                    typeK:(AULlamaRuntimeKVCacheType)typeK
                                                    typeV:(AULlamaRuntimeKVCacheType)typeV
                                                    error:(NSError * _Nullable * _Nullable)error {
    if (AULlamaKVCacheTypeIsQuantized(typeV) &&
        flashAttentionMode == AULlamaRuntimeFlashAttentionModeDisabled) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInitialization,
                [NSString stringWithFormat:@"Requested V cache type %@ requires flash attention to be auto.",
                                           AULlamaKVCacheTypeName(typeV)]
            );
        }
        return NO;
    }

    NSString *architecture = [self metadataValueForKey:"general.architecture"];
    if (architecture == nil || architecture.length == 0) {
        return YES;
    }

    if (AULlamaKVCacheTypeIsQuantized(typeK)) {
        NSString *metadataKey = [NSString stringWithFormat:@"%@.attention.key_length", architecture];
        NSNumber *keyLength = [self metadataIntegerForKey:metadataKey.UTF8String];
        const NSInteger blockSize = AULlamaKVCacheBlockSize(typeK);
        if (keyLength != nil && blockSize > 1 && keyLength.integerValue % blockSize != 0) {
            if (error != nil) {
                *error = AULlamaMakeError(
                    AULlamaRuntimeErrorCodeInitialization,
                    [NSString stringWithFormat:
                        @"Requested K cache type %@ requires %@ to be divisible by %ld, but found %@.",
                        AULlamaKVCacheTypeName(typeK),
                        metadataKey,
                        (long) blockSize,
                        keyLength]
                );
            }
            return NO;
        }
    }

    if (AULlamaKVCacheTypeIsQuantized(typeV)) {
        NSString *metadataKey = [NSString stringWithFormat:@"%@.attention.value_length", architecture];
        NSNumber *valueLength = [self metadataIntegerForKey:metadataKey.UTF8String];
        const NSInteger blockSize = AULlamaKVCacheBlockSize(typeV);
        if (valueLength != nil && blockSize > 1 && valueLength.integerValue % blockSize != 0) {
            if (error != nil) {
                *error = AULlamaMakeError(
                    AULlamaRuntimeErrorCodeInitialization,
                    [NSString stringWithFormat:
                        @"Requested V cache type %@ requires %@ to be divisible by %ld, but found %@.",
                        AULlamaKVCacheTypeName(typeV),
                        metadataKey,
                        (long) blockSize,
                        valueLength]
                );
            }
            return NO;
        }
    }

    return YES;
}

- (BOOL)initializeContextWithContextLength:(NSInteger)contextLength
                        flashAttentionMode:(AULlamaRuntimeFlashAttentionMode)flashAttentionMode
                                     typeK:(AULlamaRuntimeKVCacheType)typeK
                                     typeV:(AULlamaRuntimeKVCacheType)typeV
                                     error:(NSError * _Nullable * _Nullable)error {
    llama_context_params contextParams = llama_context_default_params();
    contextParams.n_ctx = (uint32_t)MAX(512, contextLength);
    contextParams.n_batch = (uint32_t)MAX(512, MIN(contextLength, 2048));
    contextParams.n_ubatch = (uint32_t)MAX(512, MIN(contextLength, 2048));
    contextParams.n_seq_max = 1;
    contextParams.n_threads = (int32_t)MAX(1, (NSInteger)NSProcessInfo.processInfo.processorCount);
    contextParams.n_threads_batch = contextParams.n_threads;
    contextParams.flash_attn_type = AULlamaFlashAttentionTypeForMode(flashAttentionMode);
    contextParams.type_k = AULlamaGGMLTypeForKVCacheType(typeK);
    contextParams.type_v = AULlamaGGMLTypeForKVCacheType(typeV);
    contextParams.no_perf = true;

    _context = llama_init_from_model(_model, contextParams);
    if (_context != nullptr) {
        return YES;
    }

    if (error != nil) {
        *error = AULlamaMakeError(
            AULlamaRuntimeErrorCodeInitialization,
            [NSString stringWithFormat:
                @"Unable to initialize llama context with flash_attention=%@, type_k=%@, type_v=%@.",
                flashAttentionMode == AULlamaRuntimeFlashAttentionModeAuto ? @"auto" : @"disabled",
                AULlamaKVCacheTypeName(typeK),
                AULlamaKVCacheTypeName(typeV)]
        );
    }
    return NO;
}

- (void)dealloc {
    if (_context != nullptr) {
        llama_free(_context);
    }
    if (_model != nullptr) {
        llama_model_free(_model);
    }
}

- (nullable NSString *)translatePrompt:(NSString *)prompt
                             maxTokens:(NSInteger)maxTokens
                           temperature:(double)temperature
                                  topK:(NSInteger)topK
                                  topP:(double)topP
                     repetitionPenalty:(double)repetitionPenalty
                                 error:(NSError * _Nullable * _Nullable)error {
    llama_memory_clear(llama_get_memory(_context), true);

    std::vector<llama_token> promptTokens;
    if (![self tokenizeText:prompt into:&promptTokens error:error]) {
        return nil;
    }

    if (promptTokens.empty()) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"Prompt tokenization produced no tokens."
            );
        }
        return nil;
    }

    llama_batch promptBatch = llama_batch_get_one(promptTokens.data(), (int32_t)promptTokens.size());
    if (llama_decode(_context, promptBatch) != 0) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"llama_decode failed while processing the prompt."
            );
        }
        return nil;
    }

    llama_sampler *sampler = [self createSamplerWithTemperature:temperature
                                                           topK:topK
                                                           topP:topP
                                              repetitionPenalty:repetitionPenalty
                                                          error:error];
    if (sampler == nullptr) {
        return nil;
    }

    std::vector<llama_token> generatedTokens;
    generatedTokens.reserve((size_t)MAX(1, maxTokens));

    for (NSInteger index = 0; index < maxTokens; index += 1) {
        llama_token nextToken = llama_sampler_sample(sampler, _context, -1);
        if (llama_vocab_is_eog(_vocab, nextToken)) {
            break;
        }

        generatedTokens.push_back(nextToken);
        llama_sampler_accept(sampler, nextToken);

        llama_token token = nextToken;
        llama_batch tokenBatch = llama_batch_get_one(&token, 1);
        if (llama_decode(_context, tokenBatch) != 0) {
            llama_sampler_free(sampler);

            if (error != nil) {
                *error = AULlamaMakeError(
                    AULlamaRuntimeErrorCodeInference,
                    @"llama_decode failed while generating completion tokens."
                );
            }
            return nil;
        }
    }

    llama_sampler_free(sampler);
    return [self detokenizeTokens:generatedTokens error:error];
}

- (BOOL)tokenizeText:(NSString *)text
                into:(std::vector<llama_token> *)tokens
               error:(NSError * _Nullable * _Nullable)error {
    const char *utf8 = text.UTF8String;
    const int32_t utf8Count = (int32_t)strlen(utf8);
    const int32_t estimatedCount = MAX(utf8Count + 8, 32);
    tokens->assign((size_t)estimatedCount, llama_token());

    int32_t tokenCount = llama_tokenize(
        _vocab,
        utf8,
        utf8Count,
        tokens->data(),
        (int32_t)tokens->size(),
        true,
        true
    );

    if (tokenCount == std::numeric_limits<int32_t>::min()) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"Prompt tokenization overflowed."
            );
        }
        return NO;
    }

    if (tokenCount < 0) {
        const int32_t requiredCount = (int32_t)abs(tokenCount);
        tokens->assign((size_t)requiredCount, llama_token());
        tokenCount = llama_tokenize(
            _vocab,
            utf8,
            utf8Count,
            tokens->data(),
            (int32_t)tokens->size(),
            true,
            true
        );
    }

    if (tokenCount < 0) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"Prompt tokenization failed."
            );
        }
        return NO;
    }

    tokens->resize((size_t)tokenCount);
    return YES;
}

- (nullable NSString *)detokenizeTokens:(const std::vector<llama_token> &)tokens
                                  error:(NSError * _Nullable * _Nullable)error {
    if (tokens.empty()) {
        return @"";
    }

    std::vector<char> bytes((size_t)MAX((NSInteger)tokens.size() * 8, 256), '\0');
    int32_t decodedCount = llama_detokenize(
        _vocab,
        tokens.data(),
        (int32_t)tokens.size(),
        bytes.data(),
        (int32_t)bytes.size(),
        true,
        false
    );

    if (decodedCount == std::numeric_limits<int32_t>::min()) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"Completion detokenization overflowed."
            );
        }
        return nil;
    }

    if (decodedCount < 0) {
        bytes.assign((size_t)abs(decodedCount) + 1, '\0');
        decodedCount = llama_detokenize(
            _vocab,
            tokens.data(),
            (int32_t)tokens.size(),
            bytes.data(),
            (int32_t)bytes.size(),
            true,
            false
        );
    }

    if (decodedCount < 0) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInference,
                @"Completion detokenization failed."
            );
        }
        return nil;
    }

    return [[NSString alloc] initWithBytes:bytes.data() length:(NSUInteger)decodedCount encoding:NSUTF8StringEncoding];
}

- (llama_sampler *)createSamplerWithTemperature:(double)temperature
                                           topK:(NSInteger)topK
                                           topP:(double)topP
                              repetitionPenalty:(double)repetitionPenalty
                                          error:(NSError * _Nullable * _Nullable)error {
    llama_sampler *chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (chain == nullptr) {
        if (error != nil) {
            *error = AULlamaMakeError(
                AULlamaRuntimeErrorCodeInitialization,
                @"Unable to create llama sampler chain."
            );
        }
        return nullptr;
    }

    auto addSampler = [&](llama_sampler *sampler, NSString *message) -> bool {
        if (sampler == nullptr) {
            llama_sampler_free(chain);
            if (error != nil) {
                *error = AULlamaMakeError(AULlamaRuntimeErrorCodeInitialization, message);
            }
            return false;
        }

        llama_sampler_chain_add(chain, sampler);
        return true;
    };

    if (!addSampler(llama_sampler_init_top_k((int32_t)MAX(1, topK)), @"Unable to create llama top-k sampler.")) {
        return nullptr;
    }
    if (!addSampler(llama_sampler_init_top_p((float)MAX(0.0, topP), 1), @"Unable to create llama top-p sampler.")) {
        return nullptr;
    }
    if (!addSampler(
            llama_sampler_init_penalties(-1, (float)MAX(1.0, repetitionPenalty), 0, 0),
            @"Unable to create llama repetition penalty sampler."
        )) {
        return nullptr;
    }

    if (temperature <= 0) {
        if (!addSampler(llama_sampler_init_greedy(), @"Unable to create llama greedy sampler.")) {
            return nullptr;
        }
    } else {
        if (!addSampler(llama_sampler_init_temp((float)temperature), @"Unable to create llama temperature sampler.")) {
            return nullptr;
        }
        if (!addSampler(llama_sampler_init_dist(0), @"Unable to create llama distribution sampler.")) {
            return nullptr;
        }
    }

    return chain;
}

@end
