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
    private let audioFilePlaybackService: AudioFilePlaybackService
    private var currentPlaybackID: UUID?
    private var playbackStatesByID: [UUID: HomePlaybackState] = [:]

    init(
        store: HomeStore,
        textToSpeechService: TextToSpeechService,
        audioFilePlaybackService: AudioFilePlaybackService
    ) {
        self.store = store
        self.textToSpeechService = textToSpeechService
        self.audioFilePlaybackService = audioFilePlaybackService
    }

    func startObservingPlayback() {
        textToSpeechService.playbackEventHandler = { [weak self] event in
            self?.handleTextToSpeechPlaybackEvent(event)
        }
        audioFilePlaybackService.playbackEventHandler = { [weak self] event in
            self?.handleAudioFilePlaybackEvent(event)
        }
    }

    func shouldShowTranslatedPlaybackButton(for message: ChatMessage) -> Bool {
        guard store.streamingStatesByMessageID[message.id]?.isTranslationActive != true else {
            return false
        }

        return !message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isTranslatedPlaybackDisabled(for message: ChatMessage) -> Bool {
        guard shouldShowTranslatedPlaybackButton(for: message) else {
            return true
        }

        return isPlaybackGloballyDisabled
    }

    func isPlayingTranslatedMessage(_ message: ChatMessage) -> Bool {
        store.activePlaybackState == HomePlaybackState(
            messageID: message.id,
            kind: .translatedTTS
        )
    }

    func toggleTranslatedPlayback(message: ChatMessage) {
        let targetState = HomePlaybackState(messageID: message.id, kind: .translatedTTS)
        if store.activePlaybackState == targetState {
            stop()
            return
        }

        guard shouldShowTranslatedPlaybackButton(for: message) else {
            return
        }

        guard !isPlaybackGloballyDisabled else {
            return
        }

        guard let language = translatedPlaybackLanguage(for: message) else {
            store.playbackErrorMessage = "无法确定这条消息译文的朗读语言。"
            return
        }

        let text = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        startTextToSpeechPlayback(
            text: text,
            language: language,
            state: targetState
        )
    }

    func isSourcePlaybackDisabled(for message: ChatMessage) -> Bool {
        guard !isPlaybackGloballyDisabled else {
            return true
        }

        switch message.inputType {
        case .text:
            return sourceText(for: message).isEmpty || sourcePlaybackLanguage(for: message) == nil
        case .speech:
            return !hasPlayableSourceRecording(for: message)
        }
    }

    func isPlayingSourceMessage(_ message: ChatMessage) -> Bool {
        guard let activePlaybackState = store.activePlaybackState,
              activePlaybackState.messageID == message.id else {
            return false
        }

        switch activePlaybackState.kind {
        case .sourceTTS, .sourceRecording:
            return true
        case .translatedTTS:
            return false
        }
    }

    func hasPlayableSourceRecording(for message: ChatMessage) -> Bool {
        guard message.inputType == .speech else {
            return false
        }

        return resolvedAudioURL(for: message) != nil
    }

    func toggleSourcePlayback(message: ChatMessage) {
        let targetState = HomePlaybackState(
            messageID: message.id,
            kind: message.inputType == .speech ? .sourceRecording : .sourceTTS
        )
        if store.activePlaybackState == targetState {
            stop()
            return
        }

        guard !isPlaybackGloballyDisabled else {
            return
        }

        switch message.inputType {
        case .text:
            guard let language = sourcePlaybackLanguage(for: message) else {
                store.playbackErrorMessage = "无法确定这条消息原文的朗读语言。"
                return
            }

            let text = sourceText(for: message)
            guard !text.isEmpty else {
                return
            }

            startTextToSpeechPlayback(
                text: text,
                language: language,
                state: targetState
            )
        case .speech:
            guard let audioURL = resolvedAudioURL(for: message) else {
                store.playbackErrorMessage = sourceRecordingFailureMessage(for: message)
                return
            }

            startAudioFilePlayback(
                url: audioURL,
                state: targetState
            )
        }
    }

    func shouldAutoExpandSpeechTranscript(for message: ChatMessage) -> Bool {
        guard message.inputType == .speech,
              let streamingState = store.streamingStatesByMessageID[message.id] else {
            return false
        }

        return streamingState.sourcePhase.isInProgress || streamingState.translationPhase.isInProgress
    }

    func stop() {
        let previousPlaybackID = currentPlaybackID
        let hadActivePlayback = previousPlaybackID != nil || store.activePlaybackState != nil
        currentPlaybackID = nil
        store.activePlaybackState = nil

        if let previousPlaybackID {
            playbackStatesByID.removeValue(forKey: previousPlaybackID)
        }

        guard hadActivePlayback else {
            return
        }

        textToSpeechService.stop()
        audioFilePlaybackService.stop()
    }

    private var isPlaybackGloballyDisabled: Bool {
        store.isRecordingSpeech || store.isTranscribingSpeech
    }

    private func startTextToSpeechPlayback(
        text: String,
        language: SupportedLanguage,
        state: HomePlaybackState
    ) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return
        }

        let playbackID = preparePlayback(state: state)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentPlaybackID == playbackID else { return }

            do {
                try await self.textToSpeechService.speak(
                    text: normalizedText,
                    language: language,
                    playbackID: playbackID
                )
            } catch let error as TextToSpeechError {
                self.handlePlaybackFailure(
                    playbackID: playbackID,
                    message: error.userFacingMessage
                )
            } catch {
                self.handlePlaybackFailure(
                    playbackID: playbackID,
                    message: "语音播放失败，请稍后再试。"
                )
            }
        }
    }

    private func startAudioFilePlayback(
        url: URL,
        state: HomePlaybackState
    ) {
        let playbackID = preparePlayback(state: state)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentPlaybackID == playbackID else { return }

            do {
                try await self.audioFilePlaybackService.play(
                    url: url,
                    playbackID: playbackID
                )
            } catch let error as AudioFilePlaybackError {
                self.handlePlaybackFailure(
                    playbackID: playbackID,
                    message: error.userFacingMessage
                )
            } catch {
                self.handlePlaybackFailure(
                    playbackID: playbackID,
                    message: "原始语音播放失败，请稍后再试。"
                )
            }
        }
    }

    @discardableResult
    private func preparePlayback(state: HomePlaybackState) -> UUID {
        stop()

        let playbackID = UUID()
        currentPlaybackID = playbackID
        playbackStatesByID[playbackID] = state
        store.activePlaybackState = state
        store.playbackErrorMessage = nil
        return playbackID
    }

    private func translatedPlaybackLanguage(for message: ChatMessage) -> SupportedLanguage? {
        if let language = message.targetLanguage {
            return language
        }

        return message.session?.targetLanguage ?? store.selectedLanguage
    }

    private func sourcePlaybackLanguage(for message: ChatMessage) -> SupportedLanguage? {
        if let language = message.sourceLanguage {
            return language
        }

        return message.session?.sourceLanguage ?? store.sourceLanguage
    }

    private func sourceText(for message: ChatMessage) -> String {
        let streamingText = store.streamingStatesByMessageID[message.id]?.sourceDisplayText ?? ""
        let trimmedStreamingText = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStreamingText.isEmpty {
            return trimmedStreamingText
        }

        return message.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedAudioURL(for message: ChatMessage) -> URL? {
        guard let url = parsedLocalAudioURL(for: message) else {
            return nil
        }

        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func sourceRecordingFailureMessage(for message: ChatMessage) -> String {
        guard let audioURLString = message.audioURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioURLString.isEmpty else {
            return "这条语音还没有可播放的原始录音。"
        }

        guard let url = parsedLocalAudioURL(from: audioURLString) else {
            return "这条语音的录音地址无效，暂时无法播放。"
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            return AudioFilePlaybackError.fileNotFound.userFacingMessage
        }

        return "这条语音暂时无法播放原始录音。"
    }

    private func parsedLocalAudioURL(for message: ChatMessage) -> URL? {
        guard let audioURLString = message.audioURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioURLString.isEmpty else {
            return nil
        }

        return parsedLocalAudioURL(from: audioURLString)
    }

    private func parsedLocalAudioURL(from audioURLString: String) -> URL? {
        if let url = URL(string: audioURLString), url.isFileURL {
            return url
        }

        guard audioURLString.hasPrefix("/") else {
            return nil
        }

        return URL(fileURLWithPath: audioURLString)
    }

    private func clearPlaybackState(for playbackID: UUID) {
        let removedState = playbackStatesByID.removeValue(forKey: playbackID)

        guard currentPlaybackID == playbackID else {
            return
        }

        currentPlaybackID = nil
        if store.activePlaybackState == removedState {
            store.activePlaybackState = nil
        }
    }

    private func handlePlaybackFailure(
        playbackID: UUID,
        message: String
    ) {
        guard currentPlaybackID == playbackID else {
            playbackStatesByID.removeValue(forKey: playbackID)
            return
        }

        clearPlaybackState(for: playbackID)
        store.playbackErrorMessage = message
    }

    private func handleTextToSpeechPlaybackEvent(_ event: TextToSpeechPlaybackEvent) {
        switch event {
        case .started(let playbackID):
            guard currentPlaybackID == playbackID,
                  let playbackState = playbackStatesByID[playbackID],
                  playbackState.kind.isTextToSpeech else {
                return
            }
            store.activePlaybackState = playbackState
        case .finished(let playbackID), .cancelled(let playbackID):
            clearPlaybackState(for: playbackID)
        case .failed(let playbackID, let message):
            handlePlaybackFailure(playbackID: playbackID, message: message)
        }
    }

    private func handleAudioFilePlaybackEvent(_ event: AudioFilePlaybackEvent) {
        switch event {
        case .started(let playbackID):
            guard currentPlaybackID == playbackID,
                  let playbackState = playbackStatesByID[playbackID],
                  playbackState.kind == .sourceRecording else {
                return
            }
            store.activePlaybackState = playbackState
        case .finished(let playbackID), .cancelled(let playbackID):
            clearPlaybackState(for: playbackID)
        case .failed(let playbackID, let message):
            handlePlaybackFailure(playbackID: playbackID, message: message)
        }
    }
}
