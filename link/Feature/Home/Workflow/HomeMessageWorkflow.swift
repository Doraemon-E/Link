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
final class HomeMessageWorkflow {
    private unowned let store: HomeStore
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let textLanguageRecognitionService: TextLanguageRecognitionService
    private let downloadWorkflow: HomeDownloadWorkflow
    private var translationTasksByMessageID: [UUID: Task<Void, Never>] = [:]

    init(
        store: HomeStore,
        sessionRepository: HomeSessionRepository,
        conversationStreamingCoordinator: any ConversationStreamingCoordinator,
        textLanguageRecognitionService: TextLanguageRecognitionService,
        downloadWorkflow: HomeDownloadWorkflow
    ) {
        self.store = store
        self.sessionRepository = sessionRepository
        self.conversationStreamingCoordinator = conversationStreamingCoordinator
        self.textLanguageRecognitionService = textLanguageRecognitionService
        self.downloadWorkflow = downloadWorkflow
    }

    func sendCurrentMessage(in runtime: HomeRuntimeContext) {
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
            guard let self else { return }

            let source: SupportedLanguage
            do {
                source = try await self.resolveSourceLanguage(for: trimmedText)
            } catch let error as TextLanguageRecognitionError {
                self.store.messageErrorMessage = error.userFacingMessage
                return
            } catch {
                self.store.messageErrorMessage = "暂时无法识别输入语言，请稍后再试。"
                return
            }

            if let prompt = await self.downloadWorkflow.downloadPromptIfNeeded(
                source: source,
                target: target
            ) {
                self.downloadWorkflow.presentTranslationDownloadPrompt(prompt)
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
                self.store.streamingStatesByMessageID.removeValue(forKey: messageID)
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
