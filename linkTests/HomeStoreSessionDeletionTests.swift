//
//  HomeStoreSessionDeletionTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeStoreSessionDeletionTests: XCTestCase {
    func testDeleteCurrentSessionTransitionsToDraftAndCleansRelatedState() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let modelContext = try makeModelContext()
        let currentAudioURL = try makeTemporaryAudioFile()
        let otherAudioURL = try makeTemporaryAudioFile()
        defer {
            try? FileManager.default.removeItem(at: currentAudioURL)
            try? FileManager.default.removeItem(at: otherAudioURL)
        }

        let currentSession = ChatSession(sourceLanguage: .english, targetLanguage: .chinese)
        let currentMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Current",
            translatedText: "当前",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: currentAudioURL.absoluteString,
            sequence: 0,
            session: currentSession
        )
        let otherSession = ChatSession(sourceLanguage: .japanese, targetLanguage: .english)
        let otherMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Other",
            translatedText: "其他",
            sourceLanguage: .japanese,
            targetLanguage: .english,
            audioURL: otherAudioURL.absoluteString,
            sequence: 0,
            session: otherSession
        )

        modelContext.insert(currentSession)
        modelContext.insert(currentMessage)
        modelContext.insert(otherSession)
        modelContext.insert(otherMessage)
        try modelContext.save()

        let store = HomeStore(dependencies: environment.dependencies)
        store.sessionPresentation = .persisted(currentSession.id)
        store.isChatInputFocused = true
        store.expandedSpeechTranscriptMessageIDs = [currentMessage.id, otherMessage.id]
        store.streamingStatesByMessageID[otherMessage.id] = makeStreamingState(messageID: otherMessage.id)
        store.messageLanguageSwitchSideByMessageID[otherMessage.id] = .target
        store.lastSpeechRecordingURL = currentAudioURL
        store.activePlaybackState = HomePlaybackState(
            messageID: currentMessage.id,
            kind: .sourceRecording
        )

        store.deleteSession(
            id: currentSession.id,
            in: runtimeContext(modelContext: modelContext)
        )

        let remainingSessions = try fetchSessions(in: modelContext)
        XCTAssertEqual(remainingSessions.map(\.id), [otherSession.id])
        XCTAssertEqual(remainingSessions.first?.sortedMessages.map(\.id), [otherMessage.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherAudioURL.path))
        XCTAssertEqual(store.sessionPresentation, .draft)
        XCTAssertFalse(store.isChatInputFocused)
        XCTAssertEqual(store.expandedSpeechTranscriptMessageIDs, Set([otherMessage.id]))
        XCTAssertEqual(Set(store.streamingStatesByMessageID.keys), Set([otherMessage.id]))
        XCTAssertEqual(store.messageLanguageSwitchSideByMessageID[otherMessage.id], .target)
        XCTAssertNil(store.lastSpeechRecordingURL)
        XCTAssertNil(store.activePlaybackState)
        XCTAssertEqual(environment.textToSpeechService.stopCount, 1)
        XCTAssertEqual(environment.audioFilePlaybackService.stopCount, 1)
        XCTAssertEqual(store.sourceLanguage, .chinese)
        XCTAssertEqual(store.selectedLanguage, .english)
    }

    func testDeleteNonCurrentSessionKeepsCurrentSelection() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let modelContext = try makeModelContext()
        let currentAudioURL = try makeTemporaryAudioFile()
        let removableAudioURL = try makeTemporaryAudioFile()
        defer {
            try? FileManager.default.removeItem(at: currentAudioURL)
            try? FileManager.default.removeItem(at: removableAudioURL)
        }

        let currentSession = ChatSession(sourceLanguage: .english, targetLanguage: .french)
        let currentMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Current",
            translatedText: "Actuel",
            sourceLanguage: .english,
            targetLanguage: .french,
            audioURL: currentAudioURL.absoluteString,
            sequence: 0,
            session: currentSession
        )
        let removableSession = ChatSession(sourceLanguage: .japanese, targetLanguage: .english)
        let removableMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Delete me",
            translatedText: "Delete me",
            sourceLanguage: .japanese,
            targetLanguage: .english,
            audioURL: removableAudioURL.absoluteString,
            sequence: 0,
            session: removableSession
        )

        modelContext.insert(currentSession)
        modelContext.insert(currentMessage)
        modelContext.insert(removableSession)
        modelContext.insert(removableMessage)
        try modelContext.save()

        let store = HomeStore(dependencies: environment.dependencies)
        store.sessionPresentation = .persisted(currentSession.id)
        store.isChatInputFocused = true

        store.deleteSession(
            id: removableSession.id,
            in: runtimeContext(modelContext: modelContext)
        )

        let remainingSessions = try fetchSessions(in: modelContext)
        XCTAssertEqual(remainingSessions.map(\.id), [currentSession.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removableAudioURL.path))
        XCTAssertEqual(store.sessionPresentation, .persisted(currentSession.id))
        XCTAssertTrue(store.isChatInputFocused)
    }

    func testCannotDeleteSessionWithStreamingOrLanguageMutationState() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }

        let modelContext = try makeModelContext()
        let audioURL = try makeTemporaryAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let session = ChatSession(sourceLanguage: .english, targetLanguage: .chinese)
        let message = ChatMessage(
            inputType: .speech,
            sourceText: "Busy",
            translatedText: "忙碌",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: audioURL.absoluteString,
            sequence: 0,
            session: session
        )

        modelContext.insert(session)
        modelContext.insert(message)
        try modelContext.save()

        let store = HomeStore(dependencies: environment.dependencies)

        store.streamingStatesByMessageID[message.id] = makeStreamingState(messageID: message.id)
        XCTAssertFalse(store.canDeleteSession(session))
        store.deleteSession(
            id: session.id,
            in: runtimeContext(modelContext: modelContext)
        )
        XCTAssertEqual(try fetchSessions(in: modelContext).map(\.id), [session.id])

        store.streamingStatesByMessageID.removeValue(forKey: message.id)
        store.messageLanguageSwitchSideByMessageID[message.id] = .source
        XCTAssertFalse(store.canDeleteSession(session))
        store.deleteSession(
            id: session.id,
            in: runtimeContext(modelContext: modelContext)
        )
        XCTAssertEqual(try fetchSessions(in: modelContext).map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    private func makeEnvironment() throws -> StoreTestEnvironment {
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

        let suiteName = "HomeStoreSessionDeletionTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        let textToSpeechService = FakeStoreTextToSpeechService()
        let audioFilePlaybackService = FakeStoreAudioFilePlaybackService()
        let dependencies = HomeDependencies(
            appSettings: AppSettings(userDefaults: userDefaults),
            textLanguageRecognitionService: FakeStoreTextLanguageRecognitionService(),
            translationService: FakeStoreTranslationService(),
            speechRecognitionService: FakeStoreSpeechRecognitionService(),
            textToSpeechService: textToSpeechService,
            audioFilePlaybackService: audioFilePlaybackService,
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: FakeStoreTranslationAssetReadinessProvider(requirement: .ready),
            translationModelInventoryProvider: FakeStoreTranslationModelInventoryProvider(),
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )

        return StoreTestEnvironment(
            dependencies: dependencies,
            textToSpeechService: textToSpeechService,
            audioFilePlaybackService: audioFilePlaybackService,
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
            sessions: (try? fetchSessions(in: modelContext)) ?? []
        )
    }

    private func fetchSessions(in modelContext: ModelContext) throws -> [ChatSession] {
        try modelContext.fetch(FetchDescriptor<ChatSession>())
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }

                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")
        FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        return url
    }

    private func makeStreamingState(messageID: UUID) -> ExchangeStreamingState {
        ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: "source",
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "translated",
            translatedLiveText: nil,
            translationPhase: .translating,
            translationRevision: 1
        )
    }
}

private struct StoreTestEnvironment {
    let dependencies: HomeDependencies
    let textToSpeechService: FakeStoreTextToSpeechService
    let audioFilePlaybackService: FakeStoreAudioFilePlaybackService
    let cleanup: () -> Void
}

private final class FakeStoreTranslationService: TranslationService, @unchecked Sendable {
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

private final class FakeStoreTranslationAssetReadinessProvider: TranslationAssetReadinessProviding, @unchecked Sendable {
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

private final class FakeStoreTranslationModelInventoryProvider: TranslationModelInventoryProviding, @unchecked Sendable {
    func packages() async throws -> [TranslationModelPackage] {
        []
    }

    func installedPackages() async throws -> [TranslationInstalledPackageSummary] {
        []
    }
}

private struct FakeStoreTextLanguageRecognitionService: TextLanguageRecognitionService {
    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult {
        _ = text
        return TextLanguageRecognitionResult(
            language: .english,
            confidence: 1,
            hypotheses: [.english: 1]
        )
    }
}

private struct FakeStoreSpeechRecognitionService: SpeechRecognitionService {
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
private final class FakeStoreTextToSpeechService: TextToSpeechService {
    var playbackEventHandler: ((TextToSpeechPlaybackEvent) -> Void)?
    var stopCount = 0

    func speak(text: String, language: SupportedLanguage, playbackID: UUID) async throws {
        _ = text
        _ = language
        _ = playbackID
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeStoreAudioFilePlaybackService: AudioFilePlaybackService {
    var playbackEventHandler: ((AudioFilePlaybackEvent) -> Void)?
    var stopCount = 0

    func play(url: URL, playbackID: UUID) async throws {
        _ = url
        _ = playbackID
    }

    func stop() {
        stopCount += 1
    }
}
