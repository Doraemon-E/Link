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
    private var immersivePreviewRefreshTask: Task<Void, Never>?
    private var immersivePendingPreviewState: LiveUtteranceState?
    private var immersivePendingPreviewRuntime: HomeRuntimeContext?
    private var immersiveFinalTranslationTaskID: UUID?
    private var lockedSpeechSourceLanguage: SupportedLanguage?
    private var immersivePreviewGeneration = 0
    private var immersivePreviewSourceLanguage: SupportedLanguage?
    private var immersiveCommittedSourceSegments: [String] = []
    private var immersiveCommittedTranslatedSegments: [HomeImmersiveVoiceTranslationSegment] = []
    private var immersiveActiveSourceText = ""
    private var immersiveActiveTranslatedText = ""

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
                    committedSegments: [],
                    activeText: "",
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
            cleanupFailedPreservedRecording(
                at: preservedRecordingURL ?? store.lastSpeechRecordingURL
            )
            handleSpeechRecognitionFailure(
                message: error.userFacingMessage,
                in: runtime
            )
        } catch {
            microphoneRecordingService.cancelRecording()
            cleanupFailedPreservedRecording(
                at: preservedRecordingURL ?? store.lastSpeechRecordingURL
            )
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
            liveDetectedLanguage: lockedSpeechSourceLanguage ?? self.liveSpeechSession?.latestState.detectedLanguage,
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
            audioURL: managedRecordingReference(
                for: messageID,
                preservedRecordingURL: completedCapture.preservedRecordingURL
            ),
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

        cancelImmersivePreviewTranslation()
        let messageID = completedCapture.liveSpeechSession.record.message.id
        let sourceSegments = resolvedFinalImmersiveSourceSegments(
            transcript: completedCapture.transcript,
            sourceLanguage: completedCapture.sourceLanguage
        )

        sessionRepository.finalizeLiveSpeechTranscript(
            completedCapture.liveSpeechSession.record,
            transcript: completedCapture.transcript,
            sourceLanguage: completedCapture.sourceLanguage,
            audioURL: managedRecordingReference(
                for: messageID,
                preservedRecordingURL: completedCapture.preservedRecordingURL
            ),
            in: runtime
        )

        self.liveSpeechSession = nil
        activeCaptureOrigin = nil
        beginImmersiveFinalConversationStreaming(
            messageID: messageID,
            sourceText: completedCapture.transcript
        )
        defer {
            store.streamingStatesByMessageID.removeValue(forKey: messageID)
        }
        store.immersiveVoiceTranslationState = nil

        do {
            if let prompt = try await downloadWorkflow.translationDownloadPrompt(
                source: completedCapture.sourceLanguage,
                target: completedCapture.targetLanguage
            ) {
                sessionRepository.updateTranslatedMessage(
                    id: messageID,
                    text: TranslationError.modelNotInstalled(
                        source: completedCapture.sourceLanguage,
                        target: completedCapture.targetLanguage
                    ).userFacingMessage,
                    in: runtime
                )
                resetImmersiveTranslationRuntime(clearPresentation: false)
                downloadWorkflow.presentTranslationDownloadPrompt(prompt)
                store.speechErrorMessage = nil
                return
            }
        } catch {
            // Fall through to the final translation attempt and surface its failure in-session.
        }

        let translatedSegments: [String]
        do {
            translatedSegments = try await streamImmersiveFinalTranslations(
                messageID: messageID,
                sourceSegments: sourceSegments,
                sourceLanguage: completedCapture.sourceLanguage,
                targetLanguage: completedCapture.targetLanguage
            )
        } catch let error as TranslationError {
            translatedSegments = [error.userFacingMessage]
        } catch {
            translatedSegments = ["翻译失败了，请稍后再试。"]
        }

        sessionRepository.updateTranslatedMessage(
            id: messageID,
            text: joinedImmersiveSubtitleSegments(
                translatedSegments,
                targetLanguage: completedCapture.targetLanguage
            ),
            in: runtime
        )

        resetImmersiveTranslationRuntime(clearPresentation: false)
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
        case .state(let rawState), .completed(let rawState):
            let previousState = liveSpeechSession.latestState
            var updatedSession = liveSpeechSession
            let state = normalizedSpeechState(
                rawState,
                for: updatedSession.record,
                in: runtime
            )
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
        immersivePendingPreviewState = state
        immersivePendingPreviewRuntime = runtime

        refreshImmersiveVoiceTranslationState(
            phase: immersiveCommittedTranslatedSegments.isEmpty &&
                immersiveActiveTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .listening
                : .translating
        )

        guard immersivePreviewRefreshTask == nil else {
            return
        }

        immersivePreviewRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.immersivePreviewRefreshTask = nil
            }

            while let pendingState = self.immersivePendingPreviewState,
                  let pendingRuntime = self.immersivePendingPreviewRuntime {
                self.immersivePendingPreviewState = nil
                self.immersivePendingPreviewRuntime = nil
                await self.refreshImmersiveTranslationPreview(for: pendingState, in: pendingRuntime)
            }
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

        let sourceLanguageDidChange = immersivePreviewSourceLanguage != detectedLanguage
        if sourceLanguageDidChange {
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
        }

        guard let segmentation = resolvedImmersivePreviewSegmentation(
            stableTranscript: stableTranscript,
            sourceLanguage: detectedLanguage,
            flushActiveText: state.isEndpoint
        ) else {
            return
        }

        let hasNewCommittedSegments = segmentation.committedSegments.count > immersiveCommittedSourceSegments.count
        let activeTextDidChange = segmentation.activeText != immersiveActiveSourceText
        guard hasNewCommittedSegments || activeTextDidChange || sourceLanguageDidChange else {
            return
        }

        let requestGeneration = immersivePreviewGeneration + 1
        immersivePreviewGeneration = requestGeneration
        cancelImmersivePreviewTranslation()

        let previousActiveSourceText = immersiveActiveSourceText
        let previousActiveTranslatedText = immersiveActiveTranslatedText
        let newlyCommittedSourceSegments = Array(
            segmentation.committedSegments.dropFirst(immersiveCommittedSourceSegments.count)
        )

        for (index, sourceSegment) in newlyCommittedSourceSegments.enumerated() {
            guard activeCaptureOrigin == .immersiveWave,
                  requestGeneration == immersivePreviewGeneration else {
                return
            }

            if index == 0,
               sourceSegment == previousActiveSourceText,
               !previousActiveTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                immersiveCommittedTranslatedSegments.append(
                    HomeImmersiveVoiceTranslationSegment(text: previousActiveTranslatedText)
                )
                continue
            }

            let translatedText: String
            do {
                translatedText = try await streamImmersiveTranslation(
                    messageID: UUID(),
                    transcript: sourceSegment,
                    sourceLanguage: detectedLanguage,
                    targetLanguage: liveSpeechSession.record.targetLanguage
                ) { [weak self] partialText in
                    guard let self,
                          self.activeCaptureOrigin == .immersiveWave,
                          requestGeneration == self.immersivePreviewGeneration else {
                        return
                    }

                    self.immersiveActiveTranslatedText = partialText
                    self.refreshImmersiveVoiceTranslationState(phase: .translating)
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard activeCaptureOrigin == .immersiveWave,
                  requestGeneration == immersivePreviewGeneration else {
                return
            }

            immersiveCommittedTranslatedSegments.append(
                HomeImmersiveVoiceTranslationSegment(text: translatedText)
            )
        }

        immersiveCommittedSourceSegments = segmentation.committedSegments
        immersiveActiveSourceText = segmentation.activeText
        immersiveActiveTranslatedText = ""

        guard !segmentation.activeText.isEmpty else {
            refreshImmersiveVoiceTranslationState(
                phase: immersiveCommittedTranslatedSegments.isEmpty ? .listening : .translating
            )
            return
        }

        refreshImmersiveVoiceTranslationState(phase: .translating)
        startImmersivePreviewTranslation(
            transcript: segmentation.activeText,
            sourceLanguage: detectedLanguage,
            targetLanguage: liveSpeechSession.record.targetLanguage,
            requestGeneration: requestGeneration
        )
    }

    private func startImmersivePreviewTranslation(
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        requestGeneration: Int
    ) {
        let taskID = UUID()
        immersivePreviewTaskID = taskID
        refreshImmersiveVoiceTranslationState(phase: .translating)

        immersivePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let translatedText = try await self.streamImmersiveTranslation(
                    messageID: taskID,
                    transcript: transcript,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                ) { [weak self] partialText in
                    guard let self,
                          self.activeCaptureOrigin == .immersiveWave,
                          requestGeneration == self.immersivePreviewGeneration else {
                        return
                    }

                    self.immersiveActiveTranslatedText = partialText
                    self.refreshImmersiveVoiceTranslationState(phase: .translating)
                }

                guard self.activeCaptureOrigin == .immersiveWave,
                      requestGeneration == self.immersivePreviewGeneration else {
                    return
                }

                self.immersiveActiveTranslatedText = translatedText
                self.refreshImmersiveVoiceTranslationState(phase: .translating)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func streamImmersiveFinalTranslations(
        messageID: UUID,
        sourceSegments: [String],
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) async throws -> [String] {
        let normalizedSourceSegments = sourceSegments.compactMap { segment in
            let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedSegment.isEmpty ? nil : normalizedSegment
        }

        guard !normalizedSourceSegments.isEmpty else {
            throw TranslationError.emptyOutput
        }

        immersiveCommittedTranslatedSegments = []
        immersiveActiveTranslatedText = ""
        refreshImmersiveVoiceTranslationState(phase: .finalizing)

        var translatedSegments: [String] = []

        defer {
            immersiveFinalTranslationTaskID = nil
        }

        for sourceSegment in normalizedSourceSegments {
            let taskID = UUID()
            immersiveFinalTranslationTaskID = taskID
            let committedSegments = translatedSegments

            let translatedText = try await streamImmersiveTranslation(
                messageID: taskID,
                transcript: sourceSegment,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ) { [weak self] partialText in
                guard let self else { return }

                self.immersiveActiveTranslatedText = partialText
                self.refreshImmersiveVoiceTranslationState(phase: .finalizing)
                self.updateImmersiveFinalConversationStreaming(
                    messageID: messageID,
                    committedSegments: committedSegments,
                    activeText: partialText,
                    targetLanguage: targetLanguage,
                    phase: .typing
                )
            }

            translatedSegments.append(translatedText)
            immersiveCommittedTranslatedSegments.append(
                HomeImmersiveVoiceTranslationSegment(text: translatedText)
            )
            immersiveActiveTranslatedText = ""
            refreshImmersiveVoiceTranslationState(phase: .finalizing)
            updateImmersiveFinalConversationStreaming(
                messageID: messageID,
                committedSegments: translatedSegments,
                activeText: nil,
                targetLanguage: targetLanguage,
                phase: .typing
            )
        }

        return translatedSegments
    }

    private func beginImmersiveFinalConversationStreaming(
        messageID: UUID,
        sourceText: String
    ) {
        guard let store else { return }

        store.streamingStatesByMessageID[messageID] = ExchangeStreamingState(
            messageID: messageID,
            sourceStableText: sourceText,
            sourceProvisionalText: "",
            sourceLiveText: "",
            sourcePhase: .completed,
            sourceRevision: 0,
            translatedCommittedText: "",
            translatedLiveText: nil,
            translationPhase: .translating,
            translationRevision: 0
        )
    }

    private func updateImmersiveFinalConversationStreaming(
        messageID: UUID,
        committedSegments: [String],
        activeText: String?,
        targetLanguage: SupportedLanguage,
        phase: MessagePhase
    ) {
        guard let store,
              var state = store.streamingStatesByMessageID[messageID] else {
            return
        }

        let committedText = joinedImmersiveSubtitleSegments(
            committedSegments,
            targetLanguage: targetLanguage
        )
        let normalizedActiveText = activeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleActiveText: String?
        if let normalizedActiveText, !normalizedActiveText.isEmpty {
            visibleActiveText = joinedImmersiveSubtitleSegments(
                committedSegments + [normalizedActiveText],
                targetLanguage: targetLanguage
            )
        } else {
            visibleActiveText = nil
        }

        let previousDisplayText = state.translatedDisplayText
        state.translatedCommittedText = committedText
        state.translatedLiveText = visibleActiveText
        state.translationPhase = phase

        if previousDisplayText != state.translatedDisplayText {
            state.translationRevision += 1
        }

        store.streamingStatesByMessageID[messageID] = state
    }

    private func streamImmersiveTranslation(
        messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        onUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let stream = conversationStreamingCoordinator.startSpeechTranslation(
            messageID: messageID,
            text: transcript,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        var completedText: String?
        var latestDisplayText = ""

        for try await event in stream {
            switch event {
            case .state(let state):
                let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayText.isEmpty {
                    latestDisplayText = state.displayText
                    onUpdate(state.displayText)
                }
            case .completed(_, let text):
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedText.isEmpty {
                    latestDisplayText = text
                    onUpdate(text)
                }
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

    private func joinedImmersiveSubtitleSegments(
        _ segments: [String],
        targetLanguage: SupportedLanguage
    ) -> String {
        let normalizedSegments = segments.compactMap { segment in
            let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedSegment.isEmpty ? nil : normalizedSegment
        }

        guard !normalizedSegments.isEmpty else {
            return ""
        }

        return normalizedSegments.joined(
            separator: immersiveSegmentSeparator(for: targetLanguage)
        )
    }

    private func resolvedImmersivePreviewSegmentation(
        stableTranscript: String,
        sourceLanguage: SupportedLanguage,
        flushActiveText: Bool
    ) -> HomeImmersiveSubtitleSegmentationResult? {
        let normalizedTranscript = stableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            return nil
        }

        let fullSegmentation = HomeImmersiveSubtitleSegmenter.segment(
            text: normalizedTranscript,
            flushActiveText: flushActiveText
        )
        if immersiveCommittedSourceSegments.isEmpty ||
            fullSegmentation.committedSegments.starts(with: immersiveCommittedSourceSegments) {
            return fullSegmentation
        }

        guard let tailTranscript = immersiveTranscriptTail(
            from: normalizedTranscript,
            sourceLanguage: sourceLanguage
        ) else {
            return nil
        }

        guard !tailTranscript.isEmpty else {
            return HomeImmersiveSubtitleSegmentationResult(
                committedSegments: immersiveCommittedSourceSegments,
                activeText: ""
            )
        }

        let tailSegmentation = HomeImmersiveSubtitleSegmenter.segment(
            text: tailTranscript,
            flushActiveText: flushActiveText
        )
        return HomeImmersiveSubtitleSegmentationResult(
            committedSegments: immersiveCommittedSourceSegments + tailSegmentation.committedSegments,
            activeText: tailSegmentation.activeText
        )
    }

    private func resolvedFinalImmersiveSourceSegments(
        transcript: String,
        sourceLanguage: SupportedLanguage
    ) -> [String] {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            return []
        }

        guard !immersiveCommittedSourceSegments.isEmpty else {
            return HomeImmersiveSubtitleSegmenter.segment(
                text: normalizedTranscript,
                flushActiveText: true
            ).committedSegments
        }

        guard let tailTranscript = immersiveTranscriptTail(
            from: normalizedTranscript,
            sourceLanguage: sourceLanguage
        ) else {
            // The final transcript doesn't start with the streaming-accumulated prefix,
            // meaning Whisper compressed or rewrote the audio differently.
            // Choose whichever result carries more content.
            let streamingText = joinedImmersiveSourceSegments(
                immersiveCommittedSourceSegments,
                sourceLanguage: sourceLanguage
            )
            if normalizedTranscript.count > streamingText.count {
                // Batch result is longer — Whisper captured more; re-segment from scratch.
                return HomeImmersiveSubtitleSegmenter.segment(
                    text: normalizedTranscript,
                    flushActiveText: true
                ).committedSegments
            }
            // Batch result is shorter (compressed) — trust the streaming accumulation.
            return immersiveCommittedSourceSegments
        }

        guard !tailTranscript.isEmpty else {
            return immersiveCommittedSourceSegments
        }

        let tailSegmentation = HomeImmersiveSubtitleSegmenter.segment(
            text: tailTranscript,
            flushActiveText: true
        )
        return immersiveCommittedSourceSegments + tailSegmentation.committedSegments
    }

    private func immersiveTranscriptTail(
        from transcript: String,
        sourceLanguage: SupportedLanguage
    ) -> String? {
        let committedPrefix = joinedImmersiveSourceSegments(
            immersiveCommittedSourceSegments,
            sourceLanguage: sourceLanguage
        )
        guard !committedPrefix.isEmpty else {
            return transcript
        }

        guard transcript.hasPrefix(committedPrefix) else {
            return nil
        }

        let tailStartIndex = transcript.index(
            transcript.startIndex,
            offsetBy: committedPrefix.count
        )
        let tail = String(transcript[tailStartIndex...])
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinedImmersiveSourceSegments(
        _ segments: [String],
        sourceLanguage: SupportedLanguage
    ) -> String {
        let normalizedSegments = segments.compactMap { segment in
            let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedSegment.isEmpty ? nil : normalizedSegment
        }

        guard !normalizedSegments.isEmpty else {
            return ""
        }

        return normalizedSegments.joined(
            separator: immersiveSegmentSeparator(for: sourceLanguage)
        )
    }

    private func immersiveSegmentSeparator(
        for language: SupportedLanguage
    ) -> String {
        switch language {
        case .chinese, .japanese:
            return ""
        case .english, .korean, .french, .german, .russian, .spanish, .italian:
            return " "
        }
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

    private func refreshImmersiveVoiceTranslationState(
        phase: HomeImmersiveVoiceTranslationPhase
    ) {
        updateImmersiveVoiceTranslationState(
            committedSegments: immersiveCommittedTranslatedSegments,
            activeText: immersiveActiveTranslatedText,
            phase: phase
        )
    }

    private func updateImmersiveVoiceTranslationState(
        committedSegments: [HomeImmersiveVoiceTranslationSegment],
        activeText: String,
        phase: HomeImmersiveVoiceTranslationPhase
    ) {
        guard let store else { return }

        guard var state = store.immersiveVoiceTranslationState else {
            if let liveSpeechSession {
                store.immersiveVoiceTranslationState = HomeImmersiveVoiceTranslationState(
                    messageID: liveSpeechSession.record.message.id,
                    committedSegments: committedSegments,
                    activeText: activeText,
                    phase: phase
                )
            }
            return
        }

        state.committedSegments = committedSegments
        state.activeText = activeText
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

    private func normalizedSpeechState(
        _ rawState: LiveUtteranceState,
        for liveSpeechSession: HomeLiveSpeechSessionRecord,
        in runtime: HomeRuntimeContext
    ) -> LiveUtteranceState {
        var state = rawState

        if let lockedSpeechSourceLanguage {
            state.detectedLanguage = lockedSpeechSourceLanguage
            return state
        }

        guard let detectedLanguage = rawState.detectedLanguage else {
            return state
        }

        lockedSpeechSourceLanguage = detectedLanguage
        state.detectedLanguage = detectedLanguage
        applyDetectedSpeechSourceLanguage(
            detectedLanguage,
            for: liveSpeechSession,
            in: runtime
        )
        return state
    }

    private func applyDetectedSpeechSourceLanguage(
        _ sourceLanguage: SupportedLanguage,
        for liveSpeechSession: HomeLiveSpeechSessionRecord,
        in runtime: HomeRuntimeContext
    ) {
        store?.sourceLanguage = sourceLanguage
        _ = sessionRepository.updateMessage(
            id: liveSpeechSession.message.id,
            sourceLanguage: sourceLanguage,
            syncSessionLanguages: true,
            in: runtime
        )
    }

    private func resolvedSpeechSourceLanguage(
        detectedLanguageCode: String?,
        liveDetectedLanguage: SupportedLanguage?,
        fallbackSourceLanguage: SupportedLanguage
    ) -> SupportedLanguage {
        if let liveDetectedLanguage {
            return liveDetectedLanguage
        }

        if let detectedLanguage = SupportedLanguage.fromWhisperLanguageCode(detectedLanguageCode) {
            return detectedLanguage
        }

        return fallbackSourceLanguage
    }

    private func resetImmersiveTranslationRuntime(clearPresentation: Bool) {
        cancelImmersivePreviewRefresh()
        cancelImmersivePreviewTranslation()

        if let finalTaskID = immersiveFinalTranslationTaskID {
            Task {
                await conversationStreamingCoordinator.cancel(messageID: finalTaskID)
            }
        }

        immersiveFinalTranslationTaskID = nil
        lockedSpeechSourceLanguage = nil
        immersivePreviewGeneration = 0
        immersivePreviewSourceLanguage = nil
        immersiveCommittedSourceSegments = []
        immersiveCommittedTranslatedSegments = []
        immersiveActiveSourceText = ""
        immersiveActiveTranslatedText = ""

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

    private func cancelImmersivePreviewRefresh() {
        immersivePreviewRefreshTask?.cancel()
        immersivePreviewRefreshTask = nil
        immersivePendingPreviewState = nil
        immersivePendingPreviewRuntime = nil
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

    private func managedRecordingReference(
        for messageID: UUID,
        preservedRecordingURL: URL?
    ) -> String? {
        guard let preservedRecordingURL else {
            return nil
        }

        let pathExtension = preservedRecordingURL.pathExtension.isEmpty
            ? "caf"
            : preservedRecordingURL.pathExtension
        return SpeechRecordingStoragePaths.recordingRelativePath(
            for: messageID,
            pathExtension: pathExtension
        )
    }
}
