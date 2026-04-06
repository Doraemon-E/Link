//
//  HomeViewModel.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import AVFoundation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HomeViewModel {
    enum SessionPresentation: Equatable {
        case none
        case draft
        case persisted(UUID)
    }

    private struct LiveSpeechSession {
        let session: ChatSession
        let message: ChatMessage
        let fallbackSourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
        var latestState: LiveUtteranceState = .init()
        var liveTask: Task<Void, Never>?
    }

    var sourceLanguage: SupportedLanguage = .chinese
    var selectedLanguage: SupportedLanguage {
        didSet {
            guard appSettings.selectedTargetLanguage != selectedLanguage else { return }
            appSettings.selectedTargetLanguage = selectedLanguage
        }
    }
    var isLanguageSheetPresented = false
    var isSessionHistoryPresented = false
    var isDownloadManagerPresented = false
    var messageText = ""
    var isChatInputFocused = false
    var sessionPresentation: SessionPresentation = .none
    var downloadableLanguagePrompt: HomeLanguageDownloadPrompt?
    var deferredDownloadPrompt: HomeLanguageDownloadPrompt?
    var activeDownloadPrompt: HomeLanguageDownloadPrompt?
    var downloadErrorMessage: String?
    var isRecordingSpeech = false
    var isTranscribingSpeech = false
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt?
    var speechErrorMessage: String?
    var ttsErrorMessage: String?
    var pendingVoiceStartAfterInstall = false
    var lastSpeechRecordingURL: URL?
    var isPlayingLastSpeechRecording = false
    var speakingMessageID: UUID?
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] = [:]
    var assetRecords: [ModelAssetRecord] = []
    var assetSummary: ModelAssetSummary = .empty
    var speechResumeRequestToken = 0

    @ObservationIgnored private let translationService: TranslationService
    @ObservationIgnored private let speechRecognitionService: SpeechRecognitionService
    @ObservationIgnored private let textToSpeechService: TextToSpeechService
    @ObservationIgnored private let speechPackageManager: SpeechModelPackageManager
    @ObservationIgnored private let translationAssetReadinessProvider: any TranslationAssetReadinessProviding
    @ObservationIgnored private let modelAssetService: ModelAssetService
    @ObservationIgnored private let microphoneRecordingService: MicrophoneRecordingService
    @ObservationIgnored private let conversationStreamingCoordinator: LocalConversationStreamingCoordinator
    @ObservationIgnored private let appSettings: AppSettings
    @ObservationIgnored private var autoStopSpeechTask: Task<Void, Never>?
    @ObservationIgnored private var speechPreviewPlayer: AVAudioPlayer?
    @ObservationIgnored private var speechPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var translationTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadObservationTask: Task<Void, Never>?
    @ObservationIgnored private var downloadMilestoneSignature = ""
    @ObservationIgnored private var pendingSpeechResumePackageID: String?
    @ObservationIgnored private var liveSpeechSession: LiveSpeechSession?
    @ObservationIgnored private var requestedTextToSpeechMessageID: UUID?

    private enum TranslationRequestOrigin {
        case manual
        case speech
    }

    init(
        appSettings: AppSettings,
        translationService: TranslationService,
        speechRecognitionService: SpeechRecognitionService,
        textToSpeechService: TextToSpeechService,
        speechPackageManager: SpeechModelPackageManager,
        translationAssetReadinessProvider: any TranslationAssetReadinessProviding,
        modelAssetService: ModelAssetService,
        microphoneRecordingService: MicrophoneRecordingService
    ) {
        self.appSettings = appSettings
        self.translationService = translationService
        self.speechRecognitionService = speechRecognitionService
        self.textToSpeechService = textToSpeechService
        self.speechPackageManager = speechPackageManager
        self.translationAssetReadinessProvider = translationAssetReadinessProvider
        self.modelAssetService = modelAssetService
        self.microphoneRecordingService = microphoneRecordingService
        self.conversationStreamingCoordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            translationAssetReadinessProvider: translationAssetReadinessProvider,
            speechStreamingService: speechRecognitionService as? any SpeechRecognitionStreamingService
        )
        self.selectedLanguage = appSettings.selectedTargetLanguage
        self.textToSpeechService.playbackEventHandler = { [weak self] event in
            self?.handleTextToSpeechPlaybackEvent(event)
        }
        startObservingDownloads()
    }

    func onAppear(using modelContext: ModelContext, sessions: [ChatSession]) {
        if selectedLanguage != appSettings.selectedTargetLanguage {
            selectedLanguage = appSettings.selectedTargetLanguage
        }
        removeEmptySessions(using: modelContext, sessions: sessions)
        Task {
            await modelAssetService.warmUp()
        }
    }

    func displayedMessages(in sessions: [ChatSession]) -> [ChatMessage] {
        guard !isDraftSession else { return [] }
        return currentSession(in: sessions)?.sortedMessages ?? []
    }

    func displayedMessageIDs(in sessions: [ChatSession]) -> [UUID] {
        displayedMessages(in: sessions).map(\.id)
    }

    func displayedMessageRenderKeys(in sessions: [ChatSession]) -> [String] {
        displayedMessages(in: sessions).map { message in
            let streamingState = streamingStatesByMessageID[message.id]
            let sourceRevision = streamingState?.sourceRevision ?? 0
            let translationRevision = streamingState?.translationRevision ?? 0
            let sourceText = streamingState?.sourceDisplayText ?? message.sourceText
            let translatedText = streamingState?.translatedDisplayText ?? message.translatedText
            let translationStatus = streamingState?.translationStatusText ?? ""
            return "\(message.id.uuidString)-\(sourceRevision)-\(translationRevision)-\(translationStatus)-\(sourceText)-\(translatedText)"
        }
    }

    func streamingState(for message: ChatMessage) -> ExchangeStreamingState? {
        streamingStatesByMessageID[message.id]
    }

    func shouldShowSessionHistoryButton(in sessions: [ChatSession]) -> Bool {
        latestNonEmptySession(in: sessions) != nil
    }

    func shouldShowNewSessionButton(in sessions: [ChatSession]) -> Bool {
        !isDraftSession && currentSession(in: sessions) != nil
    }

    func shouldShowLanguagePickerHero(in sessions: [ChatSession]) -> Bool {
        !isChatInputFocused && currentSession(in: sessions) == nil
    }

    func currentSessionID(in sessions: [ChatSession]) -> UUID? {
        currentSession(in: sessions)?.id
    }

    func handleInputFocusActivated() {
        guard case .none = sessionPresentation else { return }
        sessionPresentation = .draft
    }

    func openSessionHistory() {
        isChatInputFocused = false
        isSessionHistoryPresented = true
    }

    func startNewSession() {
        guard !isDraftSession else { return }
        stopMessageSpeechPlayback()
        sessionPresentation = .draft
    }

    func selectSession(id sessionID: UUID) {
        stopMessageSpeechPlayback()
        sessionPresentation = .persisted(sessionID)
        isChatInputFocused = false

        DispatchQueue.main.async {
            self.isSessionHistoryPresented = false
        }
    }

    func sendCurrentMessage(using modelContext: ModelContext, sessions: [ChatSession]) {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !isRecordingSpeech, !isTranscribingSpeech, !isInstallingSpeechModel else {
            return
        }

        let source = sourceLanguage
        let target = selectedLanguage

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let prompt = await self.downloadPromptIfNeeded(source: source, target: target) {
                self.presentTranslationDownloadPrompt(prompt)
                return
            }

            self.submitMessage(
                text: trimmedText,
                sourceLanguage: source,
                targetLanguage: target,
                audioURL: nil,
                translationOrigin: .manual,
                using: modelContext,
                sessions: sessions,
                clearInput: true
            )
        }
    }

    func resolveLanguageSelection(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> HomeLanguageSelectionResolution {
        do {
            let requirement = try await translationDownloadRequirement(
                source: source,
                target: target
            )

            if requirement.isReady {
                return .ready
            }

            return .requiresDownload(
                HomeLanguageDownloadPrompt(
                    sourceLanguage: source,
                    targetLanguage: target,
                    requirement: requirement
                )
            )
        } catch let error as TranslationError {
            return .failure(error.userFacingMessage)
        } catch {
            return .failure("暂时无法检查翻译模型，请稍后再试。")
        }
    }

    func commitLanguageSelection(source: SupportedLanguage, target: SupportedLanguage) {
        sourceLanguage = source
        selectedLanguage = target
        downloadableLanguagePrompt = nil
        deferredDownloadPrompt = nil
        activeDownloadPrompt = nil
    }

    func commitLanguageSelectionRequiringDownload(
        source: SupportedLanguage,
        target: SupportedLanguage,
        prompt: HomeLanguageDownloadPrompt
    ) {
        sourceLanguage = source
        selectedLanguage = target
        downloadableLanguagePrompt = prompt
        deferredDownloadPrompt = prompt
        activeDownloadPrompt = nil
    }

    func presentDeferredDownloadPromptIfNeeded() {
        guard !isLanguageSheetPresented, let deferredDownloadPrompt else { return }

        activeDownloadPrompt = deferredDownloadPrompt
        self.deferredDownloadPrompt = nil
    }

    func openDownloadManager() {
        isDownloadManagerPresented = true
    }

    func presentDownloadPrompt() {
        guard let downloadableLanguagePrompt else {
            openDownloadManager()
            return
        }

        activeDownloadPrompt = downloadableLanguagePrompt
    }

    func dismissDownloadPrompt() {
        activeDownloadPrompt = nil
    }

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt) {
        downloadableLanguagePrompt = prompt
        deferredDownloadPrompt = nil
        activeDownloadPrompt = prompt
    }

    func dismissSpeechDownloadPrompt() {
        activeSpeechDownloadPrompt = nil
        pendingVoiceStartAfterInstall = false
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
        let source = sourceLanguage
        let target = selectedLanguage
        let prompt = await downloadPromptIfNeeded(source: source, target: target)

        guard source == sourceLanguage, target == selectedLanguage else {
            return
        }

        downloadableLanguagePrompt = prompt

        if prompt == nil {
            deferredDownloadPrompt = nil
            activeDownloadPrompt = nil
        }
    }

    func installTranslationModel(packageIds: [String]) async {
        guard !packageIds.isEmpty else { return }

        downloadErrorMessage = nil
        activeDownloadPrompt = nil
        isDownloadManagerPresented = true
        await modelAssetService.startAssets(kind: .translation, packageIDs: packageIds)
        await refreshDownloadAvailabilityForCurrentSelection()
    }

    func toggleSpeechRecording(using modelContext: ModelContext, sessions: [ChatSession]) async {
        guard !isTranscribingSpeech, !isInstallingSpeechModel else {
            return
        }

        if isRecordingSpeech {
            await stopSpeechRecordingAndTranslate(using: modelContext, sessions: sessions)
            return
        }

        do {
            if let prompt = try await speechDownloadPromptIfNeeded() {
                activeSpeechDownloadPrompt = prompt
                pendingVoiceStartAfterInstall = true
                return
            }

            await startSpeechRecording(using: modelContext, sessions: sessions)
        } catch let error as SpeechRecognitionError {
            speechErrorMessage = error.userFacingMessage
        } catch {
            speechErrorMessage = "语音识别暂时不可用，请稍后再试。"
        }
    }

    func shouldShowMessageSpeechButton(for message: ChatMessage) -> Bool {
        guard streamingState(for: message)?.isTranslationActive != true else {
            return false
        }

        return !(message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func isMessageSpeechPlaybackDisabled(for message: ChatMessage) -> Bool {
        guard shouldShowMessageSpeechButton(for: message) else {
            return true
        }

        return isRecordingSpeech || isTranscribingSpeech
    }

    func isSpeakingMessage(_ message: ChatMessage) -> Bool {
        speakingMessageID == message.id
    }

    func toggleMessageSpeechPlayback(message: ChatMessage) {
        guard shouldShowMessageSpeechButton(for: message) else {
            return
        }

        if speakingMessageID == message.id {
            stopMessageSpeechPlayback()
            return
        }

        guard let language = playbackLanguage(for: message) else {
            ttsErrorMessage = "无法确定这条消息的朗读语言。"
            return
        }

        stopLastSpeechRecordingPlayback()
        if speakingMessageID != nil {
            textToSpeechService.stop()
        }

        let messageID = message.id
        let text = message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedTextToSpeechMessageID = messageID
        speakingMessageID = messageID
        ttsErrorMessage = nil

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
                if self.requestedTextToSpeechMessageID == messageID {
                    self.requestedTextToSpeechMessageID = nil
                }
                if self.speakingMessageID == messageID {
                    self.speakingMessageID = nil
                }
                self.ttsErrorMessage = error.userFacingMessage
            } catch {
                if self.requestedTextToSpeechMessageID == messageID {
                    self.requestedTextToSpeechMessageID = nil
                }
                if self.speakingMessageID == messageID {
                    self.speakingMessageID = nil
                }
                self.ttsErrorMessage = "语音播放失败，请稍后再试。"
            }
        }
    }

    func startSpeechRecording(using modelContext: ModelContext, sessions: [ChatSession]) async {
        guard !isRecordingSpeech, !isTranscribingSpeech, !isInstallingSpeechModel else {
            return
        }

        prepareForSpeechRecording()

        do {
            let audioStream = try await microphoneRecordingService.startStreamingRecording()
            let liveSession = insertLiveSpeechConversationExchange(
                sourceLanguage: sourceLanguage,
                targetLanguage: selectedLanguage,
                using: modelContext,
                sessions: sessions
            )
            liveSpeechSession = liveSession
            applyLiveSpeechState(LiveUtteranceState(), to: liveSession)
            startLiveSpeechStreaming(audioStream: audioStream)
            isRecordingSpeech = true
            isChatInputFocused = false
            scheduleAutoStopSpeechTask(using: modelContext, sessions: sessions)
        } catch let error as SpeechRecognitionError {
            cleanupLiveSpeechSessionIfNeeded(using: modelContext)
            speechErrorMessage = error.userFacingMessage
        } catch {
            cleanupLiveSpeechSessionIfNeeded(using: modelContext)
            speechErrorMessage = "无法开始录音，请稍后重试。"
        }
    }

    func stopSpeechRecordingAndTranslate(using modelContext: ModelContext, sessions: [ChatSession]) async {
        guard isRecordingSpeech else { return }

        autoStopSpeechTask?.cancel()
        autoStopSpeechTask = nil
        isRecordingSpeech = false
        isTranscribingSpeech = true
        speechErrorMessage = nil

        defer {
            isTranscribingSpeech = false
        }

        do {
            guard let liveSession = liveSpeechSession else {
                throw SpeechRecognitionError.recordingNotActive
            }

            let recordingResult = try await microphoneRecordingService.stopRecording()
            lastSpeechRecordingURL = recordingResult.preservedRecordingURL
            if let liveTask = liveSpeechSession?.liveTask {
                await liveTask.value
            }

            let recognitionResult = try await speechRecognitionService.transcribe(samples: recordingResult.samples)
            let transcribedText = recognitionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcribedText.isEmpty else {
                throw SpeechRecognitionError.emptyTranscription
            }

            let effectiveSourceLanguage = try await resolvedSpeechSourceLanguage(
                detectedLanguageCode: recognitionResult.detectedLanguage,
                fallbackSourceLanguage: liveSession.fallbackSourceLanguage,
                targetLanguage: liveSession.targetLanguage
            )
            if let prompt = try await translationDownloadPrompt(
                source: effectiveSourceLanguage,
                target: liveSession.targetLanguage
            ) {
                presentTranslationDownloadPrompt(prompt)
                finalizeLiveSpeechSession(
                    transcript: transcribedText,
                    translatedText: TranslationError.modelNotInstalled(
                        source: effectiveSourceLanguage,
                        target: liveSession.targetLanguage
                    ).userFacingMessage,
                    sourceLanguage: effectiveSourceLanguage,
                    audioURL: recordingResult.preservedRecordingURL?.absoluteString,
                    using: modelContext
                )
                return
            }

            let translatedText = try await translationService.translate(
                text: transcribedText,
                source: effectiveSourceLanguage,
                target: liveSession.targetLanguage
            )
            finalizeLiveSpeechSession(
                transcript: transcribedText,
                translatedText: translatedText,
                sourceLanguage: effectiveSourceLanguage,
                audioURL: recordingResult.preservedRecordingURL?.absoluteString,
                using: modelContext
            )
        } catch let error as SpeechRecognitionError {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: error.userFacingMessage,
                using: modelContext
            )
        } catch let error as TranslationError {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: error.userFacingMessage,
                using: modelContext
            )
        } catch {
            microphoneRecordingService.cancelRecording()
            await finalizeLiveSpeechSessionAfterFailure(
                fallbackMessage: "语音识别失败了，请稍后再试。",
                using: modelContext
            )
        }
    }

    func toggleLastSpeechRecordingPlayback() {
        guard let lastSpeechRecordingURL else { return }

        if isPlayingLastSpeechRecording {
            stopLastSpeechRecordingPlayback()
            return
        }

        stopMessageSpeechPlayback()

        do {
            let player = try AVAudioPlayer(contentsOf: lastSpeechRecordingURL)
            player.prepareToPlay()
            player.play()

            speechPreviewPlayer = player
            isPlayingLastSpeechRecording = true

            speechPreviewTask?.cancel()
            let durationNanoseconds = UInt64(max(player.duration, 0) * 1_000_000_000)
            speechPreviewTask = Task { @MainActor [weak self] in
                guard durationNanoseconds > 0 else {
                    self?.isPlayingLastSpeechRecording = false
                    return
                }

                try? await Task.sleep(nanoseconds: durationNanoseconds + 200_000_000)
                guard let self else { return }
                self.isPlayingLastSpeechRecording = self.speechPreviewPlayer?.isPlaying == true
                if !self.isPlayingLastSpeechRecording {
                    self.speechPreviewPlayer = nil
                }
            }
        } catch {
            speechErrorMessage = "无法播放刚才的录音，请稍后再试。"
        }
    }

    func stopLastSpeechRecordingPlayback() {
        speechPreviewTask?.cancel()
        speechPreviewTask = nil
        speechPreviewPlayer?.stop()
        speechPreviewPlayer = nil
        isPlayingLastSpeechRecording = false
    }

    var hasLastSpeechRecording: Bool {
        lastSpeechRecordingURL != nil
    }

    func prepareForSpeechRecording() {
        stopMessageSpeechPlayback()
        stopLastSpeechRecordingPlayback()
        speechErrorMessage = nil
        ttsErrorMessage = nil
        pendingVoiceStartAfterInstall = false
    }

    func installSpeechModelAndResumeIfNeeded(
        packageId: String,
        shouldResumeRecording: Bool
    ) async {
        speechErrorMessage = nil
        activeSpeechDownloadPrompt = nil
        isDownloadManagerPresented = true
        pendingVoiceStartAfterInstall = shouldResumeRecording
        pendingSpeechResumePackageID = packageId
        await modelAssetService.startAssets(kind: .speech, packageIDs: [packageId])
    }

    var shouldShowDownloadToolbarButton: Bool {
        true
    }

    var canStartDownloadFromToolbar: Bool {
        true
    }

    var isInstallingTranslationModel: Bool {
        activeAssetRecords.contains { $0.kind == .translation }
    }

    var isInstallingSpeechModel: Bool {
        activeAssetRecords.contains { $0.kind == .speech }
    }

    var assetManagerHasAttention: Bool {
        assetSummary.hasAttention
    }

    var assetManagerIsBusy: Bool {
        assetSummary.hasActiveTasks
    }

    var activeAssetRecords: [ModelAssetRecord] {
        assetRecords.filter {
            [.preparing, .downloading, .verifying, .installing].contains($0.status.state)
        }
    }

    var processingAssetRecords: [ModelAssetRecord] {
        assetRecords.filter {
            [.preparing, .downloading, .verifying, .installing].contains($0.status.state)
        }
    }

    var resumableAssetRecords: [ModelAssetRecord] {
        assetRecords.filter { $0.status.state == .pausedResumable }
    }

    var failedAssetRecords: [ModelAssetRecord] {
        assetRecords.filter { $0.status.state == .failed }
    }

    var installedAssetRecords: [ModelAssetRecord] {
        assetRecords.filter(\.isInstalled)
    }

    var availableAssetRecords: [ModelAssetRecord] {
        assetRecords.filter {
            !$0.isInstalled && $0.status.state == .idle
        }
    }

    func retryDownload(itemID: String) async {
        await modelAssetService.retry(assetID: itemID)
    }

    func resumeDownload(itemID: String) async {
        await modelAssetService.resume(assetID: itemID)
    }

    func startDownload(item: ModelAssetRecord) async {
        await modelAssetService.startAssets(kind: item.kind, packageIDs: [item.asset.packageId])
    }

    func deleteInstalledDownload(itemID: String) async {
        do {
            try await modelAssetService.removeInstalledAsset(id: itemID)
            await refreshDownloadAvailabilityForCurrentSelection()
        } catch let error as TranslationError {
            downloadErrorMessage = error.userFacingMessage
        } catch let error as SpeechRecognitionError {
            speechErrorMessage = error.userFacingMessage
        } catch {
            downloadErrorMessage = "删除模型失败，请稍后再试。"
        }
    }

    func handlePendingSpeechResumeIfNeeded(
        using modelContext: ModelContext,
        sessions: [ChatSession]
    ) async {
        guard speechResumeRequestToken > 0 else {
            return
        }

        speechResumeRequestToken = 0
        await startSpeechRecording(using: modelContext, sessions: sessions)
    }

    private var isDraftSession: Bool {
        if case .draft = sessionPresentation {
            return true
        }

        return false
    }

    private func currentSession(in sessions: [ChatSession]) -> ChatSession? {
        switch sessionPresentation {
        case .draft:
            return nil
        case .persisted(let sessionID):
            return sessions.first { $0.id == sessionID } ?? latestNonEmptySession(in: sessions)
        case .none:
            return nil
        }
    }

    private func latestNonEmptySession(in sessions: [ChatSession]) -> ChatSession? {
        sessions.first { $0.hasMessages }
    }

    @discardableResult
    private func createNewSession(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        using modelContext: ModelContext
    ) -> ChatSession {
        let session = ChatSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        modelContext.insert(session)
        sessionPresentation = .persisted(session.id)
        return session
    }

    private func removeEmptySessions(using modelContext: ModelContext, sessions: [ChatSession]) {
        let emptySessions = sessions.filter { !$0.hasMessages }

        guard !emptySessions.isEmpty else { return }

        for session in emptySessions {
            modelContext.delete(session)
        }

        if case .persisted(let sessionID) = sessionPresentation,
           emptySessions.contains(where: { $0.id == sessionID }) {
            sessionPresentation = .none
        }

        saveContext(using: modelContext)
    }

    private func startObservingDownloads() {
        guard downloadObservationTask == nil else {
            return
        }

        downloadObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.modelAssetService.snapshotStream()

            for await snapshot in stream {
                self.assetRecords = snapshot.records
                self.assetSummary = snapshot.summary
                self.handleAssetMilestones(for: snapshot)
            }
        }
    }

    private func handleAssetMilestones(for snapshot: ModelAssetSnapshot) {
        let milestoneSignature = snapshot.records
            .map { "\($0.id):\($0.status.state.rawValue):\($0.isInstalled)" }
            .sorted()
            .joined(separator: "|")

        if milestoneSignature != downloadMilestoneSignature {
            downloadMilestoneSignature = milestoneSignature

            Task {
                await refreshDownloadAvailabilityForCurrentSelection()
            }
        }

        guard pendingVoiceStartAfterInstall,
              let packageID = pendingSpeechResumePackageID else {
            return
        }

        let matchingItemID = ModelAsset.makeID(kind: .speech, packageId: packageID)

        if snapshot.records.contains(where: {
            $0.id == matchingItemID && $0.isInstalled
        }) {
            pendingVoiceStartAfterInstall = false
            pendingSpeechResumePackageID = nil
            speechResumeRequestToken += 1
        }

        if snapshot.records.contains(where: {
            $0.id == matchingItemID && $0.status.state == .failed
        }) {
            pendingVoiceStartAfterInstall = false
            pendingSpeechResumePackageID = nil
        }
    }

    private func saveContext(using modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save chat data: \(error)")
        }
    }

    private func stopMessageSpeechPlayback() {
        requestedTextToSpeechMessageID = nil
        speakingMessageID = nil
        textToSpeechService.stop()
    }

    private func playbackLanguage(for message: ChatMessage) -> SupportedLanguage? {
        if let language = message.targetLanguage {
            return language
        }

        return message.session?.targetLanguage ?? selectedLanguage
    }

    private func handleTextToSpeechPlaybackEvent(_ event: TextToSpeechPlaybackEvent) {
        switch event {
        case .started(let messageID):
            guard requestedTextToSpeechMessageID == messageID || speakingMessageID == messageID else {
                return
            }
            speakingMessageID = messageID
        case .finished(let messageID), .cancelled(let messageID):
            if requestedTextToSpeechMessageID == messageID {
                requestedTextToSpeechMessageID = nil
            }
            if speakingMessageID == messageID {
                speakingMessageID = nil
            }
        case .failed(let messageID, let message):
            if requestedTextToSpeechMessageID == messageID {
                requestedTextToSpeechMessageID = nil
            }
            if speakingMessageID == messageID {
                speakingMessageID = nil
            }
            ttsErrorMessage = message
        }
    }

    private func scheduleAutoStopSpeechTask(using modelContext: ModelContext, sessions: [ChatSession]) {
        autoStopSpeechTask?.cancel()
        autoStopSpeechTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }

            guard let self, self.isRecordingSpeech else { return }
            await self.stopSpeechRecordingAndTranslate(using: modelContext, sessions: sessions)
        }
    }

    private func submitMessage(
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        audioURL: String?,
        translationOrigin: TranslationRequestOrigin,
        using modelContext: ModelContext,
        sessions: [ChatSession],
        clearInput: Bool
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let session = resolveSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            using: modelContext,
            sessions: sessions
        )
        let messageID = insertConversationExchange(
            text: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioURL,
            into: session,
            using: modelContext
        )

        if clearInput {
            messageText = ""
        }

        startStreamingTranslation(
            for: messageID,
            originalText: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translationOrigin: translationOrigin,
            using: modelContext
        )
    }

    private func resolveSession(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        using modelContext: ModelContext,
        sessions: [ChatSession]
    ) -> ChatSession {
        switch sessionPresentation {
        case .draft:
            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                using: modelContext
            )
        case .persisted(let sessionID):
            if let existingSession = sessions.first(where: { $0.id == sessionID }) {
                return existingSession
            }

            if let fallbackSession = latestNonEmptySession(in: sessions) {
                sessionPresentation = .persisted(fallbackSession.id)
                return fallbackSession
            }

            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                using: modelContext
            )
        case .none:
            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                using: modelContext
            )
        }
    }

    private func insertConversationExchange(
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        audioURL: String?,
        into session: ChatSession,
        using modelContext: ModelContext
    ) -> UUID {
        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            inputType: .text,
            sourceText: text,
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioURL,
            createdAt: .now,
            sequence: nextSequence,
            session: session
        )

        modelContext.insert(message)
        session.updatedAt = message.createdAt
        saveContext(using: modelContext)

        return message.id
    }

    private func insertLiveSpeechConversationExchange(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        using modelContext: ModelContext,
        sessions: [ChatSession]
    ) -> LiveSpeechSession {
        let session = resolveSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            using: modelContext,
            sessions: sessions
        )
        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            inputType: .speech,
            sourceText: "",
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            createdAt: .now,
            sequence: nextSequence,
            session: session
        )

        modelContext.insert(message)
        session.updatedAt = message.createdAt
        saveContext(using: modelContext)

        return LiveSpeechSession(
            session: session,
            message: message,
            fallbackSourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func startStreamingTranslation(
        for messageID: UUID,
        originalText: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        translationOrigin: TranslationRequestOrigin,
        using modelContext: ModelContext
    ) {
        translationTasksByMessageID[messageID]?.cancel()
        streamingStatesByMessageID[messageID] = ExchangeStreamingState(
            messageID: messageID,
            sourceCommittedText: originalText,
            sourceLiveText: nil,
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
                let stream: AsyncThrowingStream<ConversationStreamingEvent, Error>
                switch translationOrigin {
                case .manual:
                    stream = self.conversationStreamingCoordinator.startManualTranslation(
                        messageID: messageID,
                        text: originalText,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                case .speech:
                    stream = self.conversationStreamingCoordinator.startSpeechTranslation(
                        messageID: messageID,
                        text: originalText,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                }

                for try await event in stream {
                    self.handleStreamingConversationEvent(event, using: modelContext)
                }
            } catch is CancellationError {
                self.streamingStatesByMessageID.removeValue(forKey: messageID)
            } catch let error as TranslationError {
                self.failStreamingTranslation(
                    for: messageID,
                    message: error.userFacingMessage,
                    using: modelContext
                )
            } catch {
                self.failStreamingTranslation(
                    for: messageID,
                    message: "翻译失败了，请稍后再试。",
                    using: modelContext
                )
            }
        }

        translationTasksByMessageID[messageID] = task
    }

    private func startLiveSpeechStreaming(
        audioStream: AsyncStream<[Float]>
    ) {
        guard var liveSpeechSession else {
            return
        }

        liveSpeechSession.liveTask?.cancel()
        let messageID = liveSpeechSession.message.id
        let fallbackSourceLanguage = liveSpeechSession.fallbackSourceLanguage
        let targetLanguage = liveSpeechSession.targetLanguage

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = self.conversationStreamingCoordinator.startLiveSpeechTranslation(
                    messageID: messageID,
                    audioStream: audioStream,
                    sourceLanguage: fallbackSourceLanguage,
                    targetLanguage: targetLanguage
                )

                for try await event in stream {
                    self.handleLiveSpeechTranslationEvent(event)
                }
            } catch is CancellationError {
                return
            } catch let error as SpeechRecognitionError {
                self.speechErrorMessage = error.userFacingMessage
            } catch let error as TranslationError {
                self.speechErrorMessage = error.userFacingMessage
            } catch let error as ConversationStreamingCoordinatorError {
                self.speechErrorMessage = error.localizedDescription
            } catch {
                self.speechErrorMessage = "实时语音翻译暂时不可用，请稍后再试。"
            }
        }

        liveSpeechSession.liveTask = task
        self.liveSpeechSession = liveSpeechSession
    }

    private func handleLiveSpeechTranslationEvent(
        _ event: LiveSpeechTranslationEvent
    ) {
        guard let liveSpeechSession else {
            return
        }

        switch event {
        case .state(let state), .completed(let state):
            var updatedSession = liveSpeechSession
            updatedSession.latestState = state
            self.liveSpeechSession = updatedSession
            applyLiveSpeechState(state, to: updatedSession)
        }
    }

    private func handleStreamingConversationEvent(
        _ event: ConversationStreamingEvent,
        using modelContext: ModelContext
    ) {
        switch event {
        case .state(let state):
            guard var existingState = streamingStatesByMessageID[state.messageID] else {
                return
            }
            existingState.translatedCommittedText = state.committedText
            existingState.translatedLiveText = state.liveText
            existingState.translationPhase = state.phase
            existingState.translationRevision = state.revision
            streamingStatesByMessageID[state.messageID] = existingState
        case .completed(let messageID, let text):
            updateTranslatedMessage(
                id: messageID,
                text: text,
                using: modelContext
            )
            streamingStatesByMessageID.removeValue(forKey: messageID)
        }
    }

    private func failStreamingTranslation(
        for messageID: UUID,
        message: String,
        using modelContext: ModelContext
    ) {
        var state = streamingStatesByMessageID[messageID] ?? ExchangeStreamingState(
            messageID: messageID,
            sourceCommittedText: "",
            sourceLiveText: nil,
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
        streamingStatesByMessageID[messageID] = state

        updateTranslatedMessage(
            id: messageID,
            text: message,
            using: modelContext
        )
        streamingStatesByMessageID.removeValue(forKey: messageID)
    }

    private func updateTranslatedMessage(
        id: UUID,
        text: String,
        using modelContext: ModelContext
    ) {
        let asset = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { message in
                message.id == id
            }
        )

        guard let message = try? modelContext.fetch(asset).first else {
            return
        }

        message.translatedText = text
        message.session?.updatedAt = .now
        saveContext(using: modelContext)
    }

    private func applyLiveSpeechState(
        _ state: LiveUtteranceState,
        to session: LiveSpeechSession
    ) {
        let transcriptText = (state.stableTranscript + state.unstableTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = (state.displayTranslation.isEmpty ? state.stableTranslation : state.displayTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        streamingStatesByMessageID[session.message.id] = ExchangeStreamingState(
            messageID: session.message.id,
            sourceCommittedText: state.stableTranscript,
            sourceLiveText: transcriptText.isEmpty ? nil : transcriptText,
            sourcePhase: .transcribing,
            sourceRevision: state.transcriptRevision,
            translatedCommittedText: state.stableTranslation,
            translatedLiveText: translationText.isEmpty ? nil : translationText,
            translationPhase: translationText.isEmpty ? .translating : .typing,
            translationRevision: state.translationRevision
        )
    }

    private func finalizeLiveSpeechSession(
        transcript: String,
        translatedText: String,
        sourceLanguage: SupportedLanguage,
        audioURL: String?,
        using modelContext: ModelContext
    ) {
        guard let liveSpeechSession else {
            return
        }

        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        liveSpeechSession.message.sourceText = normalizedTranscript
        liveSpeechSession.message.sourceLanguage = sourceLanguage
        liveSpeechSession.message.translatedText = normalizedTranslation
        liveSpeechSession.message.targetLanguage = liveSpeechSession.targetLanguage
        liveSpeechSession.message.audioURL = audioURL
        liveSpeechSession.session.updatedAt = .now

        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.message.id)
        speechErrorMessage = nil
        self.liveSpeechSession = nil
        saveContext(using: modelContext)
    }

    private func cleanupLiveSpeechSessionIfNeeded(using modelContext: ModelContext) {
        guard liveSpeechSession != nil else {
            return
        }

        discardLiveSpeechSession(using: modelContext)
    }

    private func discardLiveSpeechSession(using modelContext: ModelContext) {
        guard let liveSpeechSession else {
            return
        }

        liveSpeechSession.liveTask?.cancel()
        Task {
            await conversationStreamingCoordinator.cancel(messageID: liveSpeechSession.message.id)
        }
        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.message.id)
        modelContext.delete(liveSpeechSession.message)
        let remainingMessages = liveSpeechSession.session.messages.filter {
            $0.id != liveSpeechSession.message.id
        }
        if remainingMessages.isEmpty {
            modelContext.delete(liveSpeechSession.session)
            if case .persisted(let sessionID) = sessionPresentation,
               sessionID == liveSpeechSession.session.id {
                sessionPresentation = .none
            }
        }

        self.liveSpeechSession = nil
        saveContext(using: modelContext)
    }

    private func fallbackTranscriptAndTranslation(
        from state: LiveUtteranceState
    ) -> (transcript: String, translation: String)? {
        let transcript = (state.stableTranscript + state.unstableTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = (state.displayTranslation.isEmpty ? state.stableTranslation : state.displayTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty, !translation.isEmpty else {
            return nil
        }

        return (transcript, translation)
    }

    private func finalizeLiveSpeechSessionAfterFailure(
        fallbackMessage: String,
        using modelContext: ModelContext
    ) async {
        guard let liveSpeechSession else {
            speechErrorMessage = fallbackMessage
            return
        }

        if let liveTask = liveSpeechSession.liveTask {
            await liveTask.value
        }

        if let fallback = fallbackTranscriptAndTranslation(from: liveSpeechSession.latestState) {
            finalizeLiveSpeechSession(
                transcript: fallback.transcript,
                translatedText: fallback.translation,
                sourceLanguage: liveSpeechSession.latestState.detectedLanguage ?? liveSpeechSession.fallbackSourceLanguage,
                audioURL: lastSpeechRecordingURL?.absoluteString,
                using: modelContext
            )
        } else {
            discardLiveSpeechSession(using: modelContext)
            speechErrorMessage = fallbackMessage
        }
    }

    private func resolvedSpeechSourceLanguage(
        detectedLanguageCode: String?,
        fallbackSourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) async throws -> SupportedLanguage {
        if let detectedLanguage = SupportedLanguage.fromWhisperLanguageCode(detectedLanguageCode),
           await isTranslationReady(
               source: detectedLanguage,
               target: targetLanguage
           ) {
            return detectedLanguage
        }

        return fallbackSourceLanguage
    }

    private func translationDownloadRequirement(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> TranslationAssetRequirement {
        let route = try await translationService.route(source: source, target: target)
        return try await translationAssetReadinessProvider.translationAssetRequirement(for: route)
    }

    private func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt? {
        let requirement = try await translationDownloadRequirement(
            source: source,
            target: target
        )
        guard !requirement.isReady else {
            return nil
        }

        return HomeLanguageDownloadPrompt(
            sourceLanguage: source,
            targetLanguage: target,
            requirement: requirement
        )
    }

    private func downloadPromptIfNeeded(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> HomeLanguageDownloadPrompt? {
        do {
            return try await translationDownloadPrompt(source: source, target: target)
        } catch {
            return nil
        }
    }

    private func isTranslationReady(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> Bool {
        do {
            let route = try await translationService.route(source: source, target: target)
            return try await translationAssetReadinessProvider.areTranslationAssetsReady(for: route)
        } catch {
            return false
        }
    }

    private func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt? {
        guard let package = try await speechPackageManager.defaultPackageMetadata() else {
            throw SpeechRecognitionError.modelPackageUnavailable
        }

        if try await speechPackageManager.isDefaultPackageInstalled() {
            return nil
        }

        return SpeechModelDownloadPrompt(package: package)
    }
}
