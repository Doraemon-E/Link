//
//  HomeViewModelTextToSpeechTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/5.
//

import XCTest
@testable import link

@MainActor
final class HomeViewModelTextToSpeechTests: XCTestCase {
    func testAssistantMessageUsesStoredLanguageForPlayback() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let message = makeAssistantMessage(
            text: "こんにちは",
            language: .japanese,
            sessionTargetLanguage: .english
        )

        viewModel.toggleMessageSpeechPlayback(message: message)
        await settle()

        XCTAssertEqual(
            textToSpeechService.speakCalls,
            [
                .init(
                    text: "こんにちは",
                    language: .japanese,
                    messageID: message.id
                )
            ]
        )
    }

    func testAssistantMessageFallsBackToSessionTargetLanguageWhenStoredLanguageIsMissing() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let message = makeAssistantMessage(
            text: "Bonjour",
            language: nil,
            sessionTargetLanguage: .french
        )

        viewModel.toggleMessageSpeechPlayback(message: message)
        await settle()

        XCTAssertEqual(textToSpeechService.speakCalls.first?.language, .french)
    }

    func testTogglingSameMessageStopsPlayback() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let message = makeAssistantMessage(
            text: "Hello",
            language: .english,
            sessionTargetLanguage: .english
        )

        viewModel.toggleMessageSpeechPlayback(message: message)
        await settle()
        viewModel.toggleMessageSpeechPlayback(message: message)

        XCTAssertEqual(textToSpeechService.stopCallCount, 1)
        XCTAssertNil(viewModel.speakingMessageID)
    }

    func testStartingAnotherMessageStopsCurrentPlaybackAndSwitchesTarget() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let firstMessage = makeAssistantMessage(
            text: "Hello",
            language: .english,
            sessionTargetLanguage: .english
        )
        let secondMessage = makeAssistantMessage(
            text: "你好",
            language: .chinese,
            sessionTargetLanguage: .chinese
        )

        viewModel.toggleMessageSpeechPlayback(message: firstMessage)
        await settle()
        viewModel.toggleMessageSpeechPlayback(message: secondMessage)
        await settle()

        XCTAssertEqual(textToSpeechService.stopCallCount, 1)
        XCTAssertEqual(
            textToSpeechService.speakCalls.map(\.messageID),
            [firstMessage.id, secondMessage.id]
        )
        XCTAssertEqual(viewModel.speakingMessageID, secondMessage.id)
    }

    func testPrepareForSpeechRecordingStopsTextToSpeechPlayback() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let message = makeAssistantMessage(
            text: "Hola",
            language: .spanish,
            sessionTargetLanguage: .spanish
        )

        viewModel.toggleMessageSpeechPlayback(message: message)
        await settle()
        viewModel.prepareForSpeechRecording()

        XCTAssertEqual(textToSpeechService.stopCallCount, 1)
        XCTAssertNil(viewModel.speakingMessageID)
    }

    func testFailedPlaybackEventClearsStateAndShowsError() async throws {
        let textToSpeechService = StubTextToSpeechService()
        let viewModel = makeViewModel(textToSpeechService: textToSpeechService)
        let message = makeAssistantMessage(
            text: "Ciao",
            language: .italian,
            sessionTargetLanguage: .italian
        )

        viewModel.toggleMessageSpeechPlayback(message: message)
        await settle()
        textToSpeechService.emit(.failed(messageID: message.id, message: "播放失败"))
        await settle()

        XCTAssertNil(viewModel.speakingMessageID)
        XCTAssertEqual(viewModel.ttsErrorMessage, "播放失败")
    }

    private func makeViewModel(
        textToSpeechService: StubTextToSpeechService
    ) -> HomeViewModel {
        let translationCatalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: translationCatalogRepository
        )
        let speechCatalogRepository = SpeechModelCatalogRepository(remoteCatalogURL: nil, bundle: .main)
        let speechPackageManager = SpeechModelPackageManager(
            catalogRepository: speechCatalogRepository
        )

        return HomeViewModel(
            appSettings: AppSettings(
                userDefaults: UserDefaults(suiteName: "HomeViewModelTextToSpeechTests.\(UUID().uuidString)") ?? .standard
            ),
            translationService: StubTranslationService(),
            speechRecognitionService: StubSpeechRecognitionService(),
            textToSpeechService: textToSpeechService,
            speechPackageManager: speechPackageManager,
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )
    }

    private func makeAssistantMessage(
        text: String,
        language: SupportedLanguage?,
        sessionTargetLanguage: SupportedLanguage
    ) -> ChatMessage {
        let session = ChatSession(
            sourceLanguage: .chinese,
            targetLanguage: sessionTargetLanguage
        )

        return ChatMessage(
            sender: .assistant,
            text: text,
            language: language,
            sequence: 1,
            session: session
        )
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }
}

@MainActor
private final class StubTextToSpeechService: TextToSpeechService {
    struct SpeakCall: Equatable {
        let text: String
        let language: SupportedLanguage
        let messageID: UUID
    }

    private(set) var speakCalls: [SpeakCall] = []
    private(set) var stopCallCount = 0
    private var continuation: AsyncStream<TextToSpeechPlaybackEvent>.Continuation?

    func speak(text: String, language: SupportedLanguage, messageID: UUID) async throws {
        speakCalls.append(
            SpeakCall(
                text: text,
                language: language,
                messageID: messageID
            )
        )
    }

    func stop() {
        stopCallCount += 1
    }

    func playbackEvents() -> AsyncStream<TextToSpeechPlaybackEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ event: TextToSpeechPlaybackEvent) {
        continuation?.yield(event)
    }
}

private final class StubTranslationService: TranslationService, @unchecked Sendable {
    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool {
        _ = source
        _ = target
        return true
    }

    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute {
        TranslationRoute(
            source: source,
            target: target,
            steps: [
                TranslationRouteStep(
                    source: source,
                    target: target
                )
            ]
        )
    }

    func translate(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        _ = source
        _ = target
        return text
    }

    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        _ = source
        _ = target

        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.completed(text: text))
            continuation.finish()
        }
    }
}

private struct StubSpeechRecognitionService: SpeechRecognitionService {
    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        _ = samples
        return SpeechRecognitionResult(text: "stub", detectedLanguage: nil)
    }
}
