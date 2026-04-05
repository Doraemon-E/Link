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
        let userMessage: ChatMessage
        let assistantMessage: ChatMessage
        let fallbackSourceLanguage: HomeLanguage
        let targetLanguage: HomeLanguage
        var latestState: LiveUtteranceState = .init()
        var liveTask: Task<Void, Never>?
    }

    var sourceLanguage: HomeLanguage = .chinese
    var selectedLanguage: HomeLanguage {
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
    var streamingStatesByMessageID: [UUID: StreamingMessageState] = [:]
    var downloadManagerItems: [ModelDownloadItem] = []
    var downloadManagerSummary: ModelDownloadManagerSummary = .empty
    var speechResumeRequestToken = 0

    @ObservationIgnored private let translationService: TranslationService
    @ObservationIgnored private let translationModelInstaller: TranslationModelInstaller
    @ObservationIgnored private let speechRecognitionService: SpeechRecognitionService
    @ObservationIgnored private let textToSpeechService: TextToSpeechService
    @ObservationIgnored private let speechModelInstaller: SpeechModelInstaller
    @ObservationIgnored private let modelDownloadCenter: ModelDownloadCenter
    @ObservationIgnored private let microphoneRecordingService: MicrophoneRecordingService
    @ObservationIgnored private let conversationStreamingCoordinator: LocalConversationStreamingCoordinator
    @ObservationIgnored private let appSettings: AppSettings
    @ObservationIgnored private var autoStopSpeechTask: Task<Void, Never>?
    @ObservationIgnored private var speechPreviewPlayer: AVAudioPlayer?
    @ObservationIgnored private var speechPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var translationTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadObservationTask: Task<Void, Never>?
    @ObservationIgnored private var textToSpeechObservationTask: Task<Void, Never>?
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
        translationModelInstaller: TranslationModelInstaller,
        speechRecognitionService: SpeechRecognitionService,
        textToSpeechService: TextToSpeechService,
        speechModelInstaller: SpeechModelInstaller,
        modelDownloadCenter: ModelDownloadCenter,
        microphoneRecordingService: MicrophoneRecordingService
    ) {
        self.appSettings = appSettings
        self.translationService = translationService
        self.translationModelInstaller = translationModelInstaller
        self.speechRecognitionService = speechRecognitionService
        self.textToSpeechService = textToSpeechService
        self.speechModelInstaller = speechModelInstaller
        self.modelDownloadCenter = modelDownloadCenter
        self.microphoneRecordingService = microphoneRecordingService
        self.conversationStreamingCoordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechRecognitionService as? any SpeechRecognitionStreamingService
        )
        self.selectedLanguage = appSettings.selectedTargetLanguage
        startObservingDownloads()
        startObservingTextToSpeech()
    }

    func onAppear(using modelContext: ModelContext, sessions: [ChatSession]) {
        if selectedLanguage != appSettings.selectedTargetLanguage {
            selectedLanguage = appSettings.selectedTargetLanguage
        }
        removeEmptySessions(using: modelContext, sessions: sessions)
        Task {
            await modelDownloadCenter.warmUp()
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
            let revision = streamingState?.revision ?? 0
            let displayText = streamingState?.displayText ?? message.text
            let statusText = streamingState?.statusText ?? ""
            return "\(message.id.uuidString)-\(revision)-\(statusText)-\(displayText)"
        }
    }

    func streamingState(for message: ChatMessage) -> StreamingMessageState? {
        streamingStatesByMessageID[message.id]
    }

    func shouldShowNavigationBar(in sessions: [ChatSession]) -> Bool {
        isChatInputFocused || currentSession(in: sessions) != nil
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

        submitMessage(
            text: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: selectedLanguage,
            audioURL: nil,
            speechContent: nil,
            translationOrigin: .manual,
            using: modelContext,
            sessions: sessions,
            clearInput: true
        )
    }

    func resolveLanguageSelection(
        source: HomeLanguage,
        target: HomeLanguage
    ) async -> HomeLanguageSelectionResolution {
        do {
            let route = try await translationService.route(source: source, target: target)

            if !route.requiresModelDownload {
                return .ready
            }

            return .requiresDownload(HomeLanguageDownloadPrompt(route: route))
        } catch let error as TranslationError {
            return .failure(error.userFacingMessage)
        } catch {
            return .failure("暂时无法检查翻译模型，请稍后再试。")
        }
    }

    func commitLanguageSelection(source: HomeLanguage, target: HomeLanguage) {
        sourceLanguage = source
        selectedLanguage = target
        downloadableLanguagePrompt = nil
        deferredDownloadPrompt = nil
        activeDownloadPrompt = nil
    }

    func commitLanguageSelectionRequiringDownload(
        source: HomeLanguage,
        target: HomeLanguage,
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
        await modelDownloadCenter.startTranslationDownloads(packageIDs: packageIds)
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
        guard message.sender == .assistant else {
            return false
        }

        guard streamingState(for: message)?.isActive != true else {
            return false
        }

        return !(message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        await modelDownloadCenter.startSpeechDownload(packageId: packageId)
    }

    var shouldShowDownloadToolbarButton: Bool {
        true
    }

    var canStartDownloadFromToolbar: Bool {
        true
    }

    var isInstallingTranslationModel: Bool {
        activeDownloadItems.contains { $0.kind == .translation }
    }

    var isInstallingSpeechModel: Bool {
        activeDownloadItems.contains { $0.kind == .speech }
    }

    var downloadManagerHasAttention: Bool {
        downloadManagerSummary.hasAttention
    }

    var downloadManagerIsBusy: Bool {
        downloadManagerSummary.hasActiveTasks
    }

    var activeDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter {
            [.preparing, .downloading, .verifying, .installing].contains($0.progress.phase)
        }
    }

    var processingDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter {
            [.preparing, .downloading, .verifying, .installing].contains($0.progress.phase)
        }
    }

    var resumableDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter { $0.progress.phase == .pausedResumable }
    }

    var failedDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter { $0.progress.phase == .failed }
    }

    var installedDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter(\.isInstalled)
    }

    var availableDownloadItems: [ModelDownloadItem] {
        downloadManagerItems.filter {
            !$0.isInstalled && $0.progress.phase == .idle
        }
    }

    func retryDownload(itemID: String) async {
        await modelDownloadCenter.retry(itemID: itemID)
    }

    func resumeDownload(itemID: String) async {
        await modelDownloadCenter.resume(itemID: itemID)
    }

    func startDownload(item: ModelDownloadItem) async {
        switch item.kind {
        case .translation:
            await modelDownloadCenter.startTranslationDownloads(packageIDs: [item.descriptor.packageId])
        case .speech:
            await modelDownloadCenter.startSpeechDownload(packageId: item.descriptor.packageId)
        }
    }

    func deleteInstalledDownload(itemID: String) async {
        do {
            try await modelDownloadCenter.removeInstalled(itemID: itemID)
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
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
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
            let stream = await self.modelDownloadCenter.streamSnapshots()

            for await snapshot in stream {
                self.downloadManagerItems = snapshot.items
                self.downloadManagerSummary = snapshot.summary
                self.handleDownloadMilestones(for: snapshot)
            }
        }
    }

    private func startObservingTextToSpeech() {
        guard textToSpeechObservationTask == nil else {
            return
        }

        let stream = textToSpeechService.playbackEvents()
        textToSpeechObservationTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleTextToSpeechPlaybackEvent(event)
            }
        }
    }

    private func handleDownloadMilestones(for snapshot: ModelDownloadsSnapshot) {
        let milestoneSignature = snapshot.items
            .map { "\($0.id):\($0.progress.phase.rawValue):\($0.isInstalled)" }
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

        let matchingItemID = ModelDownloadDescriptor.itemID(kind: .speech, packageId: packageID)

        if snapshot.items.contains(where: {
            $0.id == matchingItemID && $0.isInstalled
        }) {
            pendingVoiceStartAfterInstall = false
            pendingSpeechResumePackageID = nil
            speechResumeRequestToken += 1
        }

        if snapshot.items.contains(where: {
            $0.id == matchingItemID && $0.progress.phase == .failed
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

    private func playbackLanguage(for message: ChatMessage) -> HomeLanguage? {
        if let language = message.language {
            return language
        }

        switch message.sender {
        case .assistant:
            return message.session?.targetLanguage ?? selectedLanguage
        case .user:
            return message.session?.sourceLanguage ?? sourceLanguage
        }
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
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
        audioURL: String?,
        speechContent: String?,
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
        let assistantMessageID = insertConversationExchange(
            text: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioURL,
            speechContent: speechContent,
            into: session,
            using: modelContext
        )

        if clearInput {
            messageText = ""
        }

        startStreamingTranslation(
            for: assistantMessageID,
            originalText: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translationOrigin: translationOrigin,
            using: modelContext
        )
    }

    private func resolveSession(
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
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
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
        audioURL: String?,
        speechContent: String?,
        into session: ChatSession,
        using modelContext: ModelContext
    ) -> UUID {
        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let now = Date()
        let userMessage = ChatMessage(
            sender: .user,
            text: text,
            language: sourceLanguage,
            audioURL: audioURL,
            speechContent: speechContent,
            createdAt: now,
            sequence: nextSequence,
            session: session
        )
        let assistantMessage = ChatMessage(
            sender: .assistant,
            text: "",
            language: targetLanguage,
            createdAt: now.addingTimeInterval(0.001),
            sequence: nextSequence + 1,
            session: session
        )

        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        session.updatedAt = assistantMessage.createdAt
        saveContext(using: modelContext)

        return assistantMessage.id
    }

    private func insertLiveSpeechConversationExchange(
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
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
        let now = Date()
        let userMessage = ChatMessage(
            sender: .user,
            text: "",
            language: sourceLanguage,
            createdAt: now,
            sequence: nextSequence,
            session: session
        )
        let assistantMessage = ChatMessage(
            sender: .assistant,
            text: "",
            language: targetLanguage,
            createdAt: now.addingTimeInterval(0.001),
            sequence: nextSequence + 1,
            session: session
        )

        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        session.updatedAt = assistantMessage.createdAt
        saveContext(using: modelContext)

        return LiveSpeechSession(
            session: session,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            fallbackSourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func startStreamingTranslation(
        for assistantMessageID: UUID,
        originalText: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
        translationOrigin: TranslationRequestOrigin,
        using modelContext: ModelContext
    ) {
        translationTasksByMessageID[assistantMessageID]?.cancel()
        streamingStatesByMessageID[assistantMessageID] = StreamingMessageState(
            messageID: assistantMessageID,
            committedText: "",
            liveText: nil,
            phase: .translating,
            revision: 0
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.translationTasksByMessageID.removeValue(forKey: assistantMessageID)
            }

            do {
                let stream: AsyncThrowingStream<ConversationStreamingEvent, Error>
                switch translationOrigin {
                case .manual:
                    stream = await self.conversationStreamingCoordinator.startManualTranslation(
                        messageID: assistantMessageID,
                        text: originalText,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                case .speech:
                    stream = await self.conversationStreamingCoordinator.startSpeechTranslation(
                        messageID: assistantMessageID,
                        text: originalText,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                }

                for try await event in stream {
                    self.handleStreamingConversationEvent(event, using: modelContext)
                }
            } catch is CancellationError {
                self.streamingStatesByMessageID.removeValue(forKey: assistantMessageID)
            } catch let error as TranslationError {
                self.failStreamingTranslation(
                    for: assistantMessageID,
                    message: error.userFacingMessage,
                    using: modelContext
                )
            } catch {
                self.failStreamingTranslation(
                    for: assistantMessageID,
                    message: "翻译失败了，请稍后再试。",
                    using: modelContext
                )
            }
        }

        translationTasksByMessageID[assistantMessageID] = task
    }

    private func startLiveSpeechStreaming(
        audioStream: AsyncStream<[Float]>
    ) {
        guard var liveSpeechSession else {
            return
        }

        liveSpeechSession.liveTask?.cancel()
        let assistantMessageID = liveSpeechSession.assistantMessage.id
        let fallbackSourceLanguage = liveSpeechSession.fallbackSourceLanguage
        let targetLanguage = liveSpeechSession.targetLanguage

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let stream = await self.conversationStreamingCoordinator.startLiveSpeechTranslation(
                    messageID: assistantMessageID,
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
            streamingStatesByMessageID[state.messageID] = state
        case .completed(let messageID, let text):
            updateAssistantMessage(
                id: messageID,
                text: text,
                using: modelContext
            )
            streamingStatesByMessageID.removeValue(forKey: messageID)
        }
    }

    private func failStreamingTranslation(
        for assistantMessageID: UUID,
        message: String,
        using modelContext: ModelContext
    ) {
        streamingStatesByMessageID[assistantMessageID] = StreamingMessageState(
            messageID: assistantMessageID,
            committedText: message,
            liveText: nil,
            phase: .failed(message),
            revision: (streamingStatesByMessageID[assistantMessageID]?.revision ?? 0) + 1
        )
        updateAssistantMessage(
            id: assistantMessageID,
            text: message,
            using: modelContext
        )
        streamingStatesByMessageID.removeValue(forKey: assistantMessageID)
    }

    private func updateAssistantMessage(
        id: UUID,
        text: String,
        using modelContext: ModelContext
    ) {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { message in
                message.id == id
            }
        )

        guard let message = try? modelContext.fetch(descriptor).first else {
            return
        }

        message.text = text
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

        streamingStatesByMessageID[session.userMessage.id] = StreamingMessageState(
            messageID: session.userMessage.id,
            committedText: state.stableTranscript,
            liveText: transcriptText.isEmpty ? nil : transcriptText,
            phase: .transcribing,
            revision: state.transcriptRevision
        )
        streamingStatesByMessageID[session.assistantMessage.id] = StreamingMessageState(
            messageID: session.assistantMessage.id,
            committedText: state.stableTranslation,
            liveText: translationText.isEmpty ? nil : translationText,
            phase: translationText.isEmpty ? .translating : .typing,
            revision: state.translationRevision
        )
    }

    private func finalizeLiveSpeechSession(
        transcript: String,
        translatedText: String,
        sourceLanguage: HomeLanguage,
        audioURL: String?,
        using modelContext: ModelContext
    ) {
        guard let liveSpeechSession else {
            return
        }

        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        liveSpeechSession.userMessage.text = normalizedTranscript
        liveSpeechSession.userMessage.language = sourceLanguage
        liveSpeechSession.userMessage.speechContent = normalizedTranscript
        liveSpeechSession.userMessage.audioURL = audioURL
        liveSpeechSession.assistantMessage.text = normalizedTranslation
        liveSpeechSession.assistantMessage.language = liveSpeechSession.targetLanguage
        liveSpeechSession.session.updatedAt = .now

        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.userMessage.id)
        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.assistantMessage.id)
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
            await conversationStreamingCoordinator.cancel(messageID: liveSpeechSession.assistantMessage.id)
        }
        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.userMessage.id)
        streamingStatesByMessageID.removeValue(forKey: liveSpeechSession.assistantMessage.id)
        modelContext.delete(liveSpeechSession.userMessage)
        modelContext.delete(liveSpeechSession.assistantMessage)
        let remainingMessages = liveSpeechSession.session.messages.filter {
            $0.id != liveSpeechSession.userMessage.id && $0.id != liveSpeechSession.assistantMessage.id
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
        fallbackSourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) async throws -> HomeLanguage {
        if let detectedLanguage = HomeLanguage.fromWhisperLanguageCode(detectedLanguageCode),
           try await translationService.supports(source: detectedLanguage, target: targetLanguage) {
            return detectedLanguage
        }

        return fallbackSourceLanguage
    }

    private func downloadPromptIfNeeded(
        source: HomeLanguage,
        target: HomeLanguage
    ) async -> HomeLanguageDownloadPrompt? {
        do {
            let route = try await translationService.route(source: source, target: target)

            if !route.requiresModelDownload {
                return nil
            }

            return HomeLanguageDownloadPrompt(route: route)
        } catch {
            return nil
        }
    }

    private func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt? {
        guard let package = try await speechModelInstaller.defaultPackageMetadata() else {
            throw SpeechRecognitionError.modelPackageUnavailable
        }

        if try await speechModelInstaller.isDefaultPackageInstalled() {
            return nil
        }

        return SpeechModelDownloadPrompt(package: package)
    }
}
