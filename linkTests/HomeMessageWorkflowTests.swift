//
//  HomeMessageWorkflowTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeMessageWorkflowTests: XCTestCase {
    func testSendCurrentMessagePresentsTargetLanguagePromptAndKeepsInput() async throws {
        let harness = try makeHarness(
            messageText: "你好",
            recognizedLanguage: .chinese,
            selectedLanguage: .english
        )
        harness.downloadSupport.outcome = .targetLanguagePrompt(.english)

        harness.workflow.sendCurrentMessage(in: harness.runtime)

        try await waitUntil {
            harness.store.activeTargetLanguageModelPrompt != nil
        }

        XCTAssertEqual(harness.store.activeTargetLanguageModelPrompt?.targetLanguage, .english)
        XCTAssertNil(harness.store.activeDownloadPrompt)
        XCTAssertEqual(harness.store.messageText, "你好")
        XCTAssertEqual(try messageCount(in: harness.runtime.modelContext), 0)
        XCTAssertTrue(harness.coordinator.manualRequests.isEmpty)
    }

    func testSendCurrentMessagePresentsTranslationDownloadPromptAndKeepsInput() async throws {
        let harness = try makeHarness(
            messageText: "你好",
            recognizedLanguage: .chinese,
            selectedLanguage: .english
        )
        harness.downloadSupport.outcome = .translationPrompt(
            makeTranslationPrompt(source: .chinese, target: .english)
        )

        harness.workflow.sendCurrentMessage(in: harness.runtime)

        try await waitUntil {
            harness.store.activeDownloadPrompt != nil
        }

        XCTAssertNil(harness.store.activeTargetLanguageModelPrompt)
        XCTAssertEqual(harness.store.activeDownloadPrompt?.sourceLanguage, .chinese)
        XCTAssertEqual(harness.store.activeDownloadPrompt?.targetLanguage, .english)
        XCTAssertEqual(harness.store.messageText, "你好")
        XCTAssertEqual(try messageCount(in: harness.runtime.modelContext), 0)
        XCTAssertTrue(harness.coordinator.manualRequests.isEmpty)
    }

    func testSendCurrentMessageSubmitsAndClearsInputWhenPreflightPasses() async throws {
        let harness = try makeHarness(
            messageText: "  hello world  ",
            recognizedLanguage: .english,
            selectedLanguage: .french
        )
        harness.coordinator.manualResult = "bonjour le monde"

        harness.workflow.sendCurrentMessage(in: harness.runtime)

        try await waitUntil {
            try self.messageCount(in: harness.runtime.modelContext) == 1
        }

        let messages = try fetchMessages(in: harness.runtime.modelContext)

        XCTAssertNil(harness.store.activeTargetLanguageModelPrompt)
        XCTAssertNil(harness.store.activeDownloadPrompt)
        XCTAssertEqual(harness.store.messageText, "")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.sourceText, "hello world")
        XCTAssertEqual(messages.first?.translatedText, "bonjour le monde")
        XCTAssertEqual(messages.first?.sourceLanguage, .english)
        XCTAssertEqual(messages.first?.targetLanguage, .french)
        XCTAssertEqual(harness.coordinator.manualRequests.count, 1)
        XCTAssertEqual(harness.coordinator.manualRequests.first?.text, "hello world")
        XCTAssertEqual(harness.coordinator.manualRequests.first?.sourceLanguage, .english)
        XCTAssertEqual(harness.coordinator.manualRequests.first?.targetLanguage, .french)
    }

    private func makeHarness(
        messageText: String,
        recognizedLanguage: SupportedLanguage,
        selectedLanguage: SupportedLanguage
    ) throws -> WorkflowHarness {
        let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            configurations: modelConfiguration
        )
        let modelContext = ModelContext(container)
        let runtime = HomeRuntimeContext(
            modelContext: modelContext,
            sessions: []
        )
        let store = FakeStore(
            messageText: messageText,
            selectedLanguage: selectedLanguage
        )
        let coordinator = FakeConversationStreamingCoordinator()
        let downloadSupport = FakeDownloadSupport(store: store)
        let workflow = HomeMessageWorkflow(
            store: store,
            sessionRepository: HomeSessionRepository(),
            conversationStreamingCoordinator: coordinator,
            textLanguageRecognitionService: FakeTextLanguageRecognitionService(
                resultLanguage: recognizedLanguage
            ),
            downloadSupport: downloadSupport
        )

        return WorkflowHarness(
            workflow: workflow,
            store: store,
            coordinator: coordinator,
            downloadSupport: downloadSupport,
            runtime: runtime
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if try condition() {
                return
            }

            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition.")
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fetchMessages(in modelContext: ModelContext) throws -> [ChatMessage] {
        try modelContext.fetch(FetchDescriptor<ChatMessage>())
            .sorted { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
    }

    private func messageCount(in modelContext: ModelContext) throws -> Int {
        try fetchMessages(in: modelContext).count
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

@MainActor
private struct WorkflowHarness {
    let workflow: HomeMessageWorkflow
    let store: FakeStore
    let coordinator: FakeConversationStreamingCoordinator
    let downloadSupport: FakeDownloadSupport
    let runtime: HomeRuntimeContext
}

@MainActor
private final class FakeStore: HomeMessageWorkflowStore {
    var messageText: String
    var isRecordingSpeech = false
    var isTranscribingSpeech = false
    var isInstallingSpeechModel = false
    var selectedLanguage: SupportedLanguage
    var messageErrorMessage: String?
    var sessionPresentation: HomeSessionPresentation = .none
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] = [:]
    var activeTargetLanguageModelPrompt: HomeTargetLanguageModelPrompt?
    var activeDownloadPrompt: HomeLanguageDownloadPrompt?

    init(
        messageText: String,
        selectedLanguage: SupportedLanguage
    ) {
        self.messageText = messageText
        self.selectedLanguage = selectedLanguage
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
    var manualResult = ""

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
        makeStream(
            messageID: messageID,
            completedText: text
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

private struct FakeTextLanguageRecognitionService: TextLanguageRecognitionService {
    let resultLanguage: SupportedLanguage

    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult {
        TextLanguageRecognitionResult(
            language: resultLanguage,
            confidence: 1,
            hypotheses: [resultLanguage: 1]
        )
    }
}

@MainActor
private final class FakeDownloadSupport: HomeMessageDownloadSupporting {
    enum Outcome {
        case none
        case targetLanguagePrompt(SupportedLanguage)
        case translationPrompt(HomeLanguageDownloadPrompt)
    }

    private weak var store: FakeStore?
    var outcome: Outcome = .none

    init(store: FakeStore) {
        self.store = store
    }

    func presentSendPreflightPromptIfNeeded(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> Bool {
        guard let store else { return false }

        switch outcome {
        case .none:
            return false
        case .targetLanguagePrompt(let targetLanguage):
            store.activeDownloadPrompt = nil
            store.activeTargetLanguageModelPrompt = HomeTargetLanguageModelPrompt(
                targetLanguage: targetLanguage
            )
            return true
        case .translationPrompt(let prompt):
            store.activeTargetLanguageModelPrompt = nil
            store.activeDownloadPrompt = prompt
            return true
        }
    }
}
