//
//  MarianTranslationService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import onnxruntime_objc

// TODO: 后续进行性能调优
/// 没有做 beam search
/// 也还没启用 decoder_with_past_model.onnx 做缓存优化

actor MarianTranslationService: TranslationService {
    private struct LoadedState {
        let packageID: String
        let manifest: TranslationModelManifest
        let tokenizer: TokenizerAdapter
        let environment: ORTEnv
        let encoderSession: ORTSession
        let decoderSession: ORTSession
    }

    private let installer: TranslationModelInstaller
    private var loadedStates: [String: LoadedState] = [:]
    private let logger = AppLogger.translation

    init(
        installer: TranslationModelInstaller = TranslationModelInstaller(
            catalogService: TranslationModelCatalogService(remoteCatalogURL: nil)
        )
    ) {
        self.installer = installer
    }

    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool {
        try await AppTrace.withMetadata(Self.languageMetadata(source: source, target: target)) {
            logger.debug("Checking whether Marian translation supports the requested language pair")

            if source == target {
                logger.info("Marian translation supports the request because source and target are identical")
                return true
            }

            let supported = try await installer.packageMetadata(source: source, target: target) != nil
            logger.info(
                "Finished Marian translation support check",
                metadata: ["supported": "\(supported)"]
            )
            return supported
        }
    }

    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String {
        let startedAt = Date()

        return try await AppTrace.withMetadata(Self.languageMetadata(source: source, target: target)) {
            logger.info(
                "Marian translation started",
                metadata: ["input_length": "\(text.count)"]
            )

            do {
                if source == target {
                    logger.info(
                        "Marian translation returned the original text because source and target are identical",
                        metadata: ["duration_ms": appElapsedMilliseconds(since: startedAt)]
                    )
                    return text
                }

                let state = try await loadState(source: source, target: target)

                guard state.manifest.supports(source: source, target: target) else {
                    throw TranslationError.unsupportedLanguagePair(source: source, target: target)
                }

                let inputTokenIDs = try state.tokenizer.encode(
                    text,
                    maxLength: state.manifest.generation.maxInputLength,
                    eosTokenID: state.manifest.generation.eosTokenId
                )
                let attentionMask = Array(repeating: Int64(1), count: inputTokenIDs.count)

                logger.debug(
                    "Prepared Marian encoder inputs",
                    metadata: [
                        "input_token_count": "\(inputTokenIDs.count)",
                        "package_id": state.packageID
                    ]
                )

                let encoderInputs = try [
                    state.manifest.tensorNames.encoderInputIDs: makeInt64Tensor(
                        inputTokenIDs,
                        shape: [1, inputTokenIDs.count]
                    ),
                    state.manifest.tensorNames.encoderAttentionMask: makeInt64Tensor(
                        attentionMask,
                        shape: [1, attentionMask.count]
                    )
                ]

                let encoderOutputs = try state.encoderSession.run(
                    withInputs: encoderInputs,
                    outputNames: [state.manifest.tensorNames.encoderOutput],
                    runOptions: nil
                )

                guard let encoderHiddenStates = encoderOutputs[state.manifest.tensorNames.encoderOutput] else {
                    throw TranslationError.inferenceFailed("Encoder output tensor is missing.")
                }

                var decoderTokenIDs = [Int64(state.manifest.generation.decoderStartTokenId)]
                var generatedTokenIDs: [Int64] = []
                var stopReason = "max_output_length"

                for _ in 0 ..< state.manifest.generation.maxOutputLength {
                    let decoderInputs = try [
                        state.manifest.tensorNames.decoderInputIDs: makeInt64Tensor(
                            decoderTokenIDs,
                            shape: [1, decoderTokenIDs.count]
                        ),
                        state.manifest.tensorNames.decoderEncoderAttentionMask: makeInt64Tensor(
                            attentionMask,
                            shape: [1, attentionMask.count]
                        ),
                        state.manifest.tensorNames.decoderEncoderHiddenStates: encoderHiddenStates
                    ]

                    let decoderOutputs = try state.decoderSession.run(
                        withInputs: decoderInputs,
                        outputNames: [state.manifest.tensorNames.decoderOutputLogits],
                        runOptions: nil
                    )

                    guard let logitsValue = decoderOutputs[state.manifest.tensorNames.decoderOutputLogits] else {
                        throw TranslationError.inferenceFailed("Decoder logits tensor is missing.")
                    }

                    let nextTokenID = try argmaxForLastStep(logitsValue)

                    if nextTokenID == Int64(state.manifest.generation.eosTokenId) {
                        stopReason = "eos_token"
                        break
                    }

                    generatedTokenIDs.append(nextTokenID)
                    decoderTokenIDs.append(nextTokenID)
                }

                let translatedText = try state.tokenizer.decode(
                    generatedTokenIDs,
                    eosTokenID: state.manifest.generation.eosTokenId,
                    padTokenID: state.manifest.generation.padTokenId
                )

                guard !translatedText.isEmpty else {
                    throw TranslationError.emptyOutput
                }

                logger.info(
                    "Marian translation finished",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "output_length": "\(translatedText.count)",
                        "output_token_count": "\(generatedTokenIDs.count)",
                        "package_id": state.packageID,
                        "stop_reason": stopReason
                    ]
                )
                return translatedText
            } catch {
                logger.error(
                    "Marian translation failed",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error)
                    ]
                )
                throw error
            }
        }
    }

    private func loadState(source: HomeLanguage, target: HomeLanguage) async throws -> LoadedState {
        try await AppTrace.withMetadata(Self.languageMetadata(source: source, target: target)) {
            logger.debug("Loading Marian runtime state")

            guard let installation = try await installer.installedPackage(for: source, target: target) else {
                if try await installer.packageMetadata(source: source, target: target) != nil {
                    logger.error("Marian runtime state is unavailable because the model is not installed")
                    throw TranslationError.modelNotInstalled(source: source, target: target)
                }

                logger.error("Marian runtime state is unavailable because no package exists for this language pair")
                throw TranslationError.modelPackageUnavailable(source: source, target: target)
            }

            return try await AppTrace.withMetadata(["package_id": installation.package.packageId]) {
                if let loadedState = loadedStates[installation.package.packageId] {
                    logger.info("Reused cached Marian runtime state")
                    return loadedState
                }

                let manifest = installation.manifest

                guard manifest.family == .marian else {
                    throw TranslationError.manifestInvalid("Unsupported model family: \(manifest.family.rawValue)")
                }

                let tokenizer = try MarianSentencePieceTokenizerAdapter(
                    modelDirectoryURL: installation.modelDirectoryURL,
                    manifest: manifest
                )

                do {
                    let environment = try ORTEnv(loggingLevel: .warning)
                    let encoderSession = try ORTSession(
                        env: environment,
                        modelPath: installation.modelDirectoryURL
                            .appendingPathComponent(manifest.onnxFiles.encoder, isDirectory: false)
                            .path,
                        sessionOptions: nil
                    )
                    let decoderSession = try ORTSession(
                        env: environment,
                        modelPath: installation.modelDirectoryURL
                            .appendingPathComponent(manifest.onnxFiles.decoder, isDirectory: false)
                            .path,
                        sessionOptions: nil
                    )

                    let state = LoadedState(
                        packageID: installation.package.packageId,
                        manifest: manifest,
                        tokenizer: tokenizer,
                        environment: environment,
                        encoderSession: encoderSession,
                        decoderSession: decoderSession
                    )
                    loadedStates[installation.package.packageId] = state

                    logger.info(
                        "Initialized Marian runtime state",
                        metadata: [
                            "encoder_model": manifest.onnxFiles.encoder,
                            "decoder_model": manifest.onnxFiles.decoder
                        ]
                    )
                    return state
                } catch {
                    logger.error(
                        "Failed to initialize Marian runtime state",
                        metadata: ["error": appLogErrorDescription(error)]
                    )
                    throw TranslationError.runtimeInitialization(error.localizedDescription)
                }
            }
        }
    }

    private func makeInt64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }

        do {
            return try ORTValue(
                tensorData: NSMutableData(data: data),
                elementType: .int64,
                shape: shape.map(NSNumber.init(value:))
            )
        } catch {
            throw TranslationError.inferenceFailed(error.localizedDescription)
        }
    }

    private func argmaxForLastStep(_ logitsValue: ORTValue) throws -> Int64 {
        do {
            let tensorData = try logitsValue.tensorData()
            let tensorInfo = try logitsValue.tensorTypeAndShapeInfo()
            let shape = tensorInfo.shape.map(\.intValue)

            guard shape.count == 3, let sequenceLength = shape.dropLast().last, let vocabSize = shape.last else {
                throw TranslationError.inferenceFailed("Unexpected logits tensor shape.")
            }

            let floatBuffer = Data(referencing: tensorData).withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self))
            }
            let startIndex = (sequenceLength - 1) * vocabSize
            let endIndex = startIndex + vocabSize

            guard startIndex >= 0, endIndex <= floatBuffer.count else {
                throw TranslationError.inferenceFailed("Decoder logits buffer is out of bounds.")
            }

            var bestIndex = 0
            var bestValue = -Float.infinity

            for offset in 0 ..< vocabSize {
                let candidate = floatBuffer[startIndex + offset]
                if candidate > bestValue {
                    bestValue = candidate
                    bestIndex = offset
                }
            }

            return Int64(bestIndex)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.inferenceFailed(error.localizedDescription)
        }
    }

    private static func languageMetadata(
        source: HomeLanguage,
        target: HomeLanguage
    ) -> [String: String] {
        [
            "source_language": source.translationModelCode,
            "target_language": target.translationModelCode
        ]
    }
}
