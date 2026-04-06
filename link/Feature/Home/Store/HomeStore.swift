//
//  HomeStore.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import Observation

@MainActor
@Observable
final class HomeStore {
    var sourceLanguage: SupportedLanguage = .chinese
    var selectedLanguage: SupportedLanguage {
        didSet {
            guard dependencies.appSettings.selectedTargetLanguage != selectedLanguage else { return }
            dependencies.appSettings.selectedTargetLanguage = selectedLanguage
        }
    }
    var isLanguageSheetPresented = false
    var isSessionHistoryPresented = false
    var isDownloadManagerPresented = false
    var isDownloadManagerLoading = false
    var hasPreparedDownloadManager = false
    var messageText = ""
    var isChatInputFocused = false
    var sessionPresentation: HomeSessionPresentation = .none
    var downloadableLanguagePrompt: HomeLanguageDownloadPrompt?
    var deferredDownloadPrompt: HomeLanguageDownloadPrompt?
    var activeDownloadPrompt: HomeLanguageDownloadPrompt?
    var messageErrorMessage: String?
    var downloadErrorMessage: String?
    var isRecordingSpeech = false
    var isTranscribingSpeech = false
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt?
    var speechErrorMessage: String?
    var playbackErrorMessage: String?
    var pendingVoiceStartAfterInstall = false
    var lastSpeechRecordingURL: URL?
    var activePlaybackState: HomePlaybackState?
    var expandedSpeechTranscriptMessageIDs: Set<UUID> = []
    var streamingStatesByMessageID: [UUID: ExchangeStreamingState] = [:]
    var assetRecords: [ModelAssetRecord] = []
    var assetSummary: ModelAssetSummary = .empty
    var speechResumeRequestToken = 0

    @ObservationIgnored private let dependencies: HomeDependencies
    @ObservationIgnored private let sessionRepository = HomeSessionRepository()
    @ObservationIgnored private let conversationStreamingCoordinator: any ConversationStreamingCoordinator
    @ObservationIgnored private lazy var downloadWorkflow = HomeDownloadWorkflow(
        store: self,
        dependencies: dependencies
    )
    @ObservationIgnored private lazy var playbackController = HomePlaybackController(
        store: self,
        textToSpeechService: dependencies.textToSpeechService,
        audioFilePlaybackService: dependencies.audioFilePlaybackService
    )
    @ObservationIgnored private lazy var messageWorkflow = HomeMessageWorkflow(
        store: self,
        sessionRepository: sessionRepository,
        conversationStreamingCoordinator: conversationStreamingCoordinator,
        textLanguageRecognitionService: dependencies.textLanguageRecognitionService,
        downloadWorkflow: downloadWorkflow
    )
    @ObservationIgnored private lazy var speechWorkflow = HomeSpeechWorkflow(
        store: self,
        sessionRepository: sessionRepository,
        conversationStreamingCoordinator: conversationStreamingCoordinator,
        translationService: dependencies.translationService,
        speechRecognitionService: dependencies.speechRecognitionService,
        microphoneRecordingService: dependencies.microphoneRecordingService,
        downloadWorkflow: downloadWorkflow,
        playbackController: playbackController
    )

    init(dependencies: HomeDependencies) {
        self.dependencies = dependencies
        self.conversationStreamingCoordinator = LocalConversationStreamingCoordinator(
            translationService: dependencies.translationService,
            translationAssetReadinessProvider: dependencies.translationAssetReadinessProvider,
            speechStreamingService: dependencies.speechRecognitionService as? any SpeechRecognitionStreamingService
        )
        self.selectedLanguage = dependencies.appSettings.selectedTargetLanguage
        downloadWorkflow.startObservingDownloads()
        playbackController.startObservingPlayback()
    }

    func onAppear(in runtime: HomeRuntimeContext) {
        if selectedLanguage != dependencies.appSettings.selectedTargetLanguage {
            selectedLanguage = dependencies.appSettings.selectedTargetLanguage
        }
        sessionRepository.removeEmptySessions(
            in: runtime,
            presentation: &sessionPresentation
        )
        if !dependencies.appSettings.hasShownInitialTargetLanguagePicker {
            dependencies.appSettings.hasShownInitialTargetLanguagePicker = true
            isLanguageSheetPresented = true
        }
    }

    func displayedMessages(in runtime: HomeRuntimeContext) -> [ChatMessage] {
        guard !isDraftSession else { return [] }
        return sessionRepository.displayedMessages(
            in: runtime,
            presentation: sessionPresentation
        )
    }

    func displayedMessageIDs(in runtime: HomeRuntimeContext) -> [UUID] {
        displayedMessages(in: runtime).map(\.id)
    }

    func displayedMessageRenderKeys(in runtime: HomeRuntimeContext) -> [String] {
        displayedMessages(in: runtime).map { message in
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

    func shouldShowSessionHistoryButton(in runtime: HomeRuntimeContext) -> Bool {
        return true
    }

    func shouldShowNewSessionButton(in runtime: HomeRuntimeContext) -> Bool {
        !isDraftSession &&
            sessionRepository.currentSession(in: runtime, presentation: sessionPresentation) != nil
    }

    func currentSessionID(in runtime: HomeRuntimeContext) -> UUID? {
        sessionRepository.currentSessionID(in: runtime, presentation: sessionPresentation)
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
        playbackController.stop()
        sessionPresentation = .draft
        isChatInputFocused = false
    }

    func selectSession(id sessionID: UUID) {
        playbackController.stop()
        sessionPresentation = .persisted(sessionID)
        isChatInputFocused = false

        DispatchQueue.main.async {
            self.isSessionHistoryPresented = false
        }
    }

    func sendCurrentMessage(in runtime: HomeRuntimeContext) {
        messageWorkflow.sendCurrentMessage(in: runtime)
    }

    func commitTargetLanguageSelection(_ target: SupportedLanguage) {
        selectedLanguage = target
        downloadableLanguagePrompt = nil
        deferredDownloadPrompt = nil
        activeDownloadPrompt = nil

        Task {
            await refreshDownloadAvailabilityForCurrentSelection()
        }
    }

    func presentDeferredDownloadPromptIfNeeded() {
        downloadWorkflow.presentDeferredDownloadPromptIfNeeded()
    }

    func openDownloadManager() {
        downloadWorkflow.openDownloadManager()
    }

    func prepareDownloadManagerIfNeeded() async {
        await downloadWorkflow.prepareDownloadManagerIfNeeded()
    }

    func presentDownloadPrompt() {
        downloadWorkflow.presentDownloadPrompt()
    }

    func dismissDownloadPrompt() {
        downloadWorkflow.dismissDownloadPrompt()
    }

    func dismissSpeechDownloadPrompt() {
        downloadWorkflow.dismissSpeechDownloadPrompt()
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
        await downloadWorkflow.refreshDownloadAvailabilityForCurrentSelection()
    }

    func installTranslationModel(packageIds: [String]) async {
        await downloadWorkflow.installTranslationModel(packageIds: packageIds)
    }

    func toggleSpeechRecording(in runtime: HomeRuntimeContext) async {
        await speechWorkflow.toggleSpeechRecording(in: runtime)
    }

    func shouldShowTranslatedPlaybackButton(for message: ChatMessage) -> Bool {
        playbackController.shouldShowTranslatedPlaybackButton(for: message)
    }

    func isTranslatedPlaybackDisabled(for message: ChatMessage) -> Bool {
        playbackController.isTranslatedPlaybackDisabled(for: message)
    }

    func isPlayingTranslatedMessage(_ message: ChatMessage) -> Bool {
        playbackController.isPlayingTranslatedMessage(message)
    }

    func toggleTranslatedPlayback(message: ChatMessage) {
        playbackController.toggleTranslatedPlayback(message: message)
    }

    func isSourcePlaybackDisabled(for message: ChatMessage) -> Bool {
        playbackController.isSourcePlaybackDisabled(for: message)
    }

    func isPlayingSourceMessage(_ message: ChatMessage) -> Bool {
        playbackController.isPlayingSourceMessage(message)
    }

    func hasPlayableSourceRecording(for message: ChatMessage) -> Bool {
        playbackController.hasPlayableSourceRecording(for: message)
    }

    func toggleSourcePlayback(message: ChatMessage) {
        playbackController.toggleSourcePlayback(message: message)
    }

    func isSpeechTranscriptExpanded(for message: ChatMessage) -> Bool {
        guard message.inputType == .speech else {
            return false
        }

        if playbackController.shouldAutoExpandSpeechTranscript(for: message) {
            return true
        }

        return expandedSpeechTranscriptMessageIDs.contains(message.id)
    }

    func canToggleSpeechTranscript(for message: ChatMessage) -> Bool {
        message.inputType == .speech
    }

    func isSpeechTranscriptToggleDisabled(for message: ChatMessage) -> Bool {
        playbackController.shouldAutoExpandSpeechTranscript(for: message)
    }

    func toggleSpeechTranscript(for message: ChatMessage) {
        guard message.inputType == .speech else {
            return
        }

        guard !playbackController.shouldAutoExpandSpeechTranscript(for: message) else {
            return
        }

        if expandedSpeechTranscriptMessageIDs.contains(message.id) {
            expandedSpeechTranscriptMessageIDs.remove(message.id)
        } else {
            expandedSpeechTranscriptMessageIDs.insert(message.id)
        }
    }

    func installSpeechModelAndResumeIfNeeded(
        packageId: String,
        shouldResumeRecording: Bool
    ) async {
        await downloadWorkflow.installSpeechModelAndResumeIfNeeded(
            packageId: packageId,
            shouldResumeRecording: shouldResumeRecording
        )
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

    var assetManagerProgress: Double? {
        let records = activeAssetRecords
        guard !records.isEmpty else { return nil }

        let totalBytes = records.reduce(Int64(0)) { partialResult, record in
            partialResult + max(record.status.totalBytes, 0)
        }

        if totalBytes > 0 {
            let downloadedBytes = records.reduce(Int64(0)) { partialResult, record in
                let total = max(record.status.totalBytes, 0)
                let downloaded = max(record.status.downloadedBytes, 0)
                return partialResult + min(downloaded, total)
            }

            return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        }

        let averageProgress = records.reduce(0.0) { partialResult, record in
            partialResult + record.status.fractionCompleted
        } / Double(records.count)

        return min(max(averageProgress, 0), 1)
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

    var assetManagerResumableProgress: Double? {
        let records = resumableAssetRecords
        guard !records.isEmpty else { return nil }

        let totalBytes = records.reduce(Int64(0)) { partialResult, record in
            partialResult + max(record.status.totalBytes, 0)
        }

        if totalBytes > 0 {
            let downloadedBytes = records.reduce(Int64(0)) { partialResult, record in
                let total = max(record.status.totalBytes, 0)
                let downloaded = max(record.status.downloadedBytes, 0)
                return partialResult + min(downloaded, total)
            }

            return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        }

        let averageProgress = records.reduce(0.0) { partialResult, record in
            partialResult + record.status.fractionCompleted
        } / Double(records.count)

        return min(max(averageProgress, 0), 1)
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
        await downloadWorkflow.retryDownload(itemID: itemID)
    }

    func resumeDownload(itemID: String) async {
        await downloadWorkflow.resumeDownload(itemID: itemID)
    }

    func startDownload(item: ModelAssetRecord) async {
        await downloadWorkflow.startDownload(item: item)
    }

    func deleteInstalledDownload(itemID: String) async {
        await downloadWorkflow.deleteInstalledDownload(itemID: itemID)
    }

    func handlePendingSpeechResumeIfNeeded(in runtime: HomeRuntimeContext) async {
        await speechWorkflow.handlePendingSpeechResumeIfNeeded(in: runtime)
    }

    private var isDraftSession: Bool {
        if case .draft = sessionPresentation {
            return true
        }

        return false
    }
}
