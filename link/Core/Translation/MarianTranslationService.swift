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
    private var loadedState: LoadedState?

    init(
        installer: TranslationModelInstaller = TranslationModelInstaller(
            catalogService: TranslationModelCatalogService(remoteCatalogURL: nil)
        )
    ) {
        self.installer = installer
    }

    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool {
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

    func route(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRoute {
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

    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String {
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

    private func translateDirect(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String {
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

        return translatedText
    }

    private func routeStep(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRouteStep? {
        guard let package = try await installer.packageMetadata(source: source, target: target) else {
            return nil
        }

        let isInstalled = try await installer.isInstalled(source: source, target: target)
        return TranslationRouteStep(
            source: source,
            target: target,
            packageId: package.packageId,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            isInstalled: isInstalled
        )
    }

    private func loadState(source: HomeLanguage, target: HomeLanguage) async throws -> LoadedState {
        guard let installation = try await installer.installedPackage(for: source, target: target) else {
            if try await installer.packageMetadata(source: source, target: target) != nil {
                throw TranslationError.modelNotInstalled(source: source, target: target)
            }

            throw TranslationError.modelPackageUnavailable(source: source, target: target)
        }

        if let loadedState, loadedState.packageID == installation.package.packageId {
            return loadedState
        }

        loadedState = nil

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
            loadedState = state
            return state
        } catch {
            throw TranslationError.runtimeInitialization(error.localizedDescription)
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
                    let candidate = floatBuffer[startIndex + offset]
                    if candidate > bestValue {
                        bestValue = candidate
                        bestIndex = offset
                    }
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
