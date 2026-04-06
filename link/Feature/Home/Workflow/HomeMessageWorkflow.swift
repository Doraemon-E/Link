//
//  HomeMessageWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

private enum HomeTranslationRequestOrigin {
    case manual
    case speech
}

@MainActor
protocol HomeMessageWorkflowStore: AnyObject {
    var messageText: String { get set }
    var isRecordingSpeech: Bool { get }
    var isTranscribingSpeech: Bool { get }
    var isInstallingSpeechModel: Bool { get }
    var selectedLanguage: SupportedLanguage { get }
    var messageErrorMessage: String? { get set }
    var sessionPresentation: HomeSessionPresentation { get set }
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] { get set }
}

@MainActor
protocol HomeMessageDownloadSupporting: AnyObject {
    func presentSendPreflightPromptIfNeeded(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> Bool
}

extension HomeDownloadWorkflow: HomeMessageDownloadSupporting {}

@MainActor
final class HomeMessageWorkflow {
    private weak var store: (any HomeMessageWorkflowStore)?
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let textLanguageRecognitionService: TextLanguageRecognitionService
    private let downloadSupport: any HomeMessageDownloadSupporting
    private var translationTasksByMessageID: [UUID: Task<Void, Never>] = [:]

    init(
        store: any HomeMessageWorkflowStore,
        sessionRepository: HomeSessionRepository,
        conversationStreamingCoordinator: any ConversationStreamingCoordinator,
        textLanguageRecognitionService: TextLanguageRecognitionService,
        downloadSupport: any HomeMessageDownloadSupporting
    ) {
        self.store = store
        self.sessionRepository = sessionRepository
        self.conversationStreamingCoordinator = conversationStreamingCoordinator
        self.textLanguageRecognitionService = textLanguageRecognitionService
        self.downloadSupport = downloadSupport
    }

    func sendCurrentMessage(in runtime: HomeRuntimeContext) {
        guard let store else { return }

        let trimmedText = store.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              !store.isRecordingSpeech,
              !store.isTranscribingSpeech,
              !store.isInstallingSpeechModel else {
            return
        }

        let target = store.selectedLanguage
        store.messageErrorMessage = nil

        Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }

            let source: SupportedLanguage
            do {
                source = try await self.resolveSourceLanguage(for: trimmedText)
            } catch let error as TextLanguageRecognitionError {
                store.messageErrorMessage = error.userFacingMessage
                return
            } catch {
                store.messageErrorMessage = "暂时无法识别输入语言，请稍后再试。"
                return
            }

            if await self.downloadSupport.presentSendPreflightPromptIfNeeded(
                source: source,
                target: target
            ) {
                return
            }

            self.submitMessage(
                text: trimmedText,
                sourceLanguage: source,
                targetLanguage: target,
                audioURL: nil,
                translationOrigin: .manual,
                in: runtime,
                clearInput: true
            )
        }
    }

    func startSpeechTranslation(
        for messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return
        }

        startStreamingTranslation(
            for: messageID,
            originalText: trimmedTranscript,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translationOrigin: .speech,
            in: runtime
        )
    }

    private func resolveSourceLanguage(for text: String) async throws -> SupportedLanguage {
        let result = try await textLanguageRecognitionService.recognizeLanguage(for: text)
        return result.language
    }

    private func submitMessage(
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        audioURL: String?,
        translationOrigin: HomeTranslationRequestOrigin,
        in runtime: HomeRuntimeContext,
        clearInput: Bool
    ) {
        guard let store else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let session = sessionRepository.resolveSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            in: runtime,
            presentation: &store.sessionPresentation
        )
        let messageID = sessionRepository.insertConversationExchange(
            text: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioURL,
            into: session,
            in: runtime
        )

        if clearInput {
            store.messageText = ""
        }

        startStreamingTranslation(
            for: messageID,
            originalText: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translationOrigin: translationOrigin,
            in: runtime
        )
    }

    private func startStreamingTranslation(
        for messageID: UUID,
        originalText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        translationOrigin: HomeTranslationRequestOrigin,
        in runtime: HomeRuntimeContext
    ) {
        guard let store else { return }

        translationTasksByMessageID[messageID]?.cancel()
        store.streamingStatesByMessageID[messageID] = ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: originalText,
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .translating,
            translationRevision: 0
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.translationTasksByMessageID.removeValue(forKey: messageID)
            }

            do {
                let stream = self.translationStream(
                    for: messageID,
                    originalText: originalText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    translationOrigin: translationOrigin
                )
                for try await event in stream {
                    self.handleStreamingConversationEvent(event, in: runtime)
                }
            } catch is CancellationError {
                self.store?.streamingStatesByMessageID.removeValue(forKey: messageID)
            } catch let error as TranslationError {
                self.failStreamingTranslation(
                    for: messageID,
                    message: error.userFacingMessage,
                    in: runtime
                )
            } catch {
                self.failStreamingTranslation(
                    for: messageID,
                    message: "翻译失败了，请稍后再试。",
                    in: runtime
                )
            }
        }

        translationTasksByMessageID[messageID] = task
    }

    private func translationStream(
        for messageID: UUID,
        originalText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        translationOrigin: HomeTranslationRequestOrigin
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        switch translationOrigin {
        case .manual:
            return conversationStreamingCoordinator.startManualTranslation(
                messageID: messageID,
                text: originalText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        case .speech:
            return conversationStreamingCoordinator.startSpeechTranslation(
                messageID: messageID,
                text: originalText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
    }

    private func handleStreamingConversationEvent(
        _ event: ConversationStreamingEvent,
        in runtime: HomeRuntimeContext
    ) {
        guard let store else { return }

        switch event {
        case .state(let state):
            guard var existingState = store.streamingStatesByMessageID[state.messageID] else {
                return
            }
            existingState.translatedCommittedText = state.committedText
            existingState.translatedLiveText = state.liveText
            existingState.translationPhase = state.phase
            existingState.translationRevision = state.revision
            store.streamingStatesByMessageID[state.messageID] = existingState
        case .completed(let messageID, let text):
            sessionRepository.updateTranslatedMessage(
                id: messageID,
                text: text,
                in: runtime
            )
            store.streamingStatesByMessageID.removeValue(forKey: messageID)
        }
    }

    private func failStreamingTranslation(
        for messageID: UUID,
        message: String,
        in runtime: HomeRuntimeContext
    ) {
        guard let store else { return }

        var state = store.streamingStatesByMessageID[messageID] ?? ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: "",
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .translating,
            translationRevision: 0
        )
        state.translatedCommittedText = message
        state.translatedLiveText = nil
        state.translationPhase = .failed(message)
        state.translationRevision += 1
        store.streamingStatesByMessageID[messageID] = state

        sessionRepository.updateTranslatedMessage(
            id: messageID,
            text: message,
            in: runtime
        )
        store.streamingStatesByMessageID.removeValue(forKey: messageID)
    }
}

extension HomeMessageWorkflow: HomeSpeechTranslationStarting {}
