//
//  HomeMessageLanguageWorkflowTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeMessageLanguageWorkflowTests: XCTestCase {
    func testLanguageSheetContextUsesExpectedTitles() {
        let global = HomeLanguageSheetContext(
            origin: .globalTarget,
            selectedLanguage: .english
        )
        let source = HomeLanguageSheetContext(
            origin: .message(messageID: UUID(), side: .source),
            selectedLanguage: .japanese
        )
        let target = HomeLanguageSheetContext(
            origin: .message(messageID: UUID(), side: .target),
            selectedLanguage: .french
        )

        XCTAssertEqual(global.title, "选择目标语言")
        XCTAssertEqual(source.title, "选择原文语言")
        XCTAssertEqual(target.title, "选择译文语言")
    }

    func testTextTargetSwitchUpdatesTranslationAndSessionDefaults() async throws {
        let harness = try makeHarness(
            inputType: .text,
            sourceText: "你好",
            translatedText: "Hello",
            sourceLanguage: .chinese,
            targetLanguage: .english
        )
        harness.coordinator.manualResult = "Bonjour"

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .target,
            to: .french,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.translatedText == "Bonjour"
        }

        XCTAssertEqual(harness.message.sourceText, "你好")
        XCTAssertEqual(harness.message.translatedText, "Bonjour")
        XCTAssertEqual(harness.message.targetLanguage, .french)
        XCTAssertEqual(harness.session.targetLanguage, .french)
        XCTAssertEqual(harness.store.selectedLanguage, .french)
        XCTAssertEqual(harness.store.sourceLanguage, .chinese)
        XCTAssertEqual(harness.coordinator.manualRequests.count, 1)
        XCTAssertEqual(harness.coordinator.manualRequests.first?.text, "你好")
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)
    }

    func testTextSourceSwitchReverseTranslatesSourceAndSyncsDefaults() async throws {
        let harness = try makeHarness(
            inputType: .text,
            sourceText: "你好",
            translatedText: "Hello",
            sourceLanguage: .chinese,
            targetLanguage: .english
        )
        harness.translationService.translateHandler = { text, source, target in
            XCTAssertEqual(text, "Hello")
            XCTAssertEqual(source, .english)
            XCTAssertEqual(target, .japanese)
            return "こんにちは"
        }

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .source,
            to: .japanese,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.sourceLanguage == .japanese
        }

        XCTAssertEqual(harness.message.sourceText, "こんにちは")
        XCTAssertEqual(harness.message.translatedText, "Hello")
        XCTAssertEqual(harness.message.sourceLanguage, .japanese)
        XCTAssertEqual(harness.session.sourceLanguage, .japanese)
        XCTAssertEqual(harness.store.sourceLanguage, .japanese)
        XCTAssertEqual(harness.store.selectedLanguage, .english)
        XCTAssertEqual(harness.translationService.translateCalls.count, 1)
        XCTAssertTrue(harness.coordinator.manualRequests.isEmpty)
    }

    func testSpeechTargetSwitchRetranslatesWithoutRetranscribing() async throws {
        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: try makeTempAudioFileURL()
        )
        harness.coordinator.speechResult = "Bonjour"

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .target,
            to: .french,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.targetLanguage == .french
        }

        XCTAssertEqual(harness.message.sourceText, "Hello there")
        XCTAssertEqual(harness.message.translatedText, "Bonjour")
        XCTAssertEqual(harness.message.targetLanguage, .french)
        XCTAssertEqual(harness.session.targetLanguage, .french)
        XCTAssertEqual(harness.store.selectedLanguage, .french)
        XCTAssertEqual(harness.speechRecognitionService.calls.count, 0)
        XCTAssertEqual(harness.coordinator.speechRequests.count, 1)
        XCTAssertEqual(harness.coordinator.speechRequests.first?.text, "Hello there")
    }

    func testSpeechSourceSwitchRetranscribesWithPreferredLanguage() async throws {
        let audioURL = try makeTempAudioFileURL()
        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: audioURL
        )
        harness.recordingLoader.samples = [0.1, 0.2, 0.3]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "こんにちは",
            detectedLanguage: "ja"
        )
        harness.coordinator.speechResult = "你好啊"

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .source,
            to: .japanese,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.sourceLanguage == .japanese
        }

        XCTAssertEqual(harness.message.sourceText, "こんにちは")
        XCTAssertEqual(harness.message.translatedText, "你好啊")
        XCTAssertEqual(harness.message.sourceLanguage, .japanese)
        XCTAssertEqual(harness.session.sourceLanguage, .japanese)
        XCTAssertEqual(harness.store.sourceLanguage, .japanese)
        XCTAssertEqual(harness.speechRecognitionService.calls.count, 1)
        XCTAssertEqual(harness.speechRecognitionService.calls.first?.preferredLanguage, .japanese)
        XCTAssertEqual(harness.recordingLoader.loadedURLs, [audioURL])
        XCTAssertEqual(harness.coordinator.speechRequests.first?.text, "こんにちは")
    }

    func testSpeechSourceSwitchRetranscribesManagedRelativeRecordingPath() async throws {
        let managedAudio = try makeManagedAudioRecording()
        defer {
            try? FileManager.default.removeItem(at: managedAudio.fileURL)
        }

        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioReference: managedAudio.reference
        )
        harness.recordingLoader.samples = [0.1, 0.2, 0.3]
        harness.speechRecognitionService.result = SpeechRecognitionResult(
            text: "こんにちは",
            detectedLanguage: "ja"
        )
        harness.coordinator.speechResult = "你好啊"

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .source,
            to: .japanese,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.sourceLanguage == .japanese
        }

        XCTAssertEqual(harness.recordingLoader.loadedURLs, [managedAudio.fileURL])
        XCTAssertEqual(harness.coordinator.speechRequests.first?.text, "こんにちは")
    }

    func testRetrySpeechTranslationRetranslatesUsingSavedTranscript() async throws {
        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: TranslationError.modelNotInstalled(
                source: .english,
                target: .chinese
            ).userFacingMessage,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: try makeTempAudioFileURL()
        )
        harness.coordinator.speechResult = "你好啊"

        harness.workflow.retrySpeechTranslation(
            forMessageID: harness.message.id,
            in: harness.runtime
        )

        try await waitUntil {
            harness.message.translatedText == "你好啊"
        }

        XCTAssertEqual(harness.coordinator.speechRequests.count, 1)
        XCTAssertEqual(harness.coordinator.speechRequests.first?.text, "Hello there")
        XCTAssertEqual(harness.coordinator.speechRequests.first?.sourceLanguage, .english)
        XCTAssertEqual(harness.coordinator.speechRequests.first?.targetLanguage, .chinese)
        XCTAssertTrue(harness.speechRecognitionService.calls.isEmpty)
        XCTAssertEqual(harness.message.targetLanguage, .chinese)
        XCTAssertEqual(harness.store.selectedLanguage, .chinese)
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)
    }

    func testRetrySpeechTranslationWithMissingModelPresentsPromptWithoutOverwritingMessage() async throws {
        let originalTranslatedText = TranslationError.modelNotInstalled(
            source: .english,
            target: .chinese
        ).userFacingMessage
        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: originalTranslatedText,
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: try makeTempAudioFileURL()
        )
        harness.downloadSupport.translationPrompt = makeTranslationPrompt(
            source: .english,
            target: .chinese
        )

        harness.workflow.retrySpeechTranslation(
            forMessageID: harness.message.id,
            in: harness.runtime
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(harness.downloadSupport.presentedTranslationPrompt)
        XCTAssertEqual(harness.message.translatedText, originalTranslatedText)
        XCTAssertTrue(harness.coordinator.speechRequests.isEmpty)
        XCTAssertNil(harness.store.messageMutationErrorMessage)
        XCTAssertTrue(harness.store.streamingStatesByMessageID.isEmpty)
    }

    func testSwitchingToSameLanguageIsNoOp() async throws {
        let harness = try makeHarness(
            inputType: .text,
            sourceText: "你好",
            translatedText: "Hello",
            sourceLanguage: .chinese,
            targetLanguage: .english
        )

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .target,
            to: .english,
            in: harness.runtime
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(harness.coordinator.manualRequests.isEmpty)
        XCTAssertTrue(harness.translationService.translateCalls.isEmpty)
        XCTAssertNil(harness.store.messageMutationErrorMessage)
        XCTAssertEqual(harness.message.targetLanguage, .english)
    }

    func testTextTargetSwitchWithMissingModelPresentsPromptWithoutTranslating() async throws {
        let harness = try makeHarness(
            inputType: .text,
            sourceText: "你好",
            translatedText: "Hello",
            sourceLanguage: .chinese,
            targetLanguage: .english
        )
        harness.downloadSupport.translationPrompt = makeTranslationPrompt(
            source: .chinese,
            target: .french
        )

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .target,
            to: .french,
            in: harness.runtime
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(harness.downloadSupport.presentedTranslationPrompt)
        XCTAssertTrue(harness.coordinator.manualRequests.isEmpty)
        XCTAssertTrue(harness.translationService.translateCalls.isEmpty)
        XCTAssertEqual(harness.message.targetLanguage, .english)
        XCTAssertNil(harness.store.messageMutationErrorMessage)
    }

    func testSpeechSourceSwitchWithMissingSpeechModelPresentsPromptWithoutRetranscribing() async throws {
        let harness = try makeHarness(
            inputType: .speech,
            sourceText: "Hello there",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: try makeTempAudioFileURL()
        )
        harness.downloadSupport.speechPrompt = makeSpeechPrompt()

        harness.workflow.switchLanguage(
            forMessageID: harness.message.id,
            side: .source,
            to: .japanese,
            in: harness.runtime
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(harness.store.activeSpeechDownloadPrompt)
        XCTAssertFalse(harness.store.pendingVoiceStartAfterInstall)
        XCTAssertTrue(harness.speechRecognitionService.calls.isEmpty)
        XCTAssertTrue(harness.recordingLoader.loadedURLs.isEmpty)
        XCTAssertEqual(harness.message.sourceLanguage, .english)
        XCTAssertNil(harness.store.messageMutationErrorMessage)
    }

    private func makeHarness(
        inputType: ChatMessageInputType,
        sourceText: String,
        translatedText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        audioURL: URL? = nil,
        audioReference: String? = nil
    ) throws -> WorkflowHarness {
        let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            configurations: modelConfiguration
        )
        let modelContext = ModelContext(container)
        let session = ChatSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        modelContext.insert(session)

        let message = ChatMessage(
            inputType: inputType,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioReference ?? audioURL?.absoluteString,
            sequence: 0,
            session: session
        )
        modelContext.insert(message)
        try modelContext.save()

        let runtime = HomeRuntimeContext(
            modelContext: modelContext,
            sessions: [session]
        )
        let store = FakeStore(
            sourceLanguage: sourceLanguage,
            selectedLanguage: targetLanguage
        )
        let coordinator = FakeConversationStreamingCoordinator()
        let translationService = FakeTranslationService()
        let speechRecognitionService = FakeSpeechRecognitionService()
        let recordingLoader = FakeRecordingSampleLoader()
        let downloadSupport = FakeDownloadSupport()
        let workflow = HomeMessageLanguageWorkflow(
            store: store,
            sessionRepository: HomeSessionRepository(),
            conversationStreamingCoordinator: coordinator,
            translationService: translationService,
            speechRecognitionService: speechRecognitionService,
            recordingSampleLoader: recordingLoader,
            downloadSupport: downloadSupport,
            playbackController: FakePlaybackController()
        )

        return WorkflowHarness(
            workflow: workflow,
            store: store,
            coordinator: coordinator,
            translationService: translationService,
            speechRecognitionService: speechRecognitionService,
            recordingLoader: recordingLoader,
            downloadSupport: downloadSupport,
            runtime: runtime,
            session: session,
            message: message
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition.")
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeTempAudioFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        let data = Data("audio".utf8)
        FileManager.default.createFile(atPath: url.path, contents: data)
        return url
    }

    private func makeManagedAudioRecording() throws -> (reference: String, fileURL: URL) {
        let messageID = UUID()
        let reference = SpeechRecordingStoragePaths.recordingRelativePath(for: messageID)
        try SpeechRecordingStoragePaths.ensureRecordingsDirectoryExists()
        let fileURL = try XCTUnwrap(
            SpeechRecordingStoragePaths.recordingFileURL(fromRelativePath: reference)
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8))
        return (reference, fileURL)
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

    private func makeSpeechPrompt() -> SpeechModelDownloadPrompt {
        SpeechModelDownloadPrompt(
            package: SpeechModelPackage(
                packageId: "whisper-base-q5_1",
                version: "1.0.0",
                family: .whisper,
                archiveURL: URL(string: "https://example.com/whisper.zip")!,
                sha256: "hash",
                archiveSize: 1_024,
                installedSize: 2_048,
                modelRelativePath: "ggml-base-q5_1.bin",
                minAppVersion: "1.0.0"
            )
        )
    }
}

@MainActor
private struct WorkflowHarness {
    let workflow: HomeMessageLanguageWorkflow
    let store: FakeStore
    let coordinator: FakeConversationStreamingCoordinator
    let translationService: FakeTranslationService
    let speechRecognitionService: FakeSpeechRecognitionService
    let recordingLoader: FakeRecordingSampleLoader
    let downloadSupport: FakeDownloadSupport
    let runtime: HomeRuntimeContext
    let session: ChatSession
    let message: ChatMessage
}

@MainActor
private final class FakeStore: HomeMessageLanguageWorkflowStore {
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt?
    var messageMutationErrorMessage: String?
    var pendingVoiceStartAfterInstall = false
    var selectedLanguage: SupportedLanguage
    var sourceLanguage: SupportedLanguage
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] = [:]
    var messageLanguageSwitchSideByMessageID: [UUID: HomeMessageLanguageSide] = [:]
    var refreshCount = 0

    init(
        sourceLanguage: SupportedLanguage,
        selectedLanguage: SupportedLanguage
    ) {
        self.sourceLanguage = sourceLanguage
        self.selectedLanguage = selectedLanguage
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
        refreshCount += 1
    }
}

private final class FakeConversationStreamingCoordinator: ConversationStreamingCoordinator, @unchecked Sendable {
    struct Request: Equatable {
        let messageID: UUID
        let text: String
        let sourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
    }

    var manualRequests: [Request] = []
    var speechRequests: [Request] = []
    var manualResult = ""
    var speechResult = ""

    func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        manualRequests.append(
            Request(
                messageID: messageID,
                text: text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
        return makeStream(
            messageID: messageID,
            completedText: manualResult
        )
    }

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        speechRequests.append(
            Request(
                messageID: messageID,
                text: text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
        return makeStream(
            messageID: messageID,
            completedText: speechResult
        )
    }

    func startLiveSpeechTranscription(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?
    ) -> AsyncThrowingStream<LiveSpeechTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel(messageID: UUID) async {}

    private func makeStream(
        messageID: UUID,
        completedText: String
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .state(
                    TranslationStreamingState(
                        messageID: messageID,
                        committedText: "",
                        liveText: completedText.isEmpty ? nil : String(completedText.prefix(1)),
                        phase: .typing,
                        revision: 1
                    )
                )
            )
            continuation.yield(.completed(messageID: messageID, text: completedText))
            continuation.finish()
        }
    }
}

private final class FakeTranslationService: TranslationService, @unchecked Sendable {
    struct TranslateCall: Equatable {
        let text: String
        let source: SupportedLanguage
        let target: SupportedLanguage
    }

    var translateCalls: [TranslateCall] = []
    var translateHandler: ((String, SupportedLanguage, SupportedLanguage) throws -> String)?

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
        translateCalls.append(
            TranslateCall(
                text: text,
                source: source,
                target: target
            )
        )
        if let translateHandler {
            return try translateHandler(text, source, target)
        }

        return text
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

private final class FakeSpeechRecognitionService: SpeechRecognitionService, @unchecked Sendable {
    struct Call: Equatable {
        let samples: [Float]
        let preferredLanguage: SupportedLanguage?
    }

    var calls: [Call] = []
    var result = SpeechRecognitionResult(text: "", detectedLanguage: nil)

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
        return result
    }
}

@MainActor
private final class FakeRecordingSampleLoader: SpeechSampleLoading {
    var samples: [Float] = []
    var loadedURLs: [URL] = []

    func loadWhisperSamples(from url: URL) throws -> [Float] {
        loadedURLs.append(url)
        return samples
    }
}

@MainActor
private final class FakeDownloadSupport: HomeMessageLanguageDownloadSupporting {
    var translationPrompt: HomeLanguageDownloadPrompt?
    var speechPrompt: SpeechModelDownloadPrompt?
    var presentedTranslationPrompt: HomeLanguageDownloadPrompt?

    func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt? {
        translationPrompt
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
    func stop() {}
}
