//
//  HomeMessageLanguageWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
protocol HomeMessageLanguageWorkflowStore: AnyObject {
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt? { get set }
    var messageMutationErrorMessage: String? { get set }
    var pendingVoiceStartAfterInstall: Bool { get set }
    var selectedLanguage: SupportedLanguage { get set }
    var sourceLanguage: SupportedLanguage { get set }
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] { get set }
    var messageLanguageSwitchSideByMessageID: [UUID: HomeMessageLanguageSide] { get set }

    func refreshDownloadAvailabilityForCurrentSelection() async
}

@MainActor
protocol HomeMessageLanguageDownloadSupporting: AnyObject {
    func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt?

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt)

    func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt?
}

@MainActor
protocol SpeechSampleLoading: AnyObject {
    func loadWhisperSamples(from url: URL) throws -> [Float]
}

@MainActor
protocol HomePlaybackControlling: AnyObject {
    func stop()
}

extension HomeDownloadWorkflow: HomeMessageLanguageDownloadSupporting {}
extension MicrophoneRecordingService: SpeechSampleLoading {}
extension HomePlaybackController: HomePlaybackControlling {}

@MainActor
final class HomeMessageLanguageWorkflow {
    private enum MessageLanguageWorkflowError: LocalizedError {
        case missingSourceRecording
        case missingTranscript
        case missingTranslation

        var userFacingMessage: String {
            switch self {
            case .missingSourceRecording:
                return "这条语音缺少可重新识别的原始录音。"
            case .missingTranscript:
                return "这条消息还没有可用的原文内容。"
            case .missingTranslation:
                return "这条消息还没有可用的译文内容。"
            }
        }
    }

    private weak var store: (any HomeMessageLanguageWorkflowStore)?
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let translationService: TranslationService
    private let speechRecognitionService: SpeechRecognitionService
    private let recordingSampleLoader: any SpeechSampleLoading
    private let downloadSupport: any HomeMessageLanguageDownloadSupporting
    private let playbackController: any HomePlaybackControlling
    private var mutationTasksByMessageID: [UUID: Task<Void, Never>] = [:]

    init(
        store: any HomeMessageLanguageWorkflowStore,
        sessionRepository: HomeSessionRepository,
        conversationStreamingCoordinator: any ConversationStreamingCoordinator,
        translationService: TranslationService,
        speechRecognitionService: SpeechRecognitionService,
        recordingSampleLoader: any SpeechSampleLoading,
        downloadSupport: any HomeMessageLanguageDownloadSupporting,
        playbackController: any HomePlaybackControlling
    ) {
        self.store = store
        self.sessionRepository = sessionRepository
        self.conversationStreamingCoordinator = conversationStreamingCoordinator
        self.translationService = translationService
        self.speechRecognitionService = speechRecognitionService
        self.recordingSampleLoader = recordingSampleLoader
        self.downloadSupport = downloadSupport
        self.playbackController = playbackController
    }

    func switchLanguage(
        forMessageID messageID: UUID,
        side: HomeMessageLanguageSide,
        to language: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) {
        guard let store else {
            return
        }

        guard let message = sessionRepository.message(id: messageID, in: runtime) else {
            return
        }

        guard !isMessageActivelyStreaming(messageID: messageID) else {
            return
        }

        let currentSourceLanguage = resolvedSourceLanguage(for: message)
        let currentTargetLanguage = resolvedTargetLanguage(for: message)
        switch side {
        case .source where currentSourceLanguage == language:
            return
        case .target where currentTargetLanguage == language:
            return
        default:
            break
        }

        playbackController.stop()
        store.messageMutationErrorMessage = nil
        mutationTasksByMessageID[messageID]?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                switch (message.inputType, side) {
                case (.text, .target):
                    try await self.retranslateTextMessage(
                        messageID: messageID,
                        newTargetLanguage: language,
                        in: runtime
                    )
                case (.text, .source):
                    try await self.reverseTranslateTextMessage(
                        messageID: messageID,
                        newSourceLanguage: language,
                        in: runtime
                    )
                case (.speech, .target):
                    try await self.retranslateSpeechMessage(
                        messageID: messageID,
                        newTargetLanguage: language,
                        in: runtime
                    )
                case (.speech, .source):
                    try await self.retranscribeSpeechMessage(
                        messageID: messageID,
                        newSourceLanguage: language,
                        in: runtime
                    )
                }
            } catch is CancellationError {
                self.clearStreamingState(for: messageID)
            } catch let error as MessageLanguageWorkflowError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch let error as TranslationError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch let error as SpeechRecognitionError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = "消息更新失败，请稍后再试。"
            }

            self.endMutation(for: messageID)
        }

        mutationTasksByMessageID[messageID] = task
    }

    func retrySpeechTranslation(
        forMessageID messageID: UUID,
        in runtime: HomeRuntimeContext
    ) {
        guard let store else {
            return
        }

        guard let message = sessionRepository.message(id: messageID, in: runtime),
              message.inputType == .speech else {
            return
        }

        guard !isMessageActivelyStreaming(messageID: messageID) else {
            return
        }

        let targetLanguage = resolvedTargetLanguage(for: message)

        playbackController.stop()
        store.messageMutationErrorMessage = nil
        mutationTasksByMessageID[messageID]?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.retranslateSpeechMessage(
                    messageID: messageID,
                    newTargetLanguage: targetLanguage,
                    in: runtime
                )
            } catch is CancellationError {
                self.clearStreamingState(for: messageID)
            } catch let error as MessageLanguageWorkflowError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch let error as TranslationError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch let error as SpeechRecognitionError {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = error.userFacingMessage
            } catch {
                self.clearStreamingState(for: messageID)
                self.store?.messageMutationErrorMessage = "消息更新失败，请稍后再试。"
            }

            self.endMutation(for: messageID)
        }

        mutationTasksByMessageID[messageID] = task
    }

    private func retranslateTextMessage(
        messageID: UUID,
        newTargetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) async throws {
        guard let message = sessionRepository.message(id: messageID, in: runtime) else {
            return
        }

        let sourceLanguage = resolvedSourceLanguage(for: message)
        try await presentTranslationDownloadPromptIfNeeded(
            source: sourceLanguage,
            target: newTargetLanguage
        )

        beginMutation(for: messageID, side: .target)
        let translatedText = try await streamTranslatedText(
            messageID: messageID,
            sourceText: message.sourceText,
            displayedSourceText: message.sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: newTargetLanguage,
            isSpeechInput: false
        )
        let updatedMessage = sessionRepository.updateMessage(
            id: messageID,
            translatedText: translatedText,
            targetLanguage: newTargetLanguage,
            syncSessionLanguages: true,
            in: runtime
        )
        finalizeSuccessfulMutation(
            message: updatedMessage,
            sourceLanguage: nil,
            targetLanguage: newTargetLanguage
        )
    }

    private func reverseTranslateTextMessage(
        messageID: UUID,
        newSourceLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) async throws {
        guard let message = sessionRepository.message(id: messageID, in: runtime) else {
            return
        }

        let targetLanguage = resolvedTargetLanguage(for: message)
        let normalizedTranslatedText = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranslatedText.isEmpty else {
            throw MessageLanguageWorkflowError.missingTranslation
        }

        try await presentTranslationDownloadPromptIfNeeded(
            source: targetLanguage,
            target: newSourceLanguage
        )

        beginMutation(for: messageID, side: .source)
        let newSourceText = try await translationService.translate(
            text: normalizedTranslatedText,
            source: targetLanguage,
            target: newSourceLanguage
        )
        let updatedMessage = sessionRepository.updateMessage(
            id: messageID,
            sourceText: newSourceText,
            sourceLanguage: newSourceLanguage,
            syncSessionLanguages: true,
            in: runtime
        )
        finalizeSuccessfulMutation(
            message: updatedMessage,
            sourceLanguage: newSourceLanguage,
            targetLanguage: nil
        )
    }

    private func retranslateSpeechMessage(
        messageID: UUID,
        newTargetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) async throws {
        guard let message = sessionRepository.message(id: messageID, in: runtime) else {
            return
        }

        let sourceLanguage = resolvedSourceLanguage(for: message)
        let normalizedTranscript = message.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            throw MessageLanguageWorkflowError.missingTranscript
        }

        try await presentTranslationDownloadPromptIfNeeded(
            source: sourceLanguage,
            target: newTargetLanguage
        )

        beginMutation(for: messageID, side: .target)
        let translatedText = try await streamTranslatedText(
            messageID: messageID,
            sourceText: normalizedTranscript,
            displayedSourceText: message.sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: newTargetLanguage,
            isSpeechInput: true
        )
        let updatedMessage = sessionRepository.updateMessage(
            id: messageID,
            translatedText: translatedText,
            targetLanguage: newTargetLanguage,
            syncSessionLanguages: true,
            in: runtime
        )
        finalizeSuccessfulMutation(
            message: updatedMessage,
            sourceLanguage: nil,
            targetLanguage: newTargetLanguage
        )
    }

    private func retranscribeSpeechMessage(
        messageID: UUID,
        newSourceLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    ) async throws {
        guard let message = sessionRepository.message(id: messageID, in: runtime) else {
            return
        }

        let targetLanguage = resolvedTargetLanguage(for: message)
        guard let audioURL = resolvedAudioURL(for: message) else {
            throw MessageLanguageWorkflowError.missingSourceRecording
        }

        if let speechPrompt = try await downloadSupport.speechDownloadPromptIfNeeded() {
            store?.activeSpeechDownloadPrompt = speechPrompt
            store?.pendingVoiceStartAfterInstall = false
            return
        }

        try await presentTranslationDownloadPromptIfNeeded(
            source: newSourceLanguage,
            target: targetLanguage
        )

        beginMutation(for: messageID, side: .source)
        updateStreamingState(
            for: messageID,
            state: ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: message.sourceText,
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .transcribing,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .transcribing,
            translationRevision: 0
            )
        )

        let samples = try recordingSampleLoader.loadWhisperSamples(from: audioURL)
        let recognitionResult = try await speechRecognitionService.transcribe(
            samples: samples,
            preferredLanguage: newSourceLanguage
        )
        let normalizedTranscript = recognitionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            throw SpeechRecognitionError.emptyTranscription
        }

        let translatedText = try await streamTranslatedText(
            messageID: messageID,
            sourceText: normalizedTranscript,
            displayedSourceText: message.sourceText,
            sourceLanguage: newSourceLanguage,
            targetLanguage: targetLanguage,
            isSpeechInput: true
        )
        let updatedMessage = sessionRepository.updateMessage(
            id: messageID,
            sourceText: normalizedTranscript,
            translatedText: translatedText,
            sourceLanguage: newSourceLanguage,
            syncSessionLanguages: true,
            in: runtime
        )
        finalizeSuccessfulMutation(
            message: updatedMessage,
            sourceLanguage: newSourceLanguage,
            targetLanguage: nil
        )
    }

    private func streamTranslatedText(
        messageID: UUID,
        sourceText: String,
        displayedSourceText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        isSpeechInput: Bool
    ) async throws -> String {
        updateStreamingState(
            for: messageID,
            state: ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: displayedSourceText,
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .translating,
            translationRevision: 0
            )
        )

        let stream: AsyncThrowingStream<ConversationStreamingEvent, Error>
        if isSpeechInput {
            stream = conversationStreamingCoordinator.startSpeechTranslation(
                messageID: messageID,
                text: sourceText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        } else {
            stream = conversationStreamingCoordinator.startManualTranslation(
                messageID: messageID,
                text: sourceText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }

        var completedText: String?
        var latestDisplayText = ""
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .state(let state):
                guard var existingState = store?.streamingStatesByMessageID[messageID] else {
                    continue
                }
                let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayText.isEmpty {
                    latestDisplayText = state.displayText
                }
                existingState.translatedCommittedText = state.committedText
                existingState.translatedLiveText = state.liveText
                existingState.translationPhase = state.phase
                existingState.translationRevision = state.revision
                updateStreamingState(for: messageID, state: existingState)
            case .completed(_, let text):
                completedText = text
            }
        }

        if let completedText,
           !completedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return completedText
        }

        guard !latestDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyOutput
        }

        return latestDisplayText
    }

    private func presentTranslationDownloadPromptIfNeeded(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws {
        if let prompt = try await downloadSupport.translationDownloadPrompt(
            source: source,
            target: target
        ) {
            downloadSupport.presentTranslationDownloadPrompt(prompt)
            throw CancellationError()
        }
    }

    private func finalizeSuccessfulMutation(
        message: ChatMessage?,
        sourceLanguage: SupportedLanguage?,
        targetLanguage: SupportedLanguage?
    ) {
        guard let message else {
            return
        }

        clearStreamingState(for: message.id)
        if let sourceLanguage {
            store?.sourceLanguage = sourceLanguage
        } else if let sessionSourceLanguage = message.session?.sourceLanguage {
            store?.sourceLanguage = sessionSourceLanguage
        }

        if let targetLanguage {
            store?.selectedLanguage = targetLanguage
        } else if let sessionTargetLanguage = message.session?.targetLanguage {
            store?.selectedLanguage = sessionTargetLanguage
        }

        Task { @MainActor [weak self] in
            guard let store = self?.store else { return }
            await store.refreshDownloadAvailabilityForCurrentSelection()
        }
    }

    private func beginMutation(
        for messageID: UUID,
        side: HomeMessageLanguageSide
    ) {
        guard let store else { return }
        store.messageLanguageSwitchSideByMessageID[messageID] = side
    }

    private func endMutation(for messageID: UUID) {
        guard let store else {
            mutationTasksByMessageID.removeValue(forKey: messageID)
            return
        }
        store.messageLanguageSwitchSideByMessageID.removeValue(forKey: messageID)
        mutationTasksByMessageID.removeValue(forKey: messageID)
    }

    private func isMessageActivelyStreaming(messageID: UUID) -> Bool {
        guard let streamingState = store?.streamingStatesByMessageID[messageID] else {
            return false
        }

        return streamingState.sourcePhase.isInProgress || streamingState.translationPhase.isInProgress
    }

    private func resolvedSourceLanguage(for message: ChatMessage) -> SupportedLanguage {
        message.sourceLanguage ?? message.session?.sourceLanguage ?? store?.sourceLanguage ?? .chinese
    }

    private func resolvedTargetLanguage(for message: ChatMessage) -> SupportedLanguage {
        message.targetLanguage ?? message.session?.targetLanguage ?? store?.selectedLanguage ?? .english
    }

    private func resolvedAudioURL(for message: ChatMessage) -> URL? {
        guard let url = HomeSessionRepository.localAudioFileURL(from: message.audioURL) else {
            return nil
        }

        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func clearStreamingState(for messageID: UUID) {
        guard let store else { return }
        store.streamingStatesByMessageID.removeValue(forKey: messageID)
    }

    private func updateStreamingState(
        for messageID: UUID,
        state: ExchangeStreamingState
    ) {
        guard let store else { return }
        store.streamingStatesByMessageID[messageID] = state
    }
}
