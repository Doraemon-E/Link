//
//  HomeSpeechWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
final class HomeSpeechWorkflow {
    private struct LiveSpeechSession {
        let record: HomeLiveSpeechSessionRecord
        var latestState: LiveUtteranceState = .init()
        var liveTask: Task<Void, Never>?
    }

    private unowned let store: HomeStore
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let translationService: TranslationService
    private let speechRecognitionService: SpeechRecognitionService
    private let microphoneRecordingService: MicrophoneRecordingService
    private let downloadWorkflow: HomeDownloadWorkflow
    private let playbackController: HomePlaybackController
    private var silenceAutoStopTask: Task<Void, Never>?
    private var liveSpeechSession: LiveSpeechSession?

    init(
        store: HomeStore,
        sessionRepository: HomeSessionRepository,
        conversationStreamingCoordinator: any ConversationStreamingCoordinator,
        translationService: TranslationService,
        speechRecognitionService: SpeechRecognitionService,
        microphoneRecordingService: MicrophoneRecordingService,
        downloadWorkflow: HomeDownloadWorkflow,
        playbackController: HomePlaybackController
    ) {
        self.store = store
        self.sessionRepository = sessionRepository
        self.conversationStreamingCoordinator = conversationStreamingCoordinator
        self.translationService = translationService
        self.speechRecognitionService = speechRecognitionService
        self.microphoneRecordingService = microphoneRecordingService
        self.downloadWorkflow = downloadWorkflow
        self.playbackController = playbackController
    }

    func toggleSpeechRecording(in runtime: HomeRuntimeContext) async {
        guard !store.isTranscribingSpeech, !store.isInstallingSpeechModel else {
            return
        }

        if store.isRecordingSpeech {
            await stopSpeechRecordingAndTranslate(in: runtime)
            return
        }

        do {
            if let prompt = try await downloadWorkflow.speechDownloadPromptIfNeeded() {
                store.activeSpeechDownloadPrompt = prompt
                store.pendingVoiceStartAfterInstall = true
                return
            }

            await startSpeechRecording(in: runtime)
        } catch let error as SpeechRecognitionError {
            store.speechErrorMessage = error.userFacingMessage
        } catch {
            store.speechErrorMessage = "语音识别暂时不可用，请稍后再试。"
        }
    }

    func handlePendingSpeechResumeIfNeeded(in runtime: HomeRuntimeContext) async {
        guard store.speechResumeRequestToken > 0 else {
            return
        }

        store.speechResumeRequestToken = 0
        await startSpeechRecording(in: runtime)
    }

    private func startSpeechRecording(in runtime: HomeRuntimeContext) async {
        guard !store.isRecordingSpeech, !store.isTranscribingSpeech, !store.isInstallingSpeechModel else {
            return
        }

        prepareForSpeechRecording()

        do {
            let audioStream = try await microphoneRecordingService.startStreamingRecording()
            let liveSession = sessionRepository.createLiveSpeechSession(
                sourceLanguage: store.sourceLanguage,
                targetLanguage: store.selectedLanguage,
                in: runtime,
                presentation: &store.sessionPresentation
            )
            liveSpeechSession = LiveSpeechSession(record: liveSession)
            applyLiveSpeechState(LiveUtteranceState(), to: liveSession)
            startLiveSpeechStreaming(audioStream: audioStream, in: runtime)
            store.isRecordingSpeech = true
            store.isChatInputFocused = false
            scheduleSilenceAutoStop(in: runtime)
        } catch let error as SpeechRecognitionError {
            cleanupLiveSpeechSessionIfNeeded(in: runtime)
            store.speechErrorMessage = error.userFacingMessage
        } catch {
            cleanupLiveSpeechSessionIfNeeded(in: runtime)
            store.speechErrorMessage = "无法开始录音，请稍后重试。"
        }
    }

    private func stopSpeechRecordingAndTranslate(in runtime: HomeRuntimeContext) async {
        guard store.isRecordingSpeech else { return }

        cancelSilenceAutoStop()
        store.isRecordingSpeech = false
        store.isTranscribingSpeech = true
        store.speechErrorMessage = nil

        defer {
            store.isTranscribingSpeech = false
        }

        do {
            guard let liveSpeechSession else {
                throw SpeechRecognitionError.recordingNotActive
            }

            let recordingResult = try await microphoneRecordingService.stopRecording()
            store.lastSpeechRecordingURL = recordingResult.preservedRecordingURL
            if let liveTask = self.liveSpeechSession?.liveTask {
                await liveTask.value
            }

            let recognitionResult = try await speechRecognitionService.transcribe(samples: recordingResult.samples)
            let transcribedText = recognitionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcribedText.isEmpty else {
                throw SpeechRecognitionError.emptyTranscription
            }

            let effectiveSourceLanguage = try await resolvedSpeechSourceLanguage(
                detectedLanguageCode: recognitionResult.detectedLanguage,
                fallbackSourceLanguage: liveSpeechSession.record.fallbackSourceLanguage,
                targetLanguage: liveSpeechSession.record.targetLanguage
            )
            if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                source: effectiveSourceLanguage,
                target: liveSpeechSession.record.targetLanguage
            ) {
                downloadWorkflow.presentTranslationDownloadPrompt(prompt)
                sessionRepository.finalizeLiveSpeechSession(
                    liveSpeechSession.record,
                    transcript: transcribedText,
                    translatedText: TranslationError.modelNotInstalled(
                        source: effectiveSourceLanguage,
                        target: liveSpeechSession.record.targetLanguage
                    ).userFacingMessage,
                    sourceLanguage: effectiveSourceLanguage,
                    audioURL: recordingResult.preservedRecordingURL?.absoluteString,
                    in: runtime
                )
                store.streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.record.message.id)
                store.speechErrorMessage = nil
                self.liveSpeechSession = nil
                return
            }

            let translatedText = try await translationService.translate(
                text: transcribedText,
                source: effectiveSourceLanguage,
                target: liveSpeechSession.record.targetLanguage
            )
            let reconciledOutput = reconciledLiveSpeechOutput(
                liveState: liveSpeechSession.latestState,
                finalTranscript: transcribedText,
                finalTranslation: translatedText
            )
            sessionRepository.finalizeLiveSpeechSession(
                liveSpeechSession.record,
                transcript: reconciledOutput.transcript,
                translatedText: reconciledOutput.translation,
                sourceLanguage: effectiveSourceLanguage,
                audioURL: recordingResult.preservedRecordingURL?.absoluteString,
                in: runtime
            )
            store.streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.record.message.id)
            store.speechErrorMessage = nil
            self.liveSpeechSession = nil
        } catch let error as SpeechRecognitionError {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: error.userFacingMessage,
                in: runtime
            )
        } catch let error as TranslationError {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: error.userFacingMessage,
                in: runtime
            )
        } catch {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: "语音识别失败了，请稍后再试。",
                in: runtime
            )
        }
    }

    private func prepareForSpeechRecording() {
        playbackController.stop()
        store.speechErrorMessage = nil
        store.ttsErrorMessage = nil
        store.pendingVoiceStartAfterInstall = false
    }

    private func startLiveSpeechStreaming(
        audioStream: AsyncStream<[Float]>,
        in runtime: HomeRuntimeContext
    ) {
        guard var liveSpeechSession else {
            return
        }

        liveSpeechSession.liveTask?.cancel()
        let messageID = liveSpeechSession.record.message.id
        let targetLanguage = liveSpeechSession.record.targetLanguage

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = self.conversationStreamingCoordinator.startLiveSpeechTranslation(
                    messageID: messageID,
                    audioStream: audioStream,
                    sourceLanguage: nil,
                    targetLanguage: targetLanguage
                )

                for try await event in stream {
                    self.handleLiveSpeechTranslationEvent(event, in: runtime)
                }
            } catch is CancellationError {
                return
            } catch let error as SpeechRecognitionError {
                self.store.speechErrorMessage = error.userFacingMessage
            } catch let error as TranslationError {
                self.store.speechErrorMessage = error.userFacingMessage
            } catch let error as ConversationStreamingCoordinatorError {
                self.store.speechErrorMessage = error.localizedDescription
            } catch {
                self.store.speechErrorMessage = "实时语音翻译暂时不可用，请稍后再试。"
            }
        }

        liveSpeechSession.liveTask = task
        self.liveSpeechSession = liveSpeechSession
    }

    private func handleLiveSpeechTranslationEvent(
        _ event: LiveSpeechTranslationEvent,
        in runtime: HomeRuntimeContext
    ) {
        guard let liveSpeechSession else {
            return
        }

        switch event {
        case .state(let state), .completed(let state):
            let previousState = liveSpeechSession.latestState
            var updatedSession = liveSpeechSession
            updatedSession.latestState = state
            self.liveSpeechSession = updatedSession
            applyLiveSpeechState(state, to: updatedSession.record)
            updateSilenceAutoStop(
                previousState: previousState,
                currentState: state,
                in: runtime
            )
        }
    }

    private func scheduleSilenceAutoStop(in runtime: HomeRuntimeContext) {
        silenceAutoStopTask?.cancel()
        silenceAutoStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }

            guard let self, self.store.isRecordingSpeech else { return }
            await self.stopSpeechRecordingAndTranslate(in: runtime)
        }
    }

    private func cancelSilenceAutoStop() {
        silenceAutoStopTask?.cancel()
        silenceAutoStopTask = nil
    }

    private func updateSilenceAutoStop(
        previousState: LiveUtteranceState,
        currentState: LiveUtteranceState,
        in runtime: HomeRuntimeContext
    ) {
        guard store.isRecordingSpeech else {
            cancelSilenceAutoStop()
            return
        }

        let transcriptDidChange = previousState.transcriptRevision != currentState.transcriptRevision
            || previousState.fullTranscript != currentState.fullTranscript
            || previousState.isEndpoint != currentState.isEndpoint

        guard transcriptDidChange else {
            return
        }

        let hasTranscript = !currentState.fullTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if currentState.isEndpoint || !hasTranscript {
            scheduleSilenceAutoStop(in: runtime)
            return
        }

        cancelSilenceAutoStop()
    }

    private func applyLiveSpeechState(
        _ state: LiveUtteranceState,
        to liveSpeechSession: HomeLiveSpeechSessionRecord
    ) {
        let transcriptText = state.fullTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = state.effectiveTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisiblePreviewTranslation = state.hasUnstableTranslation ||
            state.hasDisplayTranslationBeyondStable

        store.streamingStatesByMessageID[liveSpeechSession.message.id] = ExchangeStreamingState(
            messageID: liveSpeechSession.message.id,
            sourceStableText: state.stableTranscript,
            sourceProvisionalText: state.provisionalTranscript,
            sourceLiveText: state.liveTranscript,
            sourcePhase: transcriptText.isEmpty ? .transcribing : (store.isRecordingSpeech ? .transcribing : .completed),
            sourceRevision: state.transcriptRevision,
            translatedCommittedText: state.stableTranslation,
            translatedLiveText: hasVisiblePreviewTranslation && !translationText.isEmpty ? translationText : nil,
            translationPhase: translationText.isEmpty
                ? .translating
                : ((store.isRecordingSpeech || state.hasUnstableTranscript || hasVisiblePreviewTranslation) ? .typing : .completed),
            translationRevision: state.translationRevision
        )
    }

    private func cleanupLiveSpeechSessionIfNeeded(in runtime: HomeRuntimeContext) {
        guard liveSpeechSession != nil else {
            return
        }

        discardLiveSpeechSession(in: runtime)
    }

    private func discardLiveSpeechSession(in runtime: HomeRuntimeContext) {
        guard let liveSpeechSession else {
            return
        }

        cancelSilenceAutoStop()
        liveSpeechSession.liveTask?.cancel()
        Task {
            await conversationStreamingCoordinator.cancel(messageID: liveSpeechSession.record.message.id)
        }
        store.streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.record.message.id)
        sessionRepository.discardLiveSpeechSession(
            liveSpeechSession.record,
            in: runtime,
            presentation: &store.sessionPresentation
        )
        self.liveSpeechSession = nil
    }

    private func fallbackTranscriptAndTranslation(
        from state: LiveUtteranceState
    ) -> (transcript: String, translation: String)? {
        let transcript = state.fullTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = state.effectiveTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty, !translation.isEmpty else {
            return nil
        }

        return (transcript, translation)
    }

    private func reconciledLiveSpeechOutput(
        liveState: LiveUtteranceState,
        finalTranscript: String,
        finalTranslation: String
    ) -> (transcript: String, translation: String) {
        let liveTranscript = liveState.fullTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let liveTranslation = liveState.effectiveTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            transcript: reconciledSpeechText(
                finalText: finalTranscript,
                liveText: liveTranscript
            ),
            translation: reconciledSpeechText(
                finalText: finalTranslation,
                liveText: liveTranslation
            )
        )
    }

    private func reconciledSpeechText(
        finalText: String,
        liveText: String
    ) -> String {
        let normalizedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLiveText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedFinalText.isEmpty else {
            return normalizedLiveText
        }

        guard !normalizedLiveText.isEmpty else {
            return normalizedFinalText
        }

        return normalizedFinalText
    }

    private func finalizeLiveSpeechSessionAfterFailure(
        fallbackMessage: String,
        in runtime: HomeRuntimeContext
    ) async {
        guard let liveSpeechSession else {
            store.speechErrorMessage = fallbackMessage
            return
        }

        if let liveTask = liveSpeechSession.liveTask {
            await liveTask.value
        }

        if let fallback = fallbackTranscriptAndTranslation(from: liveSpeechSession.latestState) {
            sessionRepository.finalizeLiveSpeechSession(
                liveSpeechSession.record,
                transcript: fallback.transcript,
                translatedText: fallback.translation,
                sourceLanguage: liveSpeechSession.latestState.detectedLanguage ?? liveSpeechSession.record.fallbackSourceLanguage,
                audioURL: store.lastSpeechRecordingURL?.absoluteString,
                in: runtime
            )
            store.streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.record.message.id)
            store.speechErrorMessage = nil
            self.liveSpeechSession = nil
        } else {
            discardLiveSpeechSession(in: runtime)
            store.speechErrorMessage = fallbackMessage
        }
    }

    private func resolvedSpeechSourceLanguage(
        detectedLanguageCode: String?,
        fallbackSourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) async throws -> SupportedLanguage {
        if let detectedLanguage = SupportedLanguage.fromWhisperLanguageCode(detectedLanguageCode),
           await downloadWorkflow.isTranslationReady(
               source: detectedLanguage,
               target: targetLanguage
           ) {
            return detectedLanguage
        }

        return fallbackSourceLanguage
    }
}
