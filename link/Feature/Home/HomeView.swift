//
//  HomeView.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @State private var store: HomeStore

    init(dependencies: HomeDependencies) {
        _store = State(
            initialValue: HomeStore(
                dependencies: dependencies
            )
        )
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if displayedMessages.isEmpty {
                        emptyState
                    } else {
                        messageList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .navigationBarTitleDisplayMode(.inline)
                .onTapGesture {
                    if store.isChatInputFocused {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            store.isChatInputFocused = false
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        sessionHistoryToolbarButton
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if store.shouldShowDownloadToolbarButton {
                            downloadToolbarButton
                        }

                        if shouldShowNewSessionButton {
                            newSessionToolbarButton
                        }
                    }
                }
                .onAppear {
                    store.onAppear(in: runtimeContext)
                    scrollToBottom(with: proxy, animated: false)
                }
                .onChange(of: displayedMessageRenderKeys) { _, _ in
                    scrollToBottom(with: proxy)
                }
            }
            .navigationDestination(isPresented: $store.isDownloadManagerPresented) {
                downloadManagerView
            }
        }
        .sheet(isPresented: $store.isLanguageSheetPresented) {
            HomeLanguageSheet(
                selectedLanguage: $store.selectedLanguage,
                isPresented: $store.isLanguageSheetPresented,
                onCommitSelection: { target in
                    store.commitTargetLanguageSelection(target)
                }
            )
        }
        .sheet(isPresented: $store.isSessionHistoryPresented) {
            HomeSessionHistorySheet(
                sessions: historySessions,
                currentSessionID: currentSessionID,
                onSelect: { sessionID in
                    store.selectSession(id: sessionID)
                },
                isPresented: $store.isSessionHistoryPresented
            )
        }
        .confirmationDialog(
            store.activeDownloadPrompt?.title ?? "",
            isPresented: Binding(
                get: { store.activeDownloadPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissDownloadPrompt()
                    }
                }
            ),
            presenting: store.activeDownloadPrompt
        ) { prompt in
            Button("下载并安装") {
                Task {
                    await store.installTranslationModel(packageIds: prompt.packageIds)
                }
            }

            Button("取消", role: .cancel) {
                store.dismissDownloadPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .confirmationDialog(
            store.activeSpeechDownloadPrompt?.title ?? "",
            isPresented: Binding(
                get: { store.activeSpeechDownloadPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissSpeechDownloadPrompt()
                    }
                }
            ),
            presenting: store.activeSpeechDownloadPrompt
        ) { prompt in
            Button("下载并安装") {
                let packageId = prompt.packageId
                let shouldResumeRecording = store.pendingVoiceStartAfterInstall

                Task {
                    await store.installSpeechModelAndResumeIfNeeded(
                        packageId: packageId,
                        shouldResumeRecording: shouldResumeRecording
                    )
                }
            }

            Button("取消", role: .cancel) {
                store.dismissSpeechDownloadPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(
            "模型下载失败",
            isPresented: Binding(
                get: { store.downloadErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.downloadErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.downloadErrorMessage ?? "")
        }
        .alert(
            "输入语言识别失败",
            isPresented: Binding(
                get: { store.messageErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.messageErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.messageErrorMessage ?? "")
        }
        .alert(
            "语音识别失败",
            isPresented: Binding(
                get: { store.speechErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.speechErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.speechErrorMessage ?? "")
        }
        .alert(
            "语音播放失败",
            isPresented: Binding(
                get: { store.ttsErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.ttsErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.ttsErrorMessage ?? "")
        }
        .task {
            await store.refreshDownloadAvailabilityForCurrentSelection()
        }
        .onChange(of: store.isLanguageSheetPresented) { _, isPresented in
            if !isPresented {
                store.presentDeferredDownloadPromptIfNeeded()
            }
        }
        .onChange(of: store.speechResumeRequestToken) { _, token in
            guard token > 0 else { return }

            Task {
                await store.handlePendingSpeechResumeIfNeeded(in: runtimeContext)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.isDownloadManagerPresented {
                HomeChatInputBar(
                    text: $store.messageText,
                    isFocused: $store.isChatInputFocused,
                    isRecordingSpeech: store.isRecordingSpeech,
                    isSpeechBusy: store.isTranscribingSpeech || store.isInstallingSpeechModel,
                    onFocusActivated: store.handleInputFocusActivated,
                    onSend: {
                        store.sendCurrentMessage(in: runtimeContext)
                    },
                    onVoiceInput: {
                        Task {
                            await store.toggleSpeechRecording(in: runtimeContext)
                        }
                    }
                )
            }
        }
    }

    private var runtimeContext: HomeRuntimeContext {
        HomeRuntimeContext(
            modelContext: modelContext,
            sessions: sessions
        )
    }

    private var displayedMessages: [ChatMessage] {
        store.displayedMessages(in: runtimeContext)
    }

    private var displayedMessageIDs: [UUID] {
        store.displayedMessageIDs(in: runtimeContext)
    }

    private var displayedMessageRenderKeys: [String] {
        store.displayedMessageRenderKeys(in: runtimeContext)
    }

    private var historySessions: [ChatSession] {
        runtimeContext.historySessions
    }

    private var currentSessionID: UUID? {
        store.currentSessionID(in: runtimeContext)
    }

    private var shouldShowSessionHistoryButton: Bool {
        store.shouldShowSessionHistoryButton(in: runtimeContext)
    }

    private var shouldShowLanguagePickerHero: Bool {
        store.shouldShowLanguagePickerHero(in: runtimeContext)
    }

    private var shouldShowNewSessionButton: Bool {
        store.shouldShowNewSessionButton(in: runtimeContext)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()

            if shouldShowLanguagePickerHero {
                Button {
                    store.isLanguageSheetPresented = true
                } label: {
                    HomeHeroLanguageChip(
                        flagEmoji: store.selectedLanguage.flagEmoji,
                        title: store.selectedLanguage.displayName
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }

            Spacer()
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(displayedMessages, id: \.id) { message in
                    HomeChatMessageBubble(
                        message: message,
                        streamingState: store.streamingState(for: message),
                        showsSpeechPlaybackButton: store.shouldShowMessageSpeechButton(for: message),
                        isSpeakingMessage: store.isSpeakingMessage(message),
                        isSpeechPlaybackDisabled: store.isMessageSpeechPlaybackDisabled(for: message),
                        onSpeechPlayback: {
                            store.toggleMessageSpeechPlayback(message: message)
                        }
                    )
                        .id(message.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var downloadManagerView: some View {
        ModelAssetsView(
            processingRecords: store.processingAssetRecords,
            resumableRecords: store.resumableAssetRecords,
            failedRecords: store.failedAssetRecords,
            installedRecords: store.installedAssetRecords,
            availableRecords: store.availableAssetRecords,
            onDownload: { item in
                Task {
                    await store.startDownload(item: item)
                }
            },
            onResume: { itemID in
                Task {
                    await store.resumeDownload(itemID: itemID)
                }
            },
            onRetry: { itemID in
                Task {
                    await store.retryDownload(itemID: itemID)
                }
            },
            onDelete: { itemID in
                Task {
                    await store.deleteInstalledDownload(itemID: itemID)
                }
            }
        )
    }

    private var sessionHistoryToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: "历史会话",
            isEnabled: shouldShowSessionHistoryButton,
            action: store.openSessionHistory
        ) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
        }
    }

    private var newSessionToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: "新增会话",
            isEnabled: shouldShowNewSessionButton,
            action: store.startNewSession
        ) {
            Image(systemName: "square.and.pencil")
                .font(.body.weight(.semibold))
        }
    }

    private var downloadToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: "下载管理",
            isEnabled: store.canStartDownloadFromToolbar,
            action: store.openDownloadManager
        ) {
            HomeDownloadToolbarIcon(
                isDownloading: store.assetManagerIsBusy,
                hasAttention: store.assetManagerHasAttention
            )
        }
    }

    private func toolbarIconButton<Label: View>(
        accessibilityLabel: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let lastMessageID = displayedMessageIDs.last else { return }

        let action = {
            proxy.scrollTo(lastMessageID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                action()
            }
        } else {
            action()
        }
    }
}

private struct HomeDownloadToolbarIcon: View {
    let isDownloading: Bool
    let hasAttention: Bool
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Image(systemName: isDownloading ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(isDownloading ? Color.accentColor : Color.primary)

            if isDownloading {
                ZStack {
                    animatedArrow(delay: 0)
                    animatedArrow(delay: 0.45)
                }
                .frame(width: 18, height: 18)
                .clipped()
            } else if hasAttention {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .offset(x: 8, y: -8)
            }
        }
        .onAppear {
            guard isDownloading else { return }
            isAnimating = true
        }
        .onChange(of: isDownloading) { _, downloading in
            isAnimating = downloading
        }
    }

    private func animatedArrow(delay: Double) -> some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
            .offset(y: isAnimating ? 6 : -5)
            .opacity(isAnimating ? 0 : 1)
            .animation(
                .linear(duration: 0.9)
                    .delay(delay)
                    .repeatForever(autoreverses: false),
                value: isAnimating
            )
    }
}

#Preview {
    let catalogRepository = TranslationModelCatalogRepository(remoteCatalogURL: nil, bundle: .main)
    let translationPackageManager = TranslationModelPackageManager(catalogRepository: catalogRepository)
    let speechPackageManager = SpeechModelPackageManager(
        catalogRepository: SpeechModelCatalogRepository(remoteCatalogURL: nil, bundle: .main)
    )
    HomeView(
        dependencies: HomeDependencies(
            appSettings: AppSettings(
                userDefaults: UserDefaults(suiteName: "HomeViewPreview") ?? .standard
            ),
            textLanguageRecognitionService: SystemTextLanguageRecognitionService(),
            translationService: MarianTranslationService(modelProvider: translationPackageManager),
            speechRecognitionService: WhisperSpeechRecognitionService(
                packageManager: speechPackageManager
            ),
            textToSpeechService: SystemTextToSpeechService(),
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: translationPackageManager,
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )
    )
        .modelContainer(for: [ChatSession.self, ChatMessage.self], inMemory: true)
}
