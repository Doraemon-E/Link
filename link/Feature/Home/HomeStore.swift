//
//  HomeStore.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import Observation

enum HomeSessionPresentation: Equatable {
    case none
    case draft
    case persisted(UUID)
}

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
    var ttsErrorMessage: String?
    var pendingVoiceStartAfterInstall = false
    var lastSpeechRecordingURL: URL?
    var speakingMessageID: UUID?
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
        textToSpeechService: dependencies.textToSpeechService
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
        Task {
            await dependencies.modelAssetService.warmUp()
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

    func shouldShowLanguagePickerHero(in runtime: HomeRuntimeContext) -> Bool {
        !isChatInputFocused &&
            sessionRepository.currentSession(in: runtime, presentation: sessionPresentation) == nil
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

    func shouldShowMessageSpeechButton(for message: ChatMessage) -> Bool {
        playbackController.shouldShowMessageSpeechButton(for: message)
    }

    func isMessageSpeechPlaybackDisabled(for message: ChatMessage) -> Bool {
        playbackController.isMessageSpeechPlaybackDisabled(for: message)
    }

    func isSpeakingMessage(_ message: ChatMessage) -> Bool {
        playbackController.isSpeakingMessage(message)
    }

    func toggleMessageSpeechPlayback(message: ChatMessage) {
        playbackController.toggleMessageSpeechPlayback(message: message)
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
