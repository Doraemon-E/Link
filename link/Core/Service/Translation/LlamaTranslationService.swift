//
//  LlamaTranslationService.swift
//  link
//
//  Created by Codex on 2026/4/10.
//

import Foundation

actor LlamaTranslationService: TranslationService {
    private struct LoadedState {
        let packageID: String
        let manifest: TranslationModelManifest
        let runtime: LlamaTranslationRuntime
    }

    private let modelProvider: any TranslationModelProviding
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

        guard try await modelProvider.packageMetadata(source: source, target: target) != nil else {
            throw TranslationError.unsupportedLanguagePair(source: source, target: target)
        }

        return TranslationRoute(
            source: source,
            target: target,
            steps: [
                TranslationRouteStep(source: source, target: target)
            ]
        )
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

    private func translateDirect(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> String {
        let state = try await loadState(source: source, target: target)

        guard state.manifest.supports(source: source, target: target) else {
            throw TranslationError.unsupportedLanguagePair(source: source, target: target)
        }

        return try state.runtime.translate(
            text: text,
            source: source,
            target: target
        )
    }

    private func loadState(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> LoadedState {
        guard let installation = try await modelProvider.installedPackage(for: source, target: target) else {
            if try await modelProvider.packageMetadata(source: source, target: target) != nil {
                throw TranslationError.modelNotInstalled(source: source, target: target)
            }

            throw TranslationError.modelPackageUnavailable(source: source, target: target)
        }

        if let loadedState, loadedState.packageID == installation.package.packageId {
            return loadedState
        }

        let runtime = try LlamaTranslationRuntime(
            modelDirectoryURL: installation.modelDirectoryURL,
            manifest: installation.manifest
        )
        let nextState = LoadedState(
            packageID: installation.package.packageId,
            manifest: installation.manifest,
            runtime: runtime
        )
        loadedState = nextState
        return nextState
    }
}
