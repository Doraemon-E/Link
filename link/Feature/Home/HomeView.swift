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
                    if displayedMessages.isEmpty && shouldShowLanguagePickerHero {
                        emptyState
                    } else {
                        messageList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
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
                get: { store.playbackErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.playbackErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.playbackErrorMessage ?? "")
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
        VStack(spacing: 18) {
            Spacer(minLength: 72)

            Text("开始新的翻译对话")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text("选择当前想要输出的语言，消息会以聊天的方式逐条呈现。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(displayedMessages, id: \.id) { message in
                    HomeChatMessageBubble(
                        message: message,
                        streamingState: store.streamingState(for: message),
                        showsTranslatedPlaybackButton: store.shouldShowTranslatedPlaybackButton(for: message),
                        isPlayingTranslatedMessage: store.isPlayingTranslatedMessage(message),
                        isTranslatedPlaybackDisabled: store.isTranslatedPlaybackDisabled(for: message),
                        isSourcePlaybackDisabled: store.isSourcePlaybackDisabled(for: message),
                        isPlayingSourceMessage: store.isPlayingSourceMessage(message),
                        showsSpeechTranscript: store.isSpeechTranscriptExpanded(for: message),
                        isSpeechTranscriptToggleDisabled: store.isSpeechTranscriptToggleDisabled(for: message),
                        hasPlayableSourceRecording: store.hasPlayableSourceRecording(for: message),
                        onTranslatedPlayback: {
                            store.toggleTranslatedPlayback(message: message)
                        },
                        onSourcePlayback: {
                            store.toggleSourcePlayback(message: message)
                        },
                        onSpeechTranscriptToggle: {
                            store.toggleSpeechTranscript(for: message)
                        }
                    )
                        .id(message.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var downloadManagerView: some View {
        ModelAssetsView(
            isLoading: store.isDownloadManagerLoading,
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
        .task {
            await store.prepareDownloadManagerIfNeeded()
        }
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
                hasAttention: store.assetManagerHasAttention,
                progress: store.assetManagerProgress,
                resumableProgress: store.assetManagerResumableProgress
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
    let progress: Double?
    let resumableProgress: Double?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))

                // Circle()
                //     .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color.primary.opacity(isDownloading ? 0.86 : 0.8),
                        Color.primary.opacity(isDownloading ? 0.16 : 0.12)
                    )
            }
            .frame(width: 32, height: 32)
            .overlay {
                if isDownloading {
                    HomeDownloadProgressRing(progress: clampedProgress, isActive: true)
                } else if hasAttention {
                    HomeDownloadProgressRing(progress: clampedResumableProgress, isActive: false)
                }
            }
            .contentShape(Circle())
        }
        .frame(width: 32, height: 32)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isDownloading)
        .animation(.easeInOut(duration: 0.24), value: clampedProgress)
        .animation(.easeInOut(duration: 0.24), value: clampedResumableProgress)
    }

    private var clampedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var clampedResumableProgress: Double {
        min(max(resumableProgress ?? 0, 0), 1)
    }
}

private struct HomeDownloadProgressRing: View {
    let progress: Double
    var isActive: Bool = true

    private var arcColor: Color {
        isActive ? Color.accentColor : Color(red: 0.95, green: 0.46, blue: 0.34)
    }

    private var trackColor: Color {
        isActive
            ? Color.primary.opacity(0.08)
            : Color(red: 0.95, green: 0.46, blue: 0.34).opacity(0.25)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 2)

            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        arcColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(0.5)
    }
}

#Preview("Download Toolbar Icon States") {
    HStack(spacing: 16) {
        HomeDownloadToolbarIcon(
            isDownloading: false,
            hasAttention: false,
            progress: nil,
            resumableProgress: nil
        )

        HomeDownloadToolbarIcon(
            isDownloading: false,
            hasAttention: true,
            progress: nil,
            resumableProgress: 0.6
        )

        HomeDownloadToolbarIcon(
            isDownloading: true,
            hasAttention: false,
            progress: 0.42,
            resumableProgress: nil
        )

        HomeDownloadToolbarIcon(
            isDownloading: true,
            hasAttention: false,
            progress: 1,
            resumableProgress: nil
        )
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
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
            audioFilePlaybackService: SystemAudioFilePlaybackService(),
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
