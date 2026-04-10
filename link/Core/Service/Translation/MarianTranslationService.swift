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

        guard !route.steps.isEmpty else {
            return text
        }

        var translatedText = text
        for step in route.steps {
            translatedText = try await translateDirect(
                text: translatedText,
                source: step.source,
                target: step.target
            )
        }

        return translatedText
    }

    nonisolated func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    Self.log(
                        "streamTranslation started source=\(source.rawValue) target=\(target.rawValue) text=\(Self.preview(text))"
                    )
                    continuation.yield(.started)

                    let translatedText = try await self.translate(
                        text: text,
                        source: source,
                        target: target
                    )
                    Self.log(
                        "streamTranslation produced translation source=\(source.rawValue) target=\(target.rawValue) text=\(Self.preview(translatedText))"
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

                    Self.log(
                        "streamTranslation completed source=\(source.rawValue) target=\(target.rawValue)"
                    )
                    continuation.yield(.completed(text: translatedText))
                    continuation.finish()
                } catch is CancellationError {
                    Self.log(
                        "streamTranslation cancelled source=\(source.rawValue) target=\(target.rawValue)"
                    )
                    continuation.finish()
                } catch {
                    Self.log(
                        "streamTranslation failed source=\(source.rawValue) target=\(target.rawValue) error=\(error.localizedDescription)"
                    )
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func translateDirect(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        log(
            "translateDirect started source=\(source.rawValue) target=\(target.rawValue) textLength=\(text.count) text=\(preview(text))"
        )
        let state = try await loadState(source: source, target: target)

        guard state.manifest.supports(source: source, target: target) else {
            throw TranslationError.unsupportedLanguagePair(source: source, target: target)
        }

        guard let tensorNames = state.manifest.tensorNames else {
            throw TranslationError.manifestInvalid("Missing Marian tensor names.")
        }

        let eosTokenID = state.manifest.generation.eosTokenId ?? 0
        let padTokenID = state.manifest.generation.padTokenId ?? 65000
        let decoderStartTokenID = state.manifest.generation.decoderStartTokenId ?? padTokenID

        let inputTokenIDs = try state.tokenizer.encode(
            preparedInputText(text),
            maxLength: state.manifest.generation.maxInputLength,
            eosTokenID: eosTokenID
        )
        let attentionMask = Array(repeating: Int64(1), count: inputTokenIDs.count)
        log(
            "translateDirect tokenized source=\(source.rawValue) target=\(target.rawValue) inputTokens=\(inputTokenIDs.count)"
        )

        let encoderInputs = try [
            tensorNames.encoderInputIDs: makeInt64Tensor(
                inputTokenIDs,
                shape: [1, inputTokenIDs.count]
            ),
            tensorNames.encoderAttentionMask: makeInt64Tensor(
                attentionMask,
                shape: [1, attentionMask.count]
            )
        ]

        log("translateDirect encoder started source=\(source.rawValue) target=\(target.rawValue)")
        let encoderOutputs = try state.encoderSession.run(
            withInputs: encoderInputs,
            outputNames: [tensorNames.encoderOutput],
            runOptions: nil
        )
        log("translateDirect encoder finished source=\(source.rawValue) target=\(target.rawValue)")

        guard let encoderHiddenStates = encoderOutputs[tensorNames.encoderOutput] else {
            throw TranslationError.inferenceFailed("Encoder output tensor is missing.")
        }

        var decoderTokenIDs = [Int64(decoderStartTokenID)]
        var generatedTokenIDs: [Int64] = []
        let maxDecoderSteps = effectiveMaxOutputLength(
            forInputTokenCount: inputTokenIDs.count,
            manifest: state.manifest
        )
        let decoderStartTick = DispatchTime.now().uptimeNanoseconds
        log(
            "translateDirect decoder started source=\(source.rawValue) target=\(target.rawValue) maxSteps=\(maxDecoderSteps)"
        )

        for stepIndex in 0 ..< maxDecoderSteps {
            let stepNumber = stepIndex + 1
            let shouldTraceStep = stepNumber <= 4 || stepNumber >= 65 || stepNumber.isMultiple(of: 16)
            if shouldTraceStep {
                log(
                    "translateDirect decoder step started source=\(source.rawValue) target=\(target.rawValue) step=\(stepNumber) currentSequenceLength=\(decoderTokenIDs.count)"
                )
            }

            let stepStartTick = DispatchTime.now().uptimeNanoseconds
            let nextTokenID: Int64 = try autoreleasepool {
                let decoderInputs = try [
                    tensorNames.decoderInputIDs: makeInt64Tensor(
                        decoderTokenIDs,
                        shape: [1, decoderTokenIDs.count]
                    ),
                    tensorNames.decoderEncoderAttentionMask: makeInt64Tensor(
                        attentionMask,
                        shape: [1, attentionMask.count]
                    ),
                    tensorNames.decoderEncoderHiddenStates: encoderHiddenStates
                ]

                let decoderOutputs = try state.decoderSession.run(
                    withInputs: decoderInputs,
                    outputNames: [tensorNames.decoderOutputLogits],
                    runOptions: nil
                )

                guard let logitsValue = decoderOutputs[tensorNames.decoderOutputLogits] else {
                    throw TranslationError.inferenceFailed("Decoder logits tensor is missing.")
                }

                return try argmaxForLastStep(
                    logitsValue,
                    suppressedTokenIDs: state.suppressedTokenIDs
                )
            }
            let stepDurationMilliseconds = milliseconds(since: stepStartTick)

            if shouldTraceStep {
                log(
                    "translateDirect decoder step finished source=\(source.rawValue) target=\(target.rawValue) step=\(stepNumber) nextTokenID=\(nextTokenID) durationMs=\(formatMilliseconds(stepDurationMilliseconds))"
                )
            }

            if nextTokenID == Int64(eosTokenID) {
                log(
                    "translateDirect decoder reached EOS source=\(source.rawValue) target=\(target.rawValue) step=\(stepNumber) totalDurationMs=\(formatMilliseconds(milliseconds(since: decoderStartTick)))"
                )
                break
            }

            generatedTokenIDs.append(nextTokenID)
            decoderTokenIDs.append(nextTokenID)

            if stepNumber.isMultiple(of: 16) {
                log(
                    "translateDirect decoder progress source=\(source.rawValue) target=\(target.rawValue) step=\(stepNumber) generatedTokens=\(generatedTokenIDs.count) elapsedMs=\(formatMilliseconds(milliseconds(since: decoderStartTick)))"
                )
            }
        }

        let translatedText = try state.tokenizer.decode(
            generatedTokenIDs,
            eosTokenID: eosTokenID,
            padTokenID: padTokenID
        )

        guard !translatedText.isEmpty else {
            throw TranslationError.emptyOutput
        }

        log(
            "translateDirect completed source=\(source.rawValue) target=\(target.rawValue) outputLength=\(translatedText.count) totalDecoderDurationMs=\(formatMilliseconds(milliseconds(since: decoderStartTick))) text=\(preview(translatedText))"
        )
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
            log(
                "Reusing translation state packageID=\(installation.package.packageId) source=\(source.rawValue) target=\(target.rawValue)"
            )
            return loadedState
        }

        loadedState = nil

        let manifest = installation.manifest
        guard manifest.family == .marian else {
            throw TranslationError.runtimeInitialization("Marian runtime received a non-Marian manifest.")
        }

        guard let onnxFiles = manifest.onnxFiles else {
            throw TranslationError.manifestInvalid("Missing Marian ONNX file configuration.")
        }

        let tokenizer = try SentencePieceTokenizerAdapter(
            modelDirectoryURL: installation.modelDirectoryURL,
            manifest: manifest
        )

        do {
            log(
                "Loading translation state packageID=\(installation.package.packageId) source=\(source.rawValue) target=\(target.rawValue)"
            )
            let environment = try sharedEnvironment()
            let encoderSession = try ORTSession(
                env: environment,
                modelPath: installation.modelDirectoryURL
                    .appendingPathComponent(onnxFiles.encoder, isDirectory: false)
                    .path,
                sessionOptions: nil
            )
            let decoderSession = try ORTSession(
                env: environment,
                modelPath: installation.modelDirectoryURL
                    .appendingPathComponent(onnxFiles.decoder, isDirectory: false)
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
            log(
                "Loaded translation state packageID=\(installation.package.packageId) source=\(source.rawValue) target=\(target.rawValue)"
            )
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
            if let data = try? Data(contentsOf: generationConfigURL),
               let generationConfig = try? JSONDecoder().decode(GenerationConfigOverrides.self, from: data) {
                suppressedTokenIDs.formUnion((generationConfig.badWordsIds ?? []).compactMap { tokenIDs in
                    guard tokenIDs.count == 1 else {
                        return nil
                    }

                    return Int64(tokenIDs[0])
                })
            }
        }

        return suppressedTokenIDs
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

    private nonisolated static func log(_ message: String) {
        print("[MarianTranslationService] \(message)")
    }

    private nonisolated func log(_ message: String) {
        Self.log(message)
    }

    private nonisolated static func preview(_ text: String, maxLength: Int = 120) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "\"\""
        }

        let preview = normalized.count > maxLength
            ? String(normalized.prefix(maxLength)) + "..."
            : normalized
        return "\"\(preview)\""
    }

    private nonisolated func preview(_ text: String, maxLength: Int = 120) -> String {
        Self.preview(text, maxLength: maxLength)
    }

    private nonisolated func milliseconds(since startTick: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startTick) / 1_000_000
    }

    private nonisolated func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
}
