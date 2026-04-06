//
//  HomeStoreRetrySpeechTranslationTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeStoreRetrySpeechTranslationTests: XCTestCase {
    func testRetrySpeechTranslationButtonShownOnlyForSpeechModelNotInstalledMessages() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let modelContext = try makeModelContext()
        let session = ChatSession(sourceLanguage: .english, targetLanguage: .chinese)
        let retryMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: TranslationError.modelNotInstalled(
                source: .english,
                target: .chinese
            ).userFacingMessage,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            sequence: 0,
            session: session
        )
        let textMessage = ChatMessage(
            inputType: .text,
            sourceText: "Hello there",
            translatedText: TranslationError.modelNotInstalled(
                source: .english,
                target: .chinese
            ).userFacingMessage,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            sequence: 1,
            session: session
        )
        let genericFailureMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "翻译失败了，请稍后再试。",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            sequence: 2,
            session: session
        )
        let successfulSpeechMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            sequence: 3,
            session: session
        )

        modelContext.insert(session)
        modelContext.insert(retryMessage)
        modelContext.insert(textMessage)
        modelContext.insert(genericFailureMessage)
        modelContext.insert(successfulSpeechMessage)
        try modelContext.save()

        let store = HomeStore(dependencies: environment.dependencies)
        store.sessionPresentation = .persisted(session.id)

        let itemStates = Dictionary(
            uniqueKeysWithValues: store.makeViewState(
                in: runtimeContext(modelContext: modelContext)
            ).messageItems.map { ($0.message.id, $0) }
        )

        XCTAssertEqual(itemStates[retryMessage.id]?.showsRetrySpeechTranslationButton, true)
        XCTAssertEqual(itemStates[retryMessage.id]?.isRetrySpeechTranslationDisabled, false)
        XCTAssertEqual(itemStates[textMessage.id]?.showsRetrySpeechTranslationButton, false)
        XCTAssertEqual(itemStates[genericFailureMessage.id]?.showsRetrySpeechTranslationButton, false)
        XCTAssertEqual(itemStates[successfulSpeechMessage.id]?.showsRetrySpeechTranslationButton, false)
    }

    func testRetrySpeechTranslationButtonDisablesForMutationAndStreamingStates() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let modelContext = try makeModelContext()
        let session = ChatSession(sourceLanguage: .english, targetLanguage: .chinese)
        let message = ChatMessage(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: TranslationError.modelNotInstalled(
                source: .english,
                target: .chinese
            ).userFacingMessage,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            sequence: 0,
            session: session
        )

        modelContext.insert(session)
        modelContext.insert(message)
        try modelContext.save()

        let store = HomeStore(dependencies: environment.dependencies)
        store.sessionPresentation = .persisted(session.id)

        var itemState = try XCTUnwrap(
            store.makeViewState(in: runtimeContext(modelContext: modelContext)).messageItems.first
        )
        XCTAssertTrue(itemState.showsRetrySpeechTranslationButton)
        XCTAssertFalse(itemState.isRetrySpeechTranslationDisabled)

        store.messageLanguageSwitchSideByMessageID[message.id] = .target
        itemState = try XCTUnwrap(
            store.makeViewState(in: runtimeContext(modelContext: modelContext)).messageItems.first
        )
        XCTAssertTrue(itemState.showsRetrySpeechTranslationButton)
        XCTAssertTrue(itemState.isRetrySpeechTranslationDisabled)

        store.messageLanguageSwitchSideByMessageID.removeValue(forKey: message.id)
        store.streamingStatesByMessageID[message.id] = makeStreamingState(messageID: message.id)
        itemState = try XCTUnwrap(
            store.makeViewState(in: runtimeContext(modelContext: modelContext)).messageItems.first
        )
        XCTAssertFalse(itemState.showsRetrySpeechTranslationButton)
        XCTAssertTrue(itemState.isRetrySpeechTranslationDisabled)
    }

    private func makeEnvironment() throws -> RetryStoreTestEnvironment {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let translationRootURL = rootURL.appendingPathComponent("translation", isDirectory: true)
        let speechRootURL = rootURL.appendingPathComponent("speech", isDirectory: true)
        try FileManager.default.createDirectory(at: translationRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: speechRootURL, withIntermediateDirectories: true)

        try FileManager.default.copyItem(
            at: resourceDirectoryURL.appendingPathComponent("translation-catalog.json", isDirectory: false),
            to: translationRootURL.appendingPathComponent("catalog.json", isDirectory: false)
        )
        try FileManager.default.copyItem(
            at: resourceDirectoryURL.appendingPathComponent("speech-catalog.json", isDirectory: false),
            to: speechRootURL.appendingPathComponent("catalog.json", isDirectory: false)
        )

        let translationCatalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            baseDirectoryURLOverride: translationRootURL
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: translationCatalogRepository,
            baseDirectoryURLOverride: translationRootURL
        )
        let speechCatalogRepository = SpeechModelCatalogRepository(
            remoteCatalogURL: nil,
            baseDirectoryURLOverride: speechRootURL
        )
        let speechPackageManager = SpeechModelPackageManager(
            catalogRepository: speechCatalogRepository,
            baseDirectoryURLOverride: speechRootURL
        )

        let suiteName = "HomeStoreRetrySpeechTranslationTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        let dependencies = HomeDependencies(
            appSettings: AppSettings(userDefaults: userDefaults),
            textLanguageRecognitionService: RetryStoreTextLanguageRecognitionService(),
            translationService: RetryStoreTranslationService(),
            speechRecognitionService: RetryStoreSpeechRecognitionService(),
            textToSpeechService: RetryStoreTextToSpeechService(),
            audioFilePlaybackService: RetryStoreAudioFilePlaybackService(),
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: RetryStoreTranslationAssetReadinessProvider(requirement: .ready),
            translationModelInventoryProvider: RetryStoreTranslationModelInventoryProvider(),
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )

        return RetryStoreTestEnvironment(
            dependencies: dependencies,
            cleanup: {
                try? FileManager.default.removeItem(at: rootURL)
                userDefaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    private var resourceDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../link/Resource", isDirectory: true)
            .standardizedFileURL
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

    private func runtimeContext(modelContext: ModelContext) -> HomeRuntimeContext {
        HomeRuntimeContext(
            modelContext: modelContext,
            sessions: (try? modelContext.fetch(FetchDescriptor<ChatSession>())) ?? []
        )
    }

    private func makeStreamingState(messageID: UUID) -> ExchangeStreamingState {
        ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: "Hello there",
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: "你",
            translationPhase: .translating,
            translationRevision: 1
        )
    }
}

private struct RetryStoreTestEnvironment {
    let dependencies: HomeDependencies
    let cleanup: () -> Void
}

private final class RetryStoreTranslationService: TranslationService, @unchecked Sendable {
    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool {
        true
    }

    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute {
        TranslationRoute(
            source: source,
            target: target,
            steps: source == target ? [] : [TranslationRouteStep(source: source, target: target)]
        )
    }

    func translate(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> String {
        text
    }

    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.completed(text: text))
            continuation.finish()
        }
    }
}

private final class RetryStoreTranslationAssetReadinessProvider: TranslationAssetReadinessProviding, @unchecked Sendable {
    let requirement: TranslationAssetRequirement

    init(requirement: TranslationAssetRequirement) {
        self.requirement = requirement
    }

    func translationAssetRequirement(
        for route: TranslationRoute
    ) async throws -> TranslationAssetRequirement {
        guard !route.steps.isEmpty else {
            return .ready
        }

        return requirement
    }

    func areTranslationAssetsReady(
        for route: TranslationRoute
    ) async throws -> Bool {
        let requirement = try await translationAssetRequirement(for: route)
        return requirement.isReady
    }
}

private final class RetryStoreTranslationModelInventoryProvider: TranslationModelInventoryProviding, @unchecked Sendable {
    func packages() async throws -> [TranslationModelPackage] {
        []
    }

    func installedPackages() async throws -> [TranslationInstalledPackageSummary] {
        []
    }
}

private struct RetryStoreTextLanguageRecognitionService: TextLanguageRecognitionService {
    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult {
        _ = text
        return TextLanguageRecognitionResult(
            language: .english,
            confidence: 1,
            hypotheses: [.english: 1]
        )
    }
}

private struct RetryStoreSpeechRecognitionService: SpeechRecognitionService {
    func transcribe(
        samples: [Float],
        preferredLanguage: SupportedLanguage?
    ) async throws -> SpeechRecognitionResult {
        _ = samples
        _ = preferredLanguage
        return SpeechRecognitionResult(text: "", detectedLanguage: nil)
    }
}

@MainActor
private final class RetryStoreTextToSpeechService: TextToSpeechService {
    var playbackEventHandler: ((TextToSpeechPlaybackEvent) -> Void)?

    func speak(text: String, language: SupportedLanguage, playbackID: UUID) async throws {
        _ = text
        _ = language
        _ = playbackID
    }

    func stop() {}
}

@MainActor
private final class RetryStoreAudioFilePlaybackService: AudioFilePlaybackService {
    var playbackEventHandler: ((AudioFilePlaybackEvent) -> Void)?

    func play(url: URL, playbackID: UUID) async throws {
        _ = url
        _ = playbackID
    }

    func stop() {}
}
