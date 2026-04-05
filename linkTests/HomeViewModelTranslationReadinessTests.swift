//
//  HomeViewModelTranslationReadinessTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/5.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeViewModelTranslationReadinessTests: XCTestCase {
    func testResolveLanguageSelectionRequiresDownloadWhenModelsAreMissing() async throws {
        let translationService = TranslationRouteStubService()
        let viewModel = makeViewModel(translationService: translationService)

        let resolution = await viewModel.resolveLanguageSelection(
            source: .chinese,
            target: .english
        )

        switch resolution {
        case .requiresDownload(let prompt):
            XCTAssertFalse(prompt.packageIds.isEmpty)
            XCTAssertGreaterThan(prompt.archiveSize, 0)
        default:
            XCTFail("Expected language selection to require a download.")
        }
    }

    func testSendCurrentMessageShowsDownloadPromptBeforeCreatingConversation() async throws {
        let translationService = TranslationRouteStubService()
        let viewModel = makeViewModel(translationService: translationService)
        let modelContext = try makeModelContext()
        viewModel.messageText = "你好"

        viewModel.sendCurrentMessage(using: modelContext, sessions: [])
        await settle()

        XCTAssertNotNil(viewModel.activeDownloadPrompt)
        XCTAssertEqual(translationService.streamTranslationCallCount, 0)
        XCTAssertEqual(translationService.translateCallCount, 0)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<ChatMessage>()).count, 0)
    }

    private func makeViewModel(
        translationService: TranslationRouteStubService
    ) -> HomeViewModel {
        let translationCatalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: translationCatalogRepository
        )
        let speechCatalogRepository = SpeechModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main
        )
        let speechPackageManager = SpeechModelPackageManager(
            catalogRepository: speechCatalogRepository
        )

        return HomeViewModel(
            appSettings: AppSettings(
                userDefaults: UserDefaults(
                    suiteName: "HomeViewModelTranslationReadinessTests.\(UUID().uuidString)"
                ) ?? .standard
            ),
            translationService: translationService,
            speechRecognitionService: HomeViewModelSpeechRecognitionStub(),
            textToSpeechService: HomeViewModelTextToSpeechStub(),
            speechPackageManager: speechPackageManager,
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )
    }

    private func makeModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        await Task.yield()
    }
}

private final class TranslationRouteStubService: TranslationService, @unchecked Sendable {
    private(set) var translateCallCount = 0
    private(set) var streamTranslationCallCount = 0

    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool {
        _ = source
        _ = target
        return true
    }

    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute {
        TranslationRoute(
            source: source,
            target: target,
            steps: source == target ? [] : [TranslationRouteStep(source: source, target: target)]
        )
    }

    func translate(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        _ = text
        _ = source
        _ = target
        translateCallCount += 1
        return ""
    }

    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        _ = text
        _ = source
        _ = target
        streamTranslationCallCount += 1

        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct HomeViewModelSpeechRecognitionStub: SpeechRecognitionService {
    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        _ = samples
        return SpeechRecognitionResult(text: "", detectedLanguage: nil)
    }
}

@MainActor
private final class HomeViewModelTextToSpeechStub: TextToSpeechService {
    func speak(text: String, language: SupportedLanguage, messageID: UUID) async throws {
        _ = text
        _ = language
        _ = messageID
    }

    func stop() {}

    func playbackEvents() -> AsyncStream<TextToSpeechPlaybackEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
