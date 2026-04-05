//
//  SystemTextToSpeechService.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import AVFoundation
import Foundation

@MainActor
final class SystemTextToSpeechService: NSObject, TextToSpeechService {
    private let synthesizer: AVSpeechSynthesizer
    private var utteranceMessageIDs: [ObjectIdentifier: UUID] = [:]
    private var eventContinuations: [UUID: AsyncStream<TextToSpeechPlaybackEvent>.Continuation] = [:]

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.delegate = self
    }

    func speak(text: String, language: HomeLanguage, messageID: UUID) async throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            let error = TextToSpeechError.emptyText
            emit(.failed(messageID: messageID, message: error.userFacingMessage))
            throw error
        }

        do {
            try configureAudioSession()
        } catch let error as TextToSpeechError {
            emit(.failed(messageID: messageID, message: error.userFacingMessage))
            throw error
        } catch {
            let wrappedError = TextToSpeechError.playbackUnavailable(error.localizedDescription)
            emit(.failed(messageID: messageID, message: wrappedError.userFacingMessage))
            throw wrappedError
        }

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = AVSpeechSynthesisVoice(language: language.ttsLocaleIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utteranceMessageIDs[ObjectIdentifier(utterance)] = messageID
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else {
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
    }

    func playbackEvents() -> AsyncStream<TextToSpeechPlaybackEvent> {
        AsyncStream { continuation in
            let token = UUID()
            eventContinuations[token] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: token)
                }
            }
        }
    }

    private func configureAudioSession() throws {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw TextToSpeechError.audioSessionUnavailable(error.localizedDescription)
        }
    }

    private func finishAudioSessionIfNeeded() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func messageID(for utterance: AVSpeechUtterance) -> UUID? {
        utteranceMessageIDs[ObjectIdentifier(utterance)]
    }

    private func removeMessageID(for utterance: AVSpeechUtterance) -> UUID? {
        utteranceMessageIDs.removeValue(forKey: ObjectIdentifier(utterance))
    }

    private func emit(_ event: TextToSpeechPlaybackEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

extension SystemTextToSpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        _ = synthesizer

        guard let messageID = messageID(for: utterance) else {
            return
        }

        emit(.started(messageID: messageID))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        _ = synthesizer

        guard let messageID = removeMessageID(for: utterance) else {
            finishAudioSessionIfNeeded()
            return
        }

        emit(.finished(messageID: messageID))
        finishAudioSessionIfNeeded()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        _ = synthesizer

        guard let messageID = removeMessageID(for: utterance) else {
            finishAudioSessionIfNeeded()
            return
        }

        emit(.cancelled(messageID: messageID))
        finishAudioSessionIfNeeded()
    }
}
