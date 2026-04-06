//
//  HomePlaybackController.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
final class HomePlaybackController {
    private unowned let store: HomeStore
    private let textToSpeechService: TextToSpeechService
    private var requestedTextToSpeechMessageID: UUID?

    init(
        store: HomeStore,
        textToSpeechService: TextToSpeechService
    ) {
        self.store = store
        self.textToSpeechService = textToSpeechService
    }

    func startObservingPlayback() {
        textToSpeechService.playbackEventHandler = { [weak self] event in
            self?.handleTextToSpeechPlaybackEvent(event)
        }
    }

    func shouldShowMessageSpeechButton(for message: ChatMessage) -> Bool {
        guard store.streamingStatesByMessageID[message.id]?.isTranslationActive != true else {
            return false
        }

        return !message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isMessageSpeechPlaybackDisabled(for message: ChatMessage) -> Bool {
        guard shouldShowMessageSpeechButton(for: message) else {
            return true
        }

        return store.isRecordingSpeech || store.isTranscribingSpeech
    }

    func isSpeakingMessage(_ message: ChatMessage) -> Bool {
        store.speakingMessageID == message.id
    }

    func toggleMessageSpeechPlayback(message: ChatMessage) {
        guard shouldShowMessageSpeechButton(for: message) else {
            return
        }

        if store.speakingMessageID == message.id {
            stop()
            return
        }

        guard let language = playbackLanguage(for: message) else {
            store.ttsErrorMessage = "无法确定这条消息的朗读语言。"
            return
        }

        if store.speakingMessageID != nil {
            textToSpeechService.stop()
        }

        let messageID = message.id
        let text = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedTextToSpeechMessageID = messageID
        store.speakingMessageID = messageID
        store.ttsErrorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.requestedTextToSpeechMessageID == messageID else { return }

            do {
                try await self.textToSpeechService.speak(
                    text: text,
                    language: language,
                    messageID: messageID
                )
            } catch let error as TextToSpeechError {
                self.clearPlaybackState(messageID: messageID)
                self.store.ttsErrorMessage = error.userFacingMessage
            } catch {
                self.clearPlaybackState(messageID: messageID)
                self.store.ttsErrorMessage = "语音播放失败，请稍后再试。"
            }
        }
    }

    func stop() {
        requestedTextToSpeechMessageID = nil
        store.speakingMessageID = nil
        textToSpeechService.stop()
    }

    private func playbackLanguage(for message: ChatMessage) -> SupportedLanguage? {
        if let language = message.targetLanguage {
            return language
        }

        return message.session?.targetLanguage ?? store.selectedLanguage
    }

    private func clearPlaybackState(messageID: UUID) {
        if requestedTextToSpeechMessageID == messageID {
            requestedTextToSpeechMessageID = nil
        }
        if store.speakingMessageID == messageID {
            store.speakingMessageID = nil
        }
    }

    private func handleTextToSpeechPlaybackEvent(_ event: TextToSpeechPlaybackEvent) {
        switch event {
        case .started(let messageID):
            guard requestedTextToSpeechMessageID == messageID || store.speakingMessageID == messageID else {
                return
            }
            store.speakingMessageID = messageID
        case .finished(let messageID), .cancelled(let messageID):
            clearPlaybackState(messageID: messageID)
        case .failed(let messageID, let message):
            clearPlaybackState(messageID: messageID)
            store.ttsErrorMessage = message
        }
    }
}
