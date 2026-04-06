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
    var immersiveVoiceTranslationState: HomeImmersiveVoiceTranslationState? { get set }
    var isChatInputFocused: Bool { get set }
    var isInstallingSpeechModel: Bool { get }
    var isRecordingSpeech: Bool { get set }
    var isTranscribingSpeech: Bool { get set }
    var lastSpeechRecordingURL: URL? { get set }
    var pendingSpeechCaptureOrigin: HomeSpeechCaptureOrigin { get set }
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

    private struct CompletedSpeechCapture {
        let liveSpeechSession: LiveSpeechSession
        let preservedRecordingURL: URL?
        let transcript: String
        let sourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
    }

    private weak var store: (any HomeSpeechWorkflowStore)?
    private let sessionRepository: HomeSessionRepository
    private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    private let messageWorkflow: any HomeSpeechTranslationStarting
    private let speechRecognitionService: SpeechRecognitionService
    private let microphoneRecordingService: any SpeechRecordingService
    private let downloadWorkflow: any HomeSpeechDownloadSupporting
    private let playbackController: any HomePlaybackControlling
    private var activeCaptureOrigin: HomeSpeechCaptureOrigin?
    private var silenceAutoStopTask: Task<Void, Never>?
    private var liveSpeechSession: LiveSpeechSession?
    private var immersivePreviewTask: Task<Void, Never>?
    private var immersivePreviewTaskID: UUID?
    private var immersiveFinalTranslationTaskID: UUID?
    private var immersivePreviewGeneration = 0
    private var immersivePreviewSourceLanguage: SupportedLanguage?
    private var immersiveLastStableTranscript = ""
    private var immersiveLatestTranslatedText = ""

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

        await beginSpeechRecordingIfPossible(in: runtime, origin: .compactMic)
    }

    func startImmersiveVoiceTranslation(in runtime: HomeRuntimeContext) async {
        guard let store else { return }

        guard !store.isRecordingSpeech, !store.isTranscribingSpeech, !store.isInstallingSpeechModel else {
            return
        }

        await beginSpeechRecordingIfPossible(in: runtime, origin: .immersiveWave)
    }

    func handlePendingSpeechResumeIfNeeded(in runtime: HomeRuntimeContext) async {
        guard let store else { return }

        guard store.speechResumeRequestToken > 0 else {
            return
        }

        let origin = store.pendingSpeechCaptureOrigin
        store.speechResumeRequestToken = 0
        await startSpeechRecording(in: runtime, origin: origin)
    }

    private func beginSpeechRecordingIfPossible(
        in runtime: HomeRuntimeContext,
        origin: HomeSpeechCaptureOrigin
    ) async {
        guard let store else { return }

        do {
            if let prompt = try await downloadWorkflow.speechDownloadPromptIfNeeded() {
                store.activeSpeechDownloadPrompt = prompt
                store.pendingVoiceStartAfterInstall = true
                store.pendingSpeechCaptureOrigin = origin
                return
            }

            await startSpeechRecording(in: runtime, origin: origin)
        } catch let error as SpeechRecognitionError {
            store.speechErrorMessage = error.userFacingMessage
        } catch {
            store.speechErrorMessage = "语音识别暂时不可用，请稍后再试。"
        }
    }

    private func startSpeechRecording(
        in runtime: HomeRuntimeContext,
        origin: HomeSpeechCaptureOrigin
    ) async {
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

            activeCaptureOrigin = origin
            liveSpeechSession = LiveSpeechSession(record: liveSession)

            if origin == .immersiveWave {
                store.immersiveVoiceTranslationState = HomeImmersiveVoiceTranslationState(
                    messageID: liveSession.message.id,
                    translatedText: "",
                    phase: .listening
                )
            } else {
                applyLiveSpeechState(LiveUtteranceState(), to: liveSession)
            }

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
            let completedCapture = try await completeSpeechCapture(in: runtime)
            preservedRecordingURL = completedCapture.preservedRecordingURL

            switch activeCaptureOrigin ?? .compactMic {
            case .compactMic:
                await finishCompactSpeechCapture(completedCapture, in: runtime)
            case .immersiveWave:
                await finishImmersiveSpeechCapture(completedCapture, in: runtime)
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

    private func completeSpeechCapture(in runtime: HomeRuntimeContext) async throws -> CompletedSpeechCapture {
        guard let liveSpeechSession else {
            throw SpeechRecognitionError.recordingNotActive
        }

        let messageID = liveSpeechSession.record.message.id
        let recordingResult = try await microphoneRecordingService.stopRecording(for: messageID)
        store?.lastSpeechRecordingURL = recordingResult.preservedRecordingURL

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

        let effectiveSourceLanguage = resolvedSpeechSourceLanguage(
            detectedLanguageCode: recognitionResult.detectedLanguage,
            liveDetectedLanguage: self.liveSpeechSession?.latestState.detectedLanguage,
            fallbackSourceLanguage: liveSpeechSession.record.fallbackSourceLanguage
        )

        return CompletedSpeechCapture(
            liveSpeechSession: liveSpeechSession,
            preservedRecordingURL: recordingResult.preservedRecordingURL,
            transcript: transcribedText,
            sourceLanguage: effectiveSourceLanguage,
            targetLanguage: liveSpeechSession.record.targetLanguage
        )
    }

    private func finishCompactSpeechCapture(
        _ completedCapture: CompletedSpeechCapture,
        in runtime: HomeRuntimeContext
    ) async {
        guard let store else { return }

        let messageID = completedCapture.liveSpeechSession.record.message.id

        sessionRepository.finalizeLiveSpeechTranscript(
            completedCapture.liveSpeechSession.record,
            transcript: completedCapture.transcript,
            sourceLanguage: completedCapture.sourceLanguage,
            audioURL: completedCapture.preservedRecordingURL?.absoluteString,
            in: runtime
        )

        self.liveSpeechSession = nil
        activeCaptureOrigin = nil

        do {
            if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                source: completedCapture.sourceLanguage,
                target: completedCapture.targetLanguage
            ) {
                downloadWorkflow.presentTranslationDownloadPrompt(prompt)
                sessionRepository.updateTranslatedMessage(
                    id: messageID,
                    text: TranslationError.modelNotInstalled(
                        source: completedCapture.sourceLanguage,
                        target: completedCapture.targetLanguage
                    ).userFacingMessage,
                    in: runtime
                )
                store.streamingStatesByMessageID.removeValue(forKey: messageID)
                store.speechErrorMessage = nil
                return
            }

            messageWorkflow.startSpeechTranslation(
                for: messageID,
                transcript: completedCapture.transcript,
                sourceLanguage: completedCapture.sourceLanguage,
                targetLanguage: completedCapture.targetLanguage,
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
    }

    private func finishImmersiveSpeechCapture(
        _ completedCapture: CompletedSpeechCapture,
        in runtime: HomeRuntimeContext
    ) async {
        guard let store else { return }

        updateImmersiveVoiceTranslationState(
            text: immersiveLatestTranslatedText,
            phase: .finalizing
        )
        cancelImmersivePreviewTranslation()

        do {
            if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                source: completedCapture.sourceLanguage,
                target: completedCapture.targetLanguage
            ) {
                cleanupFailedPreservedRecording(at: completedCapture.preservedRecordingURL)
                discardLiveSpeechSession(in: runtime)
                downloadWorkflow.presentTranslationDownloadPrompt(prompt)
                store.speechErrorMessage = nil
                return
            }
        } catch {
            // Fall through to the final translation attempt and surface its failure in-session.
        }

        let translatedText: String
        do {
            translatedText = try await streamImmersiveFinalTranslation(
                transcript: completedCapture.transcript,
                sourceLanguage: completedCapture.sourceLanguage,
                targetLanguage: completedCapture.targetLanguage
            )
        } catch let error as TranslationError {
            translatedText = error.userFacingMessage
        } catch {
            translatedText = "翻译失败了，请稍后再试。"
        }

        sessionRepository.finalizeLiveSpeechSession(
            completedCapture.liveSpeechSession.record,
            transcript: completedCapture.transcript,
            translatedText: translatedText,
            sourceLanguage: completedCapture.sourceLanguage,
            audioURL: completedCapture.preservedRecordingURL?.absoluteString,
            in: runtime
        )

        self.liveSpeechSession = nil
        activeCaptureOrigin = nil
        resetImmersiveTranslationRuntime(clearPresentation: true)
        store.speechErrorMessage = nil
    }

    private func prepareForSpeechRecording() {
        guard let store else { return }

        playbackController.stop()
        store.speechErrorMessage = nil
        store.playbackErrorMessage = nil
        store.pendingVoiceStartAfterInstall = false
        store.pendingSpeechCaptureOrigin = .compactMic
        store.lastSpeechRecordingURL = nil
        resetImmersiveTranslationRuntime(clearPresentation: true)
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

            switch activeCaptureOrigin ?? .compactMic {
            case .compactMic:
                applyLiveSpeechState(state, to: updatedSession.record)
            case .immersiveWave:
                scheduleImmersiveTranslationPreview(for: state, in: runtime)
            }

            updateSilenceAutoStop(
                previousState: previousState,
                currentState: state,
                in: runtime
            )
        }
    }

    private func scheduleImmersiveTranslationPreview(
        for state: LiveUtteranceState,
        in runtime: HomeRuntimeContext
    ) {
        updateImmersiveVoiceTranslationState(
            text: immersiveLatestTranslatedText,
            phase: immersiveLatestTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .listening
                : .translating
        )

        Task { @MainActor [weak self] in
            await self?.refreshImmersiveTranslationPreview(for: state, in: runtime)
        }
    }

    private func refreshImmersiveTranslationPreview(
        for state: LiveUtteranceState,
        in runtime: HomeRuntimeContext
    ) async {
        guard activeCaptureOrigin == .immersiveWave,
              let store,
              store.isRecordingSpeech,
              let liveSpeechSession else {
            return
        }

        let stableTranscript = state.stableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stableTranscript.isEmpty else {
            return
        }

        guard let detectedLanguage = state.detectedLanguage else {
            return
        }

        if immersivePreviewSourceLanguage != detectedLanguage {
            do {
                if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                    source: detectedLanguage,
                    target: liveSpeechSession.record.targetLanguage
                ) {
                    guard activeCaptureOrigin == .immersiveWave,
                          self.liveSpeechSession?.record.message.id == liveSpeechSession.record.message.id else {
                        return
                    }

                    await abortImmersiveSpeechSessionForMissingModel(prompt, in: runtime)
                    return
                }
            } catch {
                // Ignore transient route errors here and let the final translation surface them if needed.
            }

            guard activeCaptureOrigin == .immersiveWave,
                  self.liveSpeechSession?.record.message.id == liveSpeechSession.record.message.id else {
                return
            }

            immersivePreviewSourceLanguage = detectedLanguage
            immersiveLastStableTranscript = ""
        }

        guard stableTranscript != immersiveLastStableTranscript else {
            return
        }

        immersiveLastStableTranscript = stableTranscript
        startImmersivePreviewTranslation(
            transcript: stableTranscript,
            sourceLanguage: detectedLanguage,
            targetLanguage: liveSpeechSession.record.targetLanguage
        )
    }

    private func startImmersivePreviewTranslation(
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) {
        cancelImmersivePreviewTranslation()

        let requestGeneration = immersivePreviewGeneration + 1
        immersivePreviewGeneration = requestGeneration

        let taskID = UUID()
        immersivePreviewTaskID = taskID
        updateImmersiveVoiceTranslationState(
            text: immersiveLatestTranslatedText,
            phase: .translating
        )

        immersivePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = self.conversationStreamingCoordinator.startSpeechTranslation(
                    messageID: taskID,
                    text: transcript,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )

                for try await event in stream {
                    guard self.activeCaptureOrigin == .immersiveWave,
                          requestGeneration == self.immersivePreviewGeneration else {
                        continue
                    }

                    switch event {
                    case .state(let state):
                        let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !displayText.isEmpty {
                            self.immersiveLatestTranslatedText = state.displayText
                            self.updateImmersiveVoiceTranslationState(
                                text: state.displayText,
                                phase: .translating
                            )
                        }
                    case .completed(_, let text):
                        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !normalizedText.isEmpty {
                            self.immersiveLatestTranslatedText = text
                            self.updateImmersiveVoiceTranslationState(
                                text: text,
                                phase: .translating
                            )
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func streamImmersiveFinalTranslation(
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) async throws -> String {
        let taskID = UUID()
        immersiveFinalTranslationTaskID = taskID

        updateImmersiveVoiceTranslationState(
            text: immersiveLatestTranslatedText,
            phase: .finalizing
        )

        let stream = conversationStreamingCoordinator.startSpeechTranslation(
            messageID: taskID,
            text: transcript,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        var completedText: String?

        defer {
            immersiveFinalTranslationTaskID = nil
        }

        for try await event in stream {
            switch event {
            case .state(let state):
                let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayText.isEmpty {
                    immersiveLatestTranslatedText = state.displayText
                    updateImmersiveVoiceTranslationState(
                        text: state.displayText,
                        phase: .finalizing
                    )
                }
            case .completed(_, let text):
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedText.isEmpty {
                    immersiveLatestTranslatedText = text
                    updateImmersiveVoiceTranslationState(
                        text: text,
                        phase: .finalizing
                    )
                }
                completedText = text
            }
        }

        guard let completedText else {
            throw TranslationError.emptyOutput
        }

        return completedText
    }

    private func abortImmersiveSpeechSessionForMissingModel(
        _ prompt: HomeLanguageDownloadPrompt,
        in runtime: HomeRuntimeContext
    ) async {
        guard let store else { return }

        cancelSilenceAutoStop()
        microphoneRecordingService.cancelRecording()
        store.isRecordingSpeech = false
        store.isTranscribingSpeech = false
        discardLiveSpeechSession(in: runtime)
        downloadWorkflow.presentTranslationDownloadPrompt(prompt)
        store.speechErrorMessage = nil
    }

    private func updateImmersiveVoiceTranslationState(
        text: String? = nil,
        phase: HomeImmersiveVoiceTranslationPhase
    ) {
        guard let store else { return }

        guard var state = store.immersiveVoiceTranslationState else {
            if let liveSpeechSession {
                store.immersiveVoiceTranslationState = HomeImmersiveVoiceTranslationState(
                    messageID: liveSpeechSession.record.message.id,
                    translatedText: text ?? immersiveLatestTranslatedText,
                    phase: phase
                )
            }
            return
        }

        if let text {
            state.translatedText = text
        }
        state.phase = phase
        store.immersiveVoiceTranslationState = state
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
        resetImmersiveTranslationRuntime(clearPresentation: true)
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
        activeCaptureOrigin = nil
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
        liveDetectedLanguage: SupportedLanguage?,
        fallbackSourceLanguage: SupportedLanguage
    ) -> SupportedLanguage {
        if let detectedLanguage = SupportedLanguage.fromWhisperLanguageCode(detectedLanguageCode) {
            return detectedLanguage
        }

        if let liveDetectedLanguage {
            return liveDetectedLanguage
        }

        return fallbackSourceLanguage
    }

    private func resetImmersiveTranslationRuntime(clearPresentation: Bool) {
        cancelImmersivePreviewTranslation()

        if let finalTaskID = immersiveFinalTranslationTaskID {
            Task {
                await conversationStreamingCoordinator.cancel(messageID: finalTaskID)
            }
        }

        immersiveFinalTranslationTaskID = nil
        immersivePreviewGeneration = 0
        immersivePreviewSourceLanguage = nil
        immersiveLastStableTranscript = ""
        immersiveLatestTranslatedText = ""

        if clearPresentation {
            store?.immersiveVoiceTranslationState = nil
        }
    }

    private func cancelImmersivePreviewTranslation() {
        immersivePreviewTask?.cancel()
        immersivePreviewTask = nil

        if let previewTaskID = immersivePreviewTaskID {
            Task {
                await conversationStreamingCoordinator.cancel(messageID: previewTaskID)
            }
        }

        immersivePreviewTaskID = nil
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
