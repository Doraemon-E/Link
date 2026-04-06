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
    struct ViewState {
        let messageItems: [MessageItemState]
        let displayedMessageRenderKeys: [String]
        let shouldShowEmptyState: Bool
        let historySessions: [ChatSession]
        let currentSessionID: UUID?
        let toolbar: ToolbarState
        let downloadManager: DownloadManagerState
    }

    struct MessageItemState: Identifiable {
        let message: ChatMessage
        let streamingState: ExchangeStreamingState?
        let showsTranslatedPlaybackButton: Bool
        let isPlayingTranslatedMessage: Bool
        let isTranslatedPlaybackDisabled: Bool
        let isSourcePlaybackDisabled: Bool
        let isPlayingSourceMessage: Bool
        let showsSpeechTranscript: Bool
        let isSpeechTranscriptToggleDisabled: Bool
        let hasPlayableSourceRecording: Bool

        var id: UUID {
            message.id
        }
    }

    struct ToolbarState {
        let showsSessionHistoryButton: Bool
        let showsDownloadButton: Bool
        let isDownloadButtonEnabled: Bool
        let showsNewSessionButton: Bool
        let isDownloading: Bool
        let hasDownloadAttention: Bool
        let downloadProgress: Double?
        let resumableProgress: Double?
    }

    struct DownloadManagerState {
        let isLoading: Bool
        let processingRecords: [ModelAssetRecord]
        let resumableRecords: [ModelAssetRecord]
        let failedRecords: [ModelAssetRecord]
        let installedRecords: [ModelAssetRecord]
        let availableRecords: [ModelAssetRecord]
    }

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

    func makeViewState(in runtime: HomeRuntimeContext) -> ViewState {
        let messages = displayedMessages(in: runtime)
        let messageItems = messages.map(makeMessageItemState(for:))

        return ViewState(
            messageItems: messageItems,
            displayedMessageRenderKeys: messageItems.map { messageItem in
                messageRenderKey(
                    for: messageItem.message,
                    streamingState: messageItem.streamingState
                )
            },
            shouldShowEmptyState: messageItems.isEmpty && !isChatInputFocused,
            historySessions: runtime.historySessions,
            currentSessionID: currentSessionID(in: runtime),
            toolbar: makeToolbarState(in: runtime),
            downloadManager: makeDownloadManagerState()
        )
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

    func toggleTranslatedPlayback(message: ChatMessage) {
        playbackController.toggleTranslatedPlayback(message: message)
    }

    func toggleSourcePlayback(message: ChatMessage) {
        playbackController.toggleSourcePlayback(message: message)
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

    var isInstallingTranslationModel: Bool {
        activeAssetRecords.contains { $0.kind == .translation }
    }

    var isInstallingSpeechModel: Bool {
        activeAssetRecords.contains { $0.kind == .speech }
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

    private func displayedMessages(in runtime: HomeRuntimeContext) -> [ChatMessage] {
        guard !isDraftSession else { return [] }
        return sessionRepository.displayedMessages(
            in: runtime,
            presentation: sessionPresentation
        )
    }

    private func currentSessionID(in runtime: HomeRuntimeContext) -> UUID? {
        sessionRepository.currentSessionID(in: runtime, presentation: sessionPresentation)
    }

    private func makeMessageItemState(for message: ChatMessage) -> MessageItemState {
        let streamingState = streamingStatesByMessageID[message.id]

        return MessageItemState(
            message: message,
            streamingState: streamingState,
            showsTranslatedPlaybackButton: playbackController.shouldShowTranslatedPlaybackButton(for: message),
            isPlayingTranslatedMessage: playbackController.isPlayingTranslatedMessage(message),
            isTranslatedPlaybackDisabled: playbackController.isTranslatedPlaybackDisabled(for: message),
            isSourcePlaybackDisabled: playbackController.isSourcePlaybackDisabled(for: message),
            isPlayingSourceMessage: playbackController.isPlayingSourceMessage(message),
            showsSpeechTranscript: isSpeechTranscriptExpanded(for: message),
            isSpeechTranscriptToggleDisabled: playbackController.shouldAutoExpandSpeechTranscript(for: message),
            hasPlayableSourceRecording: playbackController.hasPlayableSourceRecording(for: message)
        )
    }

    private func makeToolbarState(in runtime: HomeRuntimeContext) -> ToolbarState {
        ToolbarState(
            showsSessionHistoryButton: true,
            showsDownloadButton: shouldShowDownloadToolbarButton,
            isDownloadButtonEnabled: canStartDownloadFromToolbar,
            showsNewSessionButton: !isDraftSession &&
                sessionRepository.currentSession(in: runtime, presentation: sessionPresentation) != nil,
            isDownloading: assetSummary.hasActiveTasks,
            hasDownloadAttention: assetSummary.hasAttention,
            downloadProgress: aggregatedProgress(for: activeAssetRecords),
            resumableProgress: aggregatedProgress(for: resumableAssetRecords)
        )
    }

    private func makeDownloadManagerState() -> DownloadManagerState {
        DownloadManagerState(
            isLoading: isDownloadManagerLoading,
            processingRecords: activeAssetRecords,
            resumableRecords: resumableAssetRecords,
            failedRecords: failedAssetRecords,
            installedRecords: installedAssetRecords,
            availableRecords: availableAssetRecords
        )
    }

    private func messageRenderKey(
        for message: ChatMessage,
        streamingState: ExchangeStreamingState?
    ) -> String {
        let sourceRevision = streamingState?.sourceRevision ?? 0
        let translationRevision = streamingState?.translationRevision ?? 0
        let sourceText = streamingState?.sourceDisplayText ?? message.sourceText
        let translatedText = streamingState?.translatedDisplayText ?? message.translatedText

        return "\(message.id.uuidString)-\(sourceRevision)-\(translationRevision)-\(sourceText)-\(translatedText)"
    }

    private func isSpeechTranscriptExpanded(for message: ChatMessage) -> Bool {
        guard message.inputType == .speech else {
            return false
        }

        if playbackController.shouldAutoExpandSpeechTranscript(for: message) {
            return true
        }

        return expandedSpeechTranscriptMessageIDs.contains(message.id)
    }

    private func aggregatedProgress(for records: [ModelAssetRecord]) -> Double? {
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

    private var shouldShowDownloadToolbarButton: Bool {
        true
    }

    private var canStartDownloadFromToolbar: Bool {
        true
    }

    private var activeAssetRecords: [ModelAssetRecord] {
        assetRecords.filter {
            [.preparing, .downloading, .verifying, .installing].contains($0.status.state)
        }
    }

    private var resumableAssetRecords: [ModelAssetRecord] {
        assetRecords.filter { $0.status.state == .pausedResumable }
    }

    private var failedAssetRecords: [ModelAssetRecord] {
        assetRecords.filter { $0.status.state == .failed }
    }

    private var installedAssetRecords: [ModelAssetRecord] {
        assetRecords.filter(\.isInstalled)
    }

    private var availableAssetRecords: [ModelAssetRecord] {
        assetRecords.filter {
            !$0.isInstalled && $0.status.state == .idle
        }
    }

    private var isDraftSession: Bool {
        if case .draft = sessionPresentation {
            return true
        }

        return false
    }
}
