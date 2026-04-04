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
    @State private var viewModel: HomeViewModel
    @State private var languageSheetMode: HomeLanguageSheet.Mode = .full

    init(
        appSettings: AppSettings,
        translationService: TranslationService,
        translationModelInstaller: TranslationModelInstaller,
        speechRecognitionService: SpeechRecognitionService,
        speechModelInstaller: SpeechModelInstaller,
        microphoneRecordingService: MicrophoneRecordingService
    ) {
        _viewModel = State(
            initialValue: HomeViewModel(
                appSettings: appSettings,
                translationService: translationService,
                translationModelInstaller: translationModelInstaller,
                speechRecognitionService: speechRecognitionService,
                speechModelInstaller: speechModelInstaller,
                microphoneRecordingService: microphoneRecordingService
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel

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
                    if viewModel.isChatInputFocused {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            viewModel.isChatInputFocused = false
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        sessionHistoryToolbarButton
                    }

                    if shouldShowNavigationBar {
                        ToolbarItem {
                            toolbarContent
                        }

                        ToolbarSpacer()

                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if viewModel.shouldShowDownloadToolbarButton {
                                downloadToolbarButton
                            }

                            newSessionToolbarButton
                        }
                    }
                }
                .onAppear {
                    viewModel.onAppear(using: modelContext, sessions: sessions)
                    scrollToBottom(with: proxy, animated: false)
                }
                .onChange(of: displayedMessageIDs) { _, _ in
                    scrollToBottom(with: proxy)
                }
            }
        }
        .sheet(isPresented: $viewModel.isLanguageSheetPresented) {
            HomeLanguageSheet(
                sourceLanguage: $viewModel.sourceLanguage,
                selectedLanguage: $viewModel.selectedLanguage,
                isPresented: $viewModel.isLanguageSheetPresented,
                mode: languageSheetMode,
                onResolveSelection: { source, target in
                    await viewModel.resolveLanguageSelection(source: source, target: target)
                },
                onCommitSelection: { source, target in
                    viewModel.commitLanguageSelection(source: source, target: target)
                },
                onCommitSelectionRequiringDownload: { source, target, prompt in
                    viewModel.commitLanguageSelectionRequiringDownload(
                        source: source,
                        target: target,
                        prompt: prompt
                    )
                }
            )
        }
        .sheet(isPresented: $viewModel.isSessionHistoryPresented) {
            HomeSessionHistorySheet(
                sessions: historySessions,
                currentSessionID: currentSessionID,
                onSelect: { sessionID in
                    viewModel.selectSession(id: sessionID)
                },
                isPresented: $viewModel.isSessionHistoryPresented
            )
        }
        .confirmationDialog(
            viewModel.activeDownloadPrompt?.title ?? "",
            isPresented: Binding(
                get: { viewModel.activeDownloadPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissDownloadPrompt()
                    }
                }
            ),
            presenting: viewModel.activeDownloadPrompt
        ) { prompt in
            Button("下载并安装") {
                Task {
                    await viewModel.installTranslationModel(packageIds: prompt.packageIds)
                }
            }

            Button("取消", role: .cancel) {
                viewModel.dismissDownloadPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .confirmationDialog(
            viewModel.activeSpeechDownloadPrompt?.title ?? "",
            isPresented: Binding(
                get: { viewModel.activeSpeechDownloadPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissSpeechDownloadPrompt()
                    }
                }
            ),
            presenting: viewModel.activeSpeechDownloadPrompt
        ) { prompt in
            Button("下载并安装") {
                let packageId = prompt.packageId
                let shouldResumeRecording = viewModel.pendingVoiceStartAfterInstall

                Task {
                    await viewModel.installSpeechModelAndResumeIfNeeded(
                        packageId: packageId,
                        shouldResumeRecording: shouldResumeRecording,
                        using: modelContext,
                        sessions: sessions
                    )
                }
            }

            Button("取消", role: .cancel) {
                viewModel.dismissSpeechDownloadPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(
            "模型下载失败",
            isPresented: Binding(
                get: { viewModel.downloadErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.downloadErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.downloadErrorMessage ?? "")
        }
        .alert(
            "语音识别失败",
            isPresented: Binding(
                get: { viewModel.speechErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.speechErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.speechErrorMessage ?? "")
        }
        .task {
            await viewModel.refreshDownloadAvailabilityForCurrentSelection()
        }
        .onChange(of: viewModel.isLanguageSheetPresented) { _, isPresented in
            if !isPresented {
                viewModel.presentDeferredDownloadPromptIfNeeded()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HomeChatInputBar(
                text: $viewModel.messageText,
                isFocused: $viewModel.isChatInputFocused,
                isRecordingSpeech: viewModel.isRecordingSpeech,
                isSpeechBusy: viewModel.isTranscribingSpeech || viewModel.isInstallingSpeechModel,
                hasLastSpeechRecording: viewModel.hasLastSpeechRecording,
                isPlayingLastSpeechRecording: viewModel.isPlayingLastSpeechRecording,
                onFocusActivated: viewModel.handleInputFocusActivated,
                onSend: {
                    viewModel.sendCurrentMessage(using: modelContext, sessions: sessions)
                },
                onVoiceInput: {
                    Task {
                        await viewModel.toggleSpeechRecording(
                            using: modelContext,
                            sessions: sessions
                        )
                    }
                },
                onPlayLastSpeechRecording: {
                    viewModel.toggleLastSpeechRecordingPlayback()
                }
            )
        }
    }

    private var displayedMessages: [ChatMessage] {
        viewModel.displayedMessages(in: sessions)
    }

    private var displayedMessageIDs: [UUID] {
        viewModel.displayedMessageIDs(in: sessions)
    }

    private var shouldShowNavigationBar: Bool {
        viewModel.shouldShowNavigationBar(in: sessions)
    }

    private var historySessions: [ChatSession] {
        sessions.filter(\.hasMessages)
    }

    private var currentSessionID: UUID? {
        viewModel.currentSessionID(in: sessions)
    }

    private var shouldShowSessionHistoryButton: Bool {
        viewModel.shouldShowSessionHistoryButton(in: sessions)
    }

    private var shouldShowLanguagePickerHero: Bool {
        viewModel.shouldShowLanguagePickerHero(in: sessions)
    }

    private var shouldShowNewSessionButton: Bool {
        viewModel.shouldShowNewSessionButton(in: sessions)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()

            if shouldShowLanguagePickerHero {
                Button {
                    languageSheetMode = .targetOnly
                    viewModel.isLanguageSheetPresented = true
                } label: {
                    HomeHeroLanguageChip(
                        title: viewModel.selectedLanguage.displayName
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
                    HomeChatMessageBubble(message: message)
                        .id(message.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var toolbarContent: some View {
        toolbarLanguagePickerButton
    }

    private var sessionHistoryToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: "历史会话",
            isEnabled: shouldShowSessionHistoryButton,
            action: viewModel.openSessionHistory
        ) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
        }
    }

    private var newSessionToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: "新增会话",
            isEnabled: shouldShowNewSessionButton,
            action: viewModel.startNewSession
        ) {
            Image(systemName: "square.and.pencil")
                .font(.body.weight(.semibold))
        }
    }

    private var downloadToolbarButton: some View {
        toolbarIconButton(
            accessibilityLabel: viewModel.isInstallingTranslationModel ? "正在下载语言包" : "下载语言包",
            isEnabled: viewModel.canStartDownloadFromToolbar,
            action: viewModel.presentDownloadPrompt
        ) {
            HomeDownloadToolbarIcon(isDownloading: viewModel.isInstallingTranslationModel)
        }
    }

    private var toolbarLanguagePickerButton: some View {
        Button {
            languageSheetMode = .full
            viewModel.isLanguageSheetPresented = true
        } label: {
            HomeToolbarTranslationItem(
                sourceTitle: viewModel.sourceLanguage.displayName,
                targetTitle: viewModel.selectedLanguage.displayName
            )
            .frame(maxWidth: 250)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("翻译语言")
        .accessibilityValue("\(viewModel.sourceLanguage.displayName)到\(viewModel.selectedLanguage.displayName)")
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
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Image(systemName: isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(isDownloading ? Color.accentColor : Color.primary)

            if isDownloading {
                ZStack {
                    animatedArrow(delay: 0)
                    animatedArrow(delay: 0.45)
                }
                .frame(width: 18, height: 18)
                .clipped()
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
    let catalogService = TranslationModelCatalogService(remoteCatalogURL: nil, bundle: .main)
    let installer = TranslationModelInstaller(catalogService: catalogService)
    HomeView(
        appSettings: AppSettings(userDefaults: UserDefaults(suiteName: "HomeViewPreview") ?? .standard),
        translationService: MarianTranslationService(installer: installer),
        translationModelInstaller: installer,
        speechRecognitionService: WhisperSpeechRecognitionService(
            installer: SpeechModelInstaller(
                catalogService: SpeechModelCatalogService(remoteCatalogURL: nil, bundle: .main)
            )
        ),
        speechModelInstaller: SpeechModelInstaller(
            catalogService: SpeechModelCatalogService(remoteCatalogURL: nil, bundle: .main)
        ),
        microphoneRecordingService: MicrophoneRecordingService()
    )
        .modelContainer(for: [ChatSession.self, ChatMessage.self], inMemory: true)
}
