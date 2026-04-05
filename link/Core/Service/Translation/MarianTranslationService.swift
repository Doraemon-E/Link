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
        let suppressedTokenIDs: Set<Int64>
    }

    private struct GenerationConfigOverrides: Decodable {
        let badWordsIds: [[Int]]?

        enum CodingKeys: String, CodingKey {
            case badWordsIds = "bad_words_ids"
        }
    }

    private let modelProvider: any TranslationModelProviding
    private var environment: ORTEnv?
    private var loadedState: LoadedState?

    init(
        modelProvider: any TranslationModelProviding = TranslationModelPackageManager(
            catalogRepository: TranslationModelCatalogRepository(remoteCatalogURL: nil)
        )
    ) {
        self.modelProvider = modelProvider
    }

    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool {
        do {
            _ = try await route(source: source, target: target)
            return true
        } catch let error as TranslationError {
            if case .unsupportedLanguagePair = error {
                return false
            }

            throw error
        } catch {
            throw error
        }
    }

    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute {
        if source == target {
            return TranslationRoute(source: source, target: target, steps: [])
        }

        if let directStep = try await routeStep(source: source, target: target) {
            return TranslationRoute(source: source, target: target, steps: [directStep])
        }

        if source != .english,
           target != .english,
           let toEnglishStep = try await routeStep(source: source, target: .english),
           let fromEnglishStep = try await routeStep(source: .english, target: target) {
            return TranslationRoute(
                source: source,
                target: target,
                steps: [toEnglishStep, fromEnglishStep]
            )
        }

        throw TranslationError.unsupportedLanguagePair(source: source, target: target)
    }

    func translate(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        let route = try await route(source: source, target: target)
        debugLog(
            "route \(source.displayName)->\(target.displayName): " +
            route.steps.map { "\($0.source.displayName)->\($0.target.displayName)" }.joined(separator: ", ")
        )

        guard !route.steps.isEmpty else {
            return text
        }

        var translatedText = text
        for step in route.steps {
            debugLog("step input \(step.source.displayName)->\(step.target.displayName): \"\(translatedText)\"")
            translatedText = try await translateDirect(
                text: translatedText,
                source: step.source,
                target: step.target
            )
            debugLog("step output \(step.source.displayName)->\(step.target.displayName): \"\(translatedText)\"")
        }

        return translatedText
    }

    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.started)

                    let translatedText = try await self.translate(
                        text: text,
                        source: source,
                        target: target
                    )

                    var revision = 0
                    for try await partialText in TypingRenderer.stream(
                        text: translatedText,
                        language: target
                    ) {
                        revision += 1
                        continuation.yield(
                            .partial(
                                text: partialText,
                                revision: revision,
                                isFinal: partialText == translatedText
                            )
                        )
                    }

                    continuation.yield(.completed(text: translatedText))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func translateDirect(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        let state = try await loadState(source: source, target: target)

        guard state.manifest.supports(source: source, target: target) else {
            throw TranslationError.unsupportedLanguagePair(source: source, target: target)
        }

        let modelInputText = preparedInputText(
            text
        )

        let inputTokenIDs = try state.tokenizer.encode(
            modelInputText,
            maxLength: state.manifest.generation.maxInputLength,
            eosTokenID: state.manifest.generation.eosTokenId
        )
        let attentionMask = Array(repeating: Int64(1), count: inputTokenIDs.count)

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
        let maxDecoderSteps = effectiveMaxOutputLength(
            forInputTokenCount: inputTokenIDs.count,
            manifest: state.manifest
        )

        debugLog(
            "translateDirect start package=\(state.packageID) " +
            "\(source.displayName)->\(target.displayName) " +
            "text=\"\(text)\" modelInput=\"\(modelInputText)\" " +
            "inputTokenIDs=\(formattedTokenIDs(inputTokenIDs)) " +
            "maxDecoderSteps=\(maxDecoderSteps) " +
            "suppressedTokenIDs=\(formattedTokenIDs(Array(state.suppressedTokenIDs).sorted()))"
        )

        for _ in 0 ..< maxDecoderSteps {
            let nextTokenID: Int64 = try autoreleasepool {
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

                return try argmaxForLastStep(
                    logitsValue,
                    suppressedTokenIDs: state.suppressedTokenIDs
                )
            }

            if generatedTokenIDs.isEmpty {
                let firstTokenDescription = state.tokenizer.debugTokenDescription(
                    nextTokenID,
                    eosTokenID: state.manifest.generation.eosTokenId,
                    padTokenID: state.manifest.generation.padTokenId
                )
                debugLog(
                    "first nextTokenID package=\(state.packageID): \(nextTokenID), " +
                    "token=\"\(firstTokenDescription)\", " +
                    "isEOS=\(nextTokenID == Int64(state.manifest.generation.eosTokenId))"
                )
            }

            if nextTokenID == Int64(state.manifest.generation.eosTokenId) {
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
        let generatedTokenDescriptions = formattedTokenDescriptions(
            generatedTokenIDs,
            tokenizer: state.tokenizer,
            eosTokenID: state.manifest.generation.eosTokenId,
            padTokenID: state.manifest.generation.padTokenId
        )

        debugLog(
            "translateDirect result package=\(state.packageID) " +
            "generatedTokenIDs=\(formattedTokenIDs(generatedTokenIDs)) " +
            "generatedTokens=\(generatedTokenDescriptions) " +
            "decoded=\"\(translatedText)\""
        )

        guard !translatedText.isEmpty else {
            debugLog("translateDirect empty output package=\(state.packageID)")
            throw TranslationError.emptyOutput
        }

        return translatedText
    }

    private func effectiveMaxOutputLength(
        forInputTokenCount inputTokenCount: Int,
        manifest: TranslationModelManifest
    ) -> Int {
        let manifestLimit = manifest.generation.maxOutputLength
        let heuristicLimit = max(32, (inputTokenCount * 3) + 16)
        return min(manifestLimit, heuristicLimit)
    }

    private func routeStep(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRouteStep? {
        guard try await modelProvider.packageMetadata(source: source, target: target) != nil else {
            return nil
        }

        return TranslationRouteStep(
            source: source,
            target: target
        )
    }

    private func loadState(source: SupportedLanguage, target: SupportedLanguage) async throws -> LoadedState {
        guard let installation = try await modelProvider.installedPackage(for: source, target: target) else {
            if try await modelProvider.packageMetadata(source: source, target: target) != nil {
                throw TranslationError.modelNotInstalled(source: source, target: target)
            }

            throw TranslationError.modelPackageUnavailable(source: source, target: target)
        }

        if let loadedState, loadedState.packageID == installation.package.packageId {
            return loadedState
        }

        loadedState = nil

        let manifest = installation.manifest
        let tokenizer = try SentencePieceTokenizerAdapter(
            modelDirectoryURL: installation.modelDirectoryURL,
            manifest: manifest
        )

        do {
            let environment = try sharedEnvironment()
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
                decoderSession: decoderSession,
                suppressedTokenIDs: loadSuppressedTokenIDs(
                    manifest: manifest,
                    modelDirectoryURL: installation.modelDirectoryURL
                )
            )
            loadedState = state
            return state
        } catch {
            throw TranslationError.runtimeInitialization(error.localizedDescription)
        }
    }

    private func preparedInputText(_ text: String) -> String {
        text
    }

    private func sharedEnvironment() throws -> ORTEnv {
        if let environment {
            return environment
        }

        let environment = try ORTEnv(loggingLevel: .warning)
        self.environment = environment
        return environment
    }

    private func loadSuppressedTokenIDs(
        manifest: TranslationModelManifest,
        modelDirectoryURL: URL
    ) -> Set<Int64> {
        var suppressedTokenIDs = Set(manifest.generation.suppressedTokenIds?.map(Int64.init) ?? [])

        let generationConfigURL = modelDirectoryURL.appendingPathComponent(
            "generation_config.json",
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: generationConfigURL.path) {
            do {
                let data = try Data(contentsOf: generationConfigURL)
                let generationConfig = try JSONDecoder().decode(GenerationConfigOverrides.self, from: data)
                suppressedTokenIDs.formUnion((generationConfig.badWordsIds ?? []).compactMap { tokenIDs in
                    guard tokenIDs.count == 1 else {
                        return nil
                    }

                    return Int64(tokenIDs[0])
                })
            } catch {
                debugLog("failed to load suppressed token ids from generation_config.json: \(error.localizedDescription)")
            }
        }

        return suppressedTokenIDs
    }

    private func formattedTokenIDs(_ tokenIDs: [Int64], limit: Int = 24) -> String {
        if tokenIDs.isEmpty {
            return "[]"
        }

        let prefix = tokenIDs.prefix(limit).map(String.init).joined(separator: ", ")
        if tokenIDs.count <= limit {
            return "[\(prefix)]"
        }

        return "[\(prefix), ...] (count=\(tokenIDs.count))"
    }

    private func formattedTokenDescriptions(
        _ tokenIDs: [Int64],
        tokenizer: TokenizerAdapter,
        eosTokenID: Int,
        padTokenID: Int,
        limit: Int = 12
    ) -> String {
        if tokenIDs.isEmpty {
            return "[]"
        }

        let descriptions = tokenIDs.prefix(limit).map {
            "\"\(tokenizer.debugTokenDescription($0, eosTokenID: eosTokenID, padTokenID: padTokenID))\""
        }
        let prefix = descriptions.joined(separator: ", ")

        if tokenIDs.count <= limit {
            return "[\(prefix)]"
        }

        return "[\(prefix), ...] (count=\(tokenIDs.count))"
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[TranslationService] \(message())")
#endif
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

    private func argmaxForLastStep(
        _ logitsValue: ORTValue,
        suppressedTokenIDs: Set<Int64>
    ) throws -> Int64 {
        do {
            let tensorData = try logitsValue.tensorData()
            let tensorInfo = try logitsValue.tensorTypeAndShapeInfo()
            let shape = tensorInfo.shape.map(\.intValue)

            guard shape.count == 3,
                  let batchSize = shape.first,
                  let sequenceLength = shape.dropFirst().first,
                  let vocabSize = shape.last else {
                throw TranslationError.inferenceFailed("Unexpected logits tensor shape.")
            }

            let floatData = Data(referencing: tensorData)
            let startIndex = ((batchSize * sequenceLength) - 1) * vocabSize
            let endIndex = startIndex + vocabSize

            return try floatData.withUnsafeBytes { rawBuffer in
                let floatBuffer = rawBuffer.bindMemory(to: Float.self)

                guard startIndex >= 0, endIndex <= floatBuffer.count else {
                    throw TranslationError.inferenceFailed("Decoder logits buffer is out of bounds.")
                }

                var bestIndex = 0
                var bestValue = -Float.infinity

                for offset in 0 ..< vocabSize {
                    let tokenID = Int64(offset)
                    if suppressedTokenIDs.contains(tokenID) {
                        continue
                    }

                    let candidate = floatBuffer[startIndex + offset]
                    if candidate > bestValue {
                        bestValue = candidate
                        bestIndex = offset
                    }
                }

                guard bestValue.isFinite else {
                    throw TranslationError.inferenceFailed("Decoder logits only contained suppressed tokens.")
                }

                return Int64(bestIndex)
            }
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.inferenceFailed(error.localizedDescription)
        }
    }
}
