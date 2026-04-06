//
//  HomeSpeechWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
protocol HomeSpeechWorkflowStore: AnyObject {
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt? { get set }
    var isChatInputFocused: Bool { get set }
    var isInstallingSpeechModel: Bool { get }
    var isRecordingSpeech: Bool { get set }
    var isTranscribingSpeech: Bool { get set }
    var lastSpeechRecordingURL: URL? { get set }
    var pendingVoiceStartAfterInstall: Bool { get set }
    var playbackErrorMessage: String? { get set }
    var selectedLanguage: SupportedLanguage { get set }
    var sessionPresentation: HomeSessionPresentation { get set }
    var sourceLanguage: SupportedLanguage { get set }
    var speechErrorMessage: String? { get set }
    var speechResumeRequestToken: Int { get set }
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] { get set }
}

@MainActor
protocol HomeSpeechDownloadSupporting: AnyObject {
    func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt?

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt)

    func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt?

    func isTranslationReady(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> Bool
}

@MainActor
protocol HomeSpeechTranslationStarting: AnyObject {
    func startSpeechTranslation(
        for messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext
    )
}

extension HomeDownloadWorkflow: HomeSpeechDownloadSupporting {}

@MainActor
final class HomeSpeechWorkflow {
    private struct LiveSpeechSession {
        let record: HomeLiveSpeechSessionRecord
        var latestState: LiveUtteranceState = .init()
        var liveTask: Task<Void, Never>?
    }

    private weak var store: (any HomeSpeechWorkflowStore)?
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let messageWorkflow: any HomeSpeechTranslationStarting
    private let speechRecognitionService: SpeechRecognitionService
    private let microphoneRecordingService: any SpeechRecordingService
    private let downloadWorkflow: any HomeSpeechDownloadSupporting
    private let playbackController: any HomePlaybackControlling
    private var silenceAutoStopTask: Task<Void, Never>?
    private var liveSpeechSession: LiveSpeechSession?

    init(
        store: any HomeSpeechWorkflowStore,
        sessionRepository: HomeSessionRepository,
        conversationStreamingCoordinator: any ConversationStreamingCoordinator,
        messageWorkflow: any HomeSpeechTranslationStarting,
        speechRecognitionService: SpeechRecognitionService,
        microphoneRecordingService: any SpeechRecordingService,
        downloadWorkflow: any HomeSpeechDownloadSupporting,
        playbackController: any HomePlaybackControlling
    ) {
        self.store = store
        self.sessionRepository = sessionRepository
        self.conversationStreamingCoordinator = conversationStreamingCoordinator
        self.messageWorkflow = messageWorkflow
        self.speechRecognitionService = speechRecognitionService
        self.microphoneRecordingService = microphoneRecordingService
        self.downloadWorkflow = downloadWorkflow
        self.playbackController = playbackController
    }

    func toggleSpeechRecording(in runtime: HomeRuntimeContext) async {
        guard let store else { return }

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
        guard let store else { return }

        guard store.speechResumeRequestToken > 0 else {
            return
        }

        store.speechResumeRequestToken = 0
        await startSpeechRecording(in: runtime)
    }

    private func startSpeechRecording(in runtime: HomeRuntimeContext) async {
        guard let store else { return }

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
            startLiveSpeechTranscription(audioStream: audioStream, in: runtime)
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
        guard let store else { return }
        guard store.isRecordingSpeech else { return }

        cancelSilenceAutoStop()
        store.isRecordingSpeech = false
        store.isTranscribingSpeech = true
        store.speechErrorMessage = nil
        var preservedRecordingURL: URL?

        defer {
            store.isTranscribingSpeech = false
        }

        do {
            guard let liveSpeechSession else {
                throw SpeechRecognitionError.recordingNotActive
            }
            let messageID = liveSpeechSession.record.message.id

            let recordingResult = try await microphoneRecordingService.stopRecording(for: messageID)
            preservedRecordingURL = recordingResult.preservedRecordingURL
            store.lastSpeechRecordingURL = recordingResult.preservedRecordingURL
            if let liveTask = self.liveSpeechSession?.liveTask {
                await liveTask.value
            }

            let recognitionResult = try await speechRecognitionService.transcribe(
                samples: recordingResult.samples,
                preferredLanguage: nil
            )
            let transcribedText = recognitionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcribedText.isEmpty else {
                throw SpeechRecognitionError.emptyTranscription
            }

            let effectiveSourceLanguage = try await resolvedSpeechSourceLanguage(
                detectedLanguageCode: recognitionResult.detectedLanguage,
                fallbackSourceLanguage: liveSpeechSession.record.fallbackSourceLanguage,
                targetLanguage: liveSpeechSession.record.targetLanguage
            )
            let targetLanguage = liveSpeechSession.record.targetLanguage

            sessionRepository.finalizeLiveSpeechTranscript(
                liveSpeechSession.record,
                transcript: transcribedText,
                sourceLanguage: effectiveSourceLanguage,
                audioURL: preservedRecordingURL?.absoluteString,
                in: runtime
            )
            self.liveSpeechSession = nil

            do {
                if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                    source: effectiveSourceLanguage,
                    target: targetLanguage
                ) {
                    downloadWorkflow.presentTranslationDownloadPrompt(prompt)
                    sessionRepository.updateTranslatedMessage(
                        id: messageID,
                        text: TranslationError.modelNotInstalled(
                            source: effectiveSourceLanguage,
                            target: targetLanguage
                        ).userFacingMessage,
                        in: runtime
                    )
                    store.streamingStatesByMessageID.removeValue(forKey: messageID)
                    store.speechErrorMessage = nil
                    return
                }

                messageWorkflow.startSpeechTranslation(
                    for: messageID,
                    transcript: transcribedText,
                    sourceLanguage: effectiveSourceLanguage,
                    targetLanguage: targetLanguage,
                    in: runtime
                )
                store.speechErrorMessage = nil
            } catch let error as TranslationError {
                handleSpeechTranslationFailure(
                    messageID: messageID,
                    message: error.userFacingMessage,
                    in: runtime
                )
            } catch {
                handleSpeechTranslationFailure(
                    messageID: messageID,
                    message: "翻译失败了，请稍后再试。",
                    in: runtime
                )
            }
        } catch let error as SpeechRecognitionError {
            microphoneRecordingService.cancelRecording()
            cleanupFailedPreservedRecording(at: preservedRecordingURL)
            handleSpeechRecognitionFailure(
                message: error.userFacingMessage,
                in: runtime
            )
        } catch {
            microphoneRecordingService.cancelRecording()
            cleanupFailedPreservedRecording(at: preservedRecordingURL)
            handleSpeechRecognitionFailure(
                message: "语音识别失败了，请稍后再试。",
                in: runtime
            )
        }
    }

    private func prepareForSpeechRecording() {
        guard let store else { return }

        playbackController.stop()
        store.speechErrorMessage = nil
        store.playbackErrorMessage = nil
        store.pendingVoiceStartAfterInstall = false
        store.lastSpeechRecordingURL = nil
    }

    private func startLiveSpeechTranscription(
        audioStream: AsyncStream<[Float]>,
        in runtime: HomeRuntimeContext
    ) {
        guard var liveSpeechSession else {
            return
        }

        liveSpeechSession.liveTask?.cancel()
        let messageID = liveSpeechSession.record.message.id

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = self.conversationStreamingCoordinator.startLiveSpeechTranscription(
                    messageID: messageID,
                    audioStream: audioStream,
                    sourceLanguage: nil
                )

                for try await event in stream {
                    self.handleLiveSpeechTranscriptionEvent(event, in: runtime)
                }
            } catch is CancellationError {
                return
            } catch let error as SpeechRecognitionError {
                self.store?.speechErrorMessage = error.userFacingMessage
            } catch let error as ConversationStreamingCoordinatorError {
                self.store?.speechErrorMessage = error.localizedDescription
            } catch {
                self.store?.speechErrorMessage = "实时语音识别暂时不可用，请稍后再试。"
            }
        }

        liveSpeechSession.liveTask = task
        self.liveSpeechSession = liveSpeechSession
    }

    private func handleLiveSpeechTranscriptionEvent(
        _ event: LiveSpeechTranscriptionEvent,
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

            guard let self,
                  let store = self.store,
                  store.isRecordingSpeech else { return }
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
        guard let store else {
            cancelSilenceAutoStop()
            return
        }

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
        guard let store else {
            return
        }

        let transcriptText = state.fullTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        store.streamingStatesByMessageID[liveSpeechSession.message.id] = ExchangeStreamingState(
            messageID: liveSpeechSession.message.id,
            sourceStableText: state.stableTranscript,
            sourceProvisionalText: state.provisionalTranscript,
            sourceLiveText: state.liveTranscript,
            sourcePhase: transcriptText.isEmpty
                ? .transcribing
                : (store.isRecordingSpeech ? .transcribing : .completed),
            sourceRevision: state.transcriptRevision,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .idle,
            translationRevision: 0
        )
    }

    private func cleanupLiveSpeechSessionIfNeeded(in runtime: HomeRuntimeContext) {
        guard liveSpeechSession != nil else {
            return
        }

        discardLiveSpeechSession(in: runtime)
    }

    private func discardLiveSpeechSession(in runtime: HomeRuntimeContext) {
        guard let liveSpeechSession,
              let store else {
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

    private func handleSpeechRecognitionFailure(
        message: String,
        in runtime: HomeRuntimeContext
    ) {
        if liveSpeechSession != nil {
            discardLiveSpeechSession(in: runtime)
        }

        store?.speechErrorMessage = message
    }

    private func handleSpeechTranslationFailure(
        messageID: UUID,
        message: String,
        in runtime: HomeRuntimeContext
    ) {
        store?.streamingStatesByMessageID.removeValue(forKey: messageID)
        sessionRepository.updateTranslatedMessage(
            id: messageID,
            text: message,
            in: runtime
        )
        store?.speechErrorMessage = nil
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

    private func cleanupFailedPreservedRecording(at url: URL?) {
        guard let url else {
            return
        }

        try? FileManager.default.removeItem(at: url)
        if store?.lastSpeechRecordingURL == url {
            store?.lastSpeechRecordingURL = nil
        }
    }
}
