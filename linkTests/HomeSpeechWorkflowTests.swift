//
//  HomeSpeechWorkflowTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeSpeechWorkflowTests: XCTestCase {
    func testConsecutiveSpeechRecordingsPersistDistinctFiles() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "First transcript",
            detectedLanguage: nil
        )
        try await performSpeechRecording(harness)

        let firstSession = try fetchSingleSession(in: harness.modelContext)
        let firstMessage = try XCTUnwrap(firstSession.sortedMessages.first)
        let firstAudioURL = try fileURL(from: firstMessage.audioURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudioURL.path))
        XCTAssertEqual(harness.messageWorkflow.calls.count, 1)

        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "Second transcript",
            detectedLanguage: nil
        )
        try await performSpeechRecording(harness)

        let session = try fetchSingleSession(in: harness.modelContext)
        let messages = session.sortedMessages
        XCTAssertEqual(messages.count, 2)

        let refreshedFirstMessage = messages[0]
        let secondMessage = messages[1]
        let secondAudioURL = try fileURL(from: secondMessage.audioURL)

        XCTAssertEqual(harness.recordingService.stopMessageIDs, [refreshedFirstMessage.id, secondMessage.id])
        XCTAssertNotEqual(refreshedFirstMessage.audioURL, secondMessage.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudioURL.path))
        XCTAssertEqual(firstAudioURL.lastPathComponent, "\(refreshedFirstMessage.id.uuidString).caf")
        XCTAssertEqual(secondAudioURL.lastPathComponent, "\(secondMessage.id.uuidString).caf")
        XCTAssertEqual(harness.messageWorkflow.calls.count, 2)
    }

    func testTranslationPromptKeepsPreservedRecordingAfterTranscriptFinalized() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "Prompt transcript",
            detectedLanguage: nil
        )
        harness.downloadSupport.translationPrompt = makeTranslationPrompt(
            source: .english,
            target: .japanese
        )
        harness.store.sourceLanguage = .english
        harness.store.selectedLanguage = .japanese

        try await performSpeechRecording(harness)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        let audioURL = try fileURL(from: message.audioURL)

        XCTAssertNotNil(harness.downloadSupport.presentedTranslationPrompt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(
            message.translatedText,
            TranslationError.modelNotInstalled(source: .english, target: .japanese).userFacingMessage
        )
        XCTAssertTrue(harness.messageWorkflow.calls.isEmpty)
    }

    func testTranslationPromptPersistsDetectedSourceLanguageForRetry() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "Prompt transcript",
            detectedLanguage: "ja"
        )
        harness.downloadSupport.translationPrompt = makeTranslationPrompt(
            source: .japanese,
            target: .chinese
        )
        harness.store.sourceLanguage = .english
        harness.store.selectedLanguage = .chinese

        try await performSpeechRecording(harness)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        let audioURL = try fileURL(from: message.audioURL)

        XCTAssertEqual(message.sourceLanguage, .japanese)
        XCTAssertEqual(
            message.translatedText,
            TranslationError.modelNotInstalled(source: .japanese, target: .chinese).userFacingMessage
        )
        XCTAssertNotNil(harness.downloadSupport.presentedTranslationPrompt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(harness.messageWorkflow.calls.isEmpty)
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)
    }

    func testSpeechRecognitionFailureRemovesPreservedRecordingAndDiscardsLiveMessage() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.speechRecognitionService.error = SpeechRecognitionError.emptyTranscription

        try await performSpeechRecording(harness)

        XCTAssertEqual(try fetchSessions(in: harness.modelContext).count, 0)
        XCTAssertEqual(harness.recordingService.stopMessageIDs.count, 1)
        XCTAssertEqual(harness.recordingService.cancelCount, 1)
        XCTAssertTrue(harness.messageWorkflow.calls.isEmpty)
        XCTAssertEqual(harness.store.speechErrorMessage, SpeechRecognitionError.emptyTranscription.userFacingMessage)
        XCTAssertNil(harness.store.lastSpeechRecordingURL)

        let preservedURL = try XCTUnwrap(harness.recordingService.lastPreservedRecordingURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preservedURL.path))
    }

    func testRecordingSpeechDoesNotRewriteLegacyAudioURLs() async throws {
        let legacyAudioURL = URL(fileURLWithPath: "/tmp/last-speech-recording.caf").absoluteString
        let harness = try makeHarness(
            seedMessages: [
                SeedMessage(
                    inputType: .speech,
                    sourceText: "Legacy transcript",
                    translatedText: "旧翻译",
                    sourceLanguage: .english,
                    targetLanguage: .chinese,
                    audioURL: legacyAudioURL
                )
            ]
        )
        defer { harness.cleanup() }

        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "Fresh transcript",
            detectedLanguage: nil
        )
        harness.store.sourceLanguage = .english
        harness.store.selectedLanguage = .chinese

        try await performSpeechRecording(harness)

        let session = try fetchSingleSession(in: harness.modelContext)
        let messages = session.sortedMessages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].audioURL, legacyAudioURL)
        XCTAssertNotEqual(messages[1].audioURL, legacyAudioURL)
    }

    func testImmersivePreviewAccumulatesCommittedSegmentsAndActiveTail() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好。",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1
                )
            ),
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好。再见",
                    detectedLanguage: .english,
                    transcriptRevision: 2
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hel"], completed: "Hello."),
            .init(partials: ["Good"], completed: "Goodbye")
        ]

        await harness.workflow.startImmersiveVoiceTranslation(in: try runtime(for: harness.modelContext))
        await advanceTasks()

        let state = try XCTUnwrap(harness.store.immersiveVoiceTranslationState)
        XCTAssertEqual(state.committedSegments.map(\.text), ["Hello."])
        XCTAssertEqual(state.activeText, "Goodbye")
        XCTAssertEqual(harness.store.sourceLanguage, .chinese)
        XCTAssertEqual(
            harness.coordinator.speechTranslationCalls.map(\.text),
            ["你好。", "再见"]
        )
        XCTAssertEqual(
            harness.coordinator.speechTranslationCalls.map(\.sourceLanguage),
            [.chinese, .chinese]
        )
    }

    func testImmersiveFinalizationReplacesDisplayedSegmentsWithCorrectedTranslations() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好。再见",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hi"], completed: "Hello."),
            .init(partials: ["Bye"], completed: "Goodbye"),
            .init(partials: ["Hello"], completed: "Hello there."),
            .init(partials: ["See"], completed: "See you!")
        ]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "你好。再见！",
            detectedLanguage: "zh"
        )

        await harness.workflow.startImmersiveVoiceTranslation(in: try runtime(for: harness.modelContext))
        await advanceTasks()
        await harness.workflow.toggleSpeechRecording(in: try runtime(for: harness.modelContext))
        await advanceTasks()

        XCTAssertNil(harness.store.immersiveVoiceTranslationState)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        XCTAssertEqual(message.translatedText, "Hello there. See you!")
    }

    func testImmersiveFinalizationContinuesStreamingOnConversationListAfterExit() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好。再见",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hi"], completed: "Hello."),
            .init(partials: ["Bye"], completed: "Goodbye"),
            .init(partials: ["Hello"], completed: "Hello there."),
            .init(
                partials: ["See"],
                completed: "See you!",
                completionDelayYields: 160
            )
        ]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "你好。再见！",
            detectedLanguage: "zh"
        )

        let startRuntime = try runtime(for: harness.modelContext)
        await harness.workflow.startImmersiveVoiceTranslation(in: startRuntime)
        await advanceTasks()

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        let stopRuntime = try runtime(for: harness.modelContext)
        let stopTask = Task { @MainActor in
            await harness.workflow.toggleSpeechRecording(in: stopRuntime)
        }

        await advanceTasks(iterations: 40)

        XCTAssertNil(harness.store.immersiveVoiceTranslationState)
        let streamingState = try XCTUnwrap(harness.store.streamingStatesByMessageID[message.id])
        XCTAssertEqual(streamingState.sourceStableText, "你好。再见！")
        XCTAssertEqual(streamingState.translatedCommittedText, "Hello there.")
        XCTAssertEqual(streamingState.translatedLiveText, "Hello there. See")
        XCTAssertEqual(streamingState.translationPhase, .typing)
        XCTAssertGreaterThan(streamingState.translationRevision, 0)

        await advanceTasks(iterations: 220)
        await stopTask.value

        let finalizedSession = try fetchSingleSession(in: harness.modelContext)
        let finalizedMessage = try XCTUnwrap(finalizedSession.sortedMessages.first)
        XCTAssertEqual(finalizedMessage.translatedText, "Hello there. See you!")
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)
    }

    func testImmersivePreviewKeepsChineseEndpointSegmentsSeparateAcrossLaterStableUpdates() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .completed(
                LiveUtteranceState(
                    stableTranscript: "你好呀你好呀",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1,
                    isEndpoint: true
                )
            ),
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好呀你好呀你覺得今天怎麼樣啊?",
                    detectedLanguage: .chinese,
                    transcriptRevision: 2
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hel"], completed: "Hello Hello"),
            .init(partials: ["How"], completed: "How do you feel about today?")
        ]

        await harness.workflow.startImmersiveVoiceTranslation(in: try runtime(for: harness.modelContext))
        await advanceTasks()

        let state = try XCTUnwrap(harness.store.immersiveVoiceTranslationState)
        XCTAssertEqual(
            state.committedSegments.map(\.text),
            ["Hello Hello", "How do you feel about today?"]
        )
        XCTAssertEqual(state.activeText, "")
        XCTAssertEqual(
            harness.coordinator.speechTranslationCalls.map(\.text),
            ["你好呀你好呀", "你覺得今天怎麼樣啊?"]
        )
    }

    func testImmersiveFinalizationPreservesCommittedChineseUtteranceBoundaries() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .completed(
                LiveUtteranceState(
                    stableTranscript: "你好呀你好呀",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1,
                    isEndpoint: true
                )
            ),
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好呀你好呀你覺得今天怎麼樣啊?",
                    detectedLanguage: .chinese,
                    transcriptRevision: 2
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hel"], completed: "Hello Hello"),
            .init(partials: ["How"], completed: "How do you feel about today?"),
            .init(partials: ["Hello"], completed: "Hello Hello"),
            .init(partials: ["How"], completed: "How do you feel about today?")
        ]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "你好呀你好呀你覺得今天怎麼樣啊?",
            detectedLanguage: "zh"
        )

        await harness.workflow.startImmersiveVoiceTranslation(in: try runtime(for: harness.modelContext))
        await advanceTasks()
        await harness.workflow.toggleSpeechRecording(in: try runtime(for: harness.modelContext))
        await advanceTasks()

        XCTAssertNil(harness.store.immersiveVoiceTranslationState)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        XCTAssertEqual(message.translatedText, "Hello Hello How do you feel about today?")
    }

    func testImmersiveFinalizationFailureClearsConversationStreamingState() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.selectedLanguage = .english
        harness.coordinator.liveTranscriptionEvents = [
            .state(
                LiveUtteranceState(
                    stableTranscript: "你好",
                    detectedLanguage: .chinese,
                    transcriptRevision: 1
                )
            )
        ]
        harness.coordinator.speechTranslationResponses = [
            .init(partials: ["Hel"], completed: "Hello"),
            .init(
                partials: [],
                completed: "",
                error: TranslationError.inferenceFailed("boom")
            )
        ]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "你好",
            detectedLanguage: "zh"
        )

        await harness.workflow.startImmersiveVoiceTranslation(in: try runtime(for: harness.modelContext))
        await advanceTasks()
        await harness.workflow.toggleSpeechRecording(in: try runtime(for: harness.modelContext))
        await advanceTasks()

        XCTAssertNil(harness.store.immersiveVoiceTranslationState)
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        XCTAssertEqual(
            message.translatedText,
            TranslationError.inferenceFailed("boom").userFacingMessage
        )
    }

    func testSpeechLocksSourceLanguageFromFirstDetectedUtterance() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        harness.store.sourceLanguage = .english
        harness.store.selectedLanguage = .chinese
        harness.coordinator.liveTranscriptionEvents = [
            .state(
                LiveUtteranceState(
                    stableTranscript: "bonjour",
                    detectedLanguage: .french,
                    transcriptRevision: 1
                )
            )
        ]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "bonjour",
            detectedLanguage: "en"
        )

        try await performSpeechRecording(harness)

        let session = try fetchSingleSession(in: harness.modelContext)
        let message = try XCTUnwrap(session.sortedMessages.first)
        XCTAssertEqual(harness.store.sourceLanguage, .french)
        XCTAssertEqual(session.sourceLanguage, .french)
        XCTAssertEqual(message.sourceLanguage, .french)
        XCTAssertEqual(harness.messageWorkflow.calls.first?.sourceLanguage, .french)
    }

    private func makeHarness(
        seedMessages: [SeedMessage] = []
    ) throws -> WorkflowHarness {
        let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            configurations: modelConfiguration
        )
        let modelContext = ModelContext(container)
        let fileRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: fileRootURL,
            withIntermediateDirectories: true
        )

        let store = FakeSpeechWorkflowStore(
            sourceLanguage: seedMessages.first?.sourceLanguage ?? .english,
            selectedLanguage: seedMessages.first?.targetLanguage ?? .chinese
        )

        if !seedMessages.isEmpty {
            let session = ChatSession(
                sourceLanguage: store.sourceLanguage,
                targetLanguage: store.selectedLanguage
            )
            modelContext.insert(session)

            for (index, seedMessage) in seedMessages.enumerated() {
                let message = ChatMessage(
                    inputType: seedMessage.inputType,
                    sourceText: seedMessage.sourceText,
                    translatedText: seedMessage.translatedText,
                    sourceLanguage: seedMessage.sourceLanguage,
                    targetLanguage: seedMessage.targetLanguage,
                    audioURL: seedMessage.audioURL,
                    sequence: index,
                    session: session
                )
                modelContext.insert(message)
            }

            try modelContext.save()
            store.sessionPresentation = .persisted(session.id)
        }

        let coordinator = FakeConversationStreamingCoordinator()
        let messageWorkflow = FakeSpeechTranslationStarter()
        let speechRecognitionService = FakeSpeechRecognitionService()
        let recordingService = FakeSpeechRecordingService(applicationSupportURL: fileRootURL)
        let downloadSupport = FakeSpeechDownloadSupport()
        let playbackController = FakePlaybackController()
        let workflow = HomeSpeechWorkflow(
            store: store,
            sessionRepository: HomeSessionRepository(),
            conversationStreamingCoordinator: coordinator,
            messageWorkflow: messageWorkflow,
            speechRecognitionService: speechRecognitionService,
            microphoneRecordingService: recordingService,
            downloadWorkflow: downloadSupport,
            playbackController: playbackController
        )

        return WorkflowHarness(
            workflow: workflow,
            store: store,
            modelContext: modelContext,
            coordinator: coordinator,
            messageWorkflow: messageWorkflow,
            speechRecognitionService: speechRecognitionService,
            recordingService: recordingService,
            downloadSupport: downloadSupport,
            playbackController: playbackController,
            cleanup: {
                try? FileManager.default.removeItem(at: fileRootURL)
            }
        )
    }

    private func performSpeechRecording(_ harness: WorkflowHarness) async throws {
        await harness.workflow.toggleSpeechRecording(in: try runtime(for: harness.modelContext))
        XCTAssertTrue(harness.store.isRecordingSpeech)

        await harness.workflow.toggleSpeechRecording(in: try runtime(for: harness.modelContext))
        XCTAssertFalse(harness.store.isRecordingSpeech)
        XCTAssertFalse(harness.store.isTranscribingSpeech)
    }

    private func advanceTasks(iterations: Int = 24) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    private func runtime(for modelContext: ModelContext) throws -> HomeRuntimeContext {
        HomeRuntimeContext(
            modelContext: modelContext,
            sessions: try fetchSessions(in: modelContext)
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

    private func fetchSingleSession(in modelContext: ModelContext) throws -> ChatSession {
        let sessions = try fetchSessions(in: modelContext)
        XCTAssertEqual(sessions.count, 1)
        return try XCTUnwrap(sessions.first)
    }

    private func fileURL(from audioURL: String?) throws -> URL {
        let audioURL = try XCTUnwrap(audioURL)
        return try XCTUnwrap(URL(string: audioURL))
    }

    private func makeTranslationPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> HomeLanguageDownloadPrompt {
        let package = TranslationModelPackage(
            packageId: "test-\(source.rawValue)-\(target.rawValue)",
            version: "1.0.0",
            source: source.translationModelCode,
            target: target.translationModelCode,
            family: .marian,
            archiveURL: URL(string: "https://example.com/model.zip")!,
            sha256: "hash",
            archiveSize: 1_024,
            installedSize: 2_048,
            manifestRelativePath: "manifest.json",
            minAppVersion: "1.0.0"
        )
        return HomeLanguageDownloadPrompt(
            sourceLanguage: source,
            targetLanguage: target,
            requirement: TranslationAssetRequirement(missingPackages: [package])
        )
    }
}

private struct SeedMessage {
    let inputType: ChatMessageInputType
    let sourceText: String
    let translatedText: String
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let audioURL: String?
}

@MainActor
private struct WorkflowHarness {
    let workflow: HomeSpeechWorkflow
    let store: FakeSpeechWorkflowStore
    let modelContext: ModelContext
    let coordinator: FakeConversationStreamingCoordinator
    let messageWorkflow: FakeSpeechTranslationStarter
    let speechRecognitionService: FakeSpeechRecognitionService
    let recordingService: FakeSpeechRecordingService
    let downloadSupport: FakeSpeechDownloadSupport
    let playbackController: FakePlaybackController
    let cleanup: () -> Void
}

@MainActor
private final class FakeSpeechWorkflowStore: HomeSpeechWorkflowStore {
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt?
    var immersiveVoiceTranslationState: HomeImmersiveVoiceTranslationState? {
        didSet {
            immersiveStateHistory.append(immersiveVoiceTranslationState)
        }
    }
    var immersiveStateHistory: [HomeImmersiveVoiceTranslationState?] = []
    var isChatInputFocused = false
    var isInstallingSpeechModel = false
    var isRecordingSpeech = false
    var isTranscribingSpeech = false
    var lastSpeechRecordingURL: URL?
    var pendingSpeechCaptureOrigin: HomeSpeechCaptureOrigin = .compactMic
    var pendingVoiceStartAfterInstall = false
    var playbackErrorMessage: String?
    var selectedLanguage: SupportedLanguage
    var sessionPresentation: HomeSessionPresentation = .none
    var sourceLanguage: SupportedLanguage
    var speechErrorMessage: String?
    var speechResumeRequestToken = 0
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] = [:]

    init(
        sourceLanguage: SupportedLanguage,
        selectedLanguage: SupportedLanguage
    ) {
        self.sourceLanguage = sourceLanguage
        self.selectedLanguage = selectedLanguage
    }
}

private final class FakeConversationStreamingCoordinator: ConversationStreamingCoordinator, @unchecked Sendable {
    struct SpeechTranslationCall: Equatable {
        let messageID: UUID
        let text: String
        let sourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
    }

    struct TranslationResponse {
        let partials: [String]
        let completed: String

        var completionDelayYields: Int = 0
        var error: Error?
    }

    var cancelledMessageIDs: [UUID] = []
    var liveTranscriptionEvents: [LiveSpeechTranscriptionEvent] = []
    var speechTranslationCalls: [SpeechTranslationCall] = []
    var speechTranslationResponses: [TranslationResponse] = []

    func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        speechTranslationCalls.append(
            SpeechTranslationCall(
                messageID: messageID,
                text: text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
        let response = speechTranslationResponses.isEmpty
            ? TranslationResponse(partials: [], completed: text)
            : speechTranslationResponses.removeFirst()

        return AsyncThrowingStream { continuation in
            Task {
                for (index, partial) in response.partials.enumerated() {
                    continuation.yield(
                        ConversationStreamingEvent.state(
                            TranslationStreamingState(
                                messageID: messageID,
                                committedText: "",
                                liveText: partial,
                                phase: .typing,
                                revision: index + 1
                            )
                        )
                    )
                    await Task.yield()
                }

                for _ in 0..<response.completionDelayYields {
                    await Task.yield()
                }

                if let error = response.error {
                    continuation.finish(throwing: error)
                    return
                }

                continuation.yield(
                    .completed(
                        messageID: messageID,
                        text: response.completed
                    )
                )
                continuation.finish()
            }
        }
    }

    func startLiveSpeechTranscription(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?
    ) -> AsyncThrowingStream<LiveSpeechTranscriptionEvent, Error> {
        let events = liveTranscriptionEvents
        return AsyncThrowingStream { continuation in
            _ = messageID
            _ = audioStream
            _ = sourceLanguage

            Task {
                for event in events {
                    continuation.yield(event)
                    await Task.yield()
                }

                continuation.finish()
            }
        }
    }

    func cancel(messageID: UUID) async {
        cancelledMessageIDs.append(messageID)
    }
}

@MainActor
private final class FakeSpeechTranslationStarter: HomeSpeechTranslationStarting {
    struct Call: Equatable {
        let messageID: UUID
        let transcript: String
        let sourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
    }

    var calls: [Call] = []

    func startSpeechTranslation(
        for messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) {
        _ = runtime
        calls.append(
            Call(
                messageID: messageID,
                transcript: transcript,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
    }
}

private final class FakeSpeechRecognitionService: SpeechRecognitionService, @unchecked Sendable {
    struct Call: Equatable {
        let samples: [Float]
        let preferredLanguage: SupportedLanguage?
    }

    var calls: [Call] = []
    var result = SpeechRecognitionResult(text: "Transcript", detectedLanguage: nil)
    var error: Error?

    func transcribe(
        samples: [Float],
        preferredLanguage: SupportedLanguage?
    ) async throws -> SpeechRecognitionResult {
        calls.append(
            Call(
                samples: samples,
                preferredLanguage: preferredLanguage
            )
        )
        if let error {
            throw error
        }

        return result
    }
}

@MainActor
private final class FakeSpeechRecordingService: SpeechRecordingService {
    let applicationSupportURL: URL
    var stopMessageIDs: [UUID] = []
    var cancelCount = 0
    var lastPreservedRecordingURL: URL?
    var samples: [Float] = [0.1, 0.2, 0.3]
    var stopError: Error?

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
    }

    func startStreamingRecording() async throws -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopRecording(for messageID: UUID) async throws -> MicrophoneRecordingResult {
        stopMessageIDs.append(messageID)

        if let stopError {
            throw stopError
        }

        try SpeechRecordingStoragePaths.ensureRecordingsDirectoryExists(
            applicationSupportURL: applicationSupportURL
        )
        let url = try SpeechRecordingStoragePaths.recordingFileURL(
            for: messageID,
            fileManager: .default,
            applicationSupportURL: applicationSupportURL
        )
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("recording-\(messageID.uuidString)".utf8)
        )
        lastPreservedRecordingURL = url

        return MicrophoneRecordingResult(
            samples: samples,
            preservedRecordingURL: url
        )
    }

    func cancelRecording() {
        cancelCount += 1
    }
}

@MainActor
private final class FakeSpeechDownloadSupport: HomeSpeechDownloadSupporting {
    var translationPrompt: HomeLanguageDownloadPrompt?
    var speechPrompt: SpeechModelDownloadPrompt?
    var presentedTranslationPrompt: HomeLanguageDownloadPrompt?

    func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt? {
        _ = source
        _ = target
        return translationPrompt
    }

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt) {
        presentedTranslationPrompt = prompt
    }

    func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt? {
        speechPrompt
    }
}

@MainActor
private final class FakePlaybackController: HomePlaybackControlling {
    var stopCount = 0

    func stop() {
        stopCount += 1
    }
}
