//
//  HomeView.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    private static let messageListBottomAnchorID = "home-message-list-bottom-anchor"
    private static let messageListBottomSpacing: CGFloat = 16
    private static let messageListBottomActionClearance: CGFloat = 44
    private static let chatInputHorizontalInset: CGFloat = 14
    private static let chatInputTopInset: CGFloat = 8
    private static let chatInputBottomInset: CGFloat = 10

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @State private var store: HomeStore
    @State private var chatInputBarHeight: CGFloat = 0
    @State private var isMessageListNearBottom = true

    init(dependencies: HomeDependencies) {
        _store = State(
            initialValue: HomeStore(
                dependencies: dependencies
            )
        )
    }

    var body: some View {
        let viewState = currentViewState
        let messageIDsKey = viewState.messageItems.map(\.id)
        let lastMessageAutoScrollKey =
            "\(viewState.messageItems.last?.renderKey ?? "")|\(messageListBottomSpacerHeight)"

        ZStack {
            homeBackground(for: viewState)
                .ignoresSafeArea()

            NavigationStack {
                ScrollViewReader { proxy in
                    HomeConversationContentView(
                        viewState: viewState,
                        selectedLanguage: store.selectedLanguage,
                        messageListBottomAnchorID: Self.messageListBottomAnchorID,
                        messageListBottomSpacerHeight: messageListBottomSpacerHeight,
                        immersiveVoiceTranslationState: viewState.immersiveVoiceTranslationState,
                        onOpenLanguagePicker: {
                            store.presentGlobalTargetLanguagePicker()
                        },
                        onDismissInputFocus: dismissChatInputFocus,
                        onTranslatedPlayback: { message in
                            store.toggleTranslatedPlayback(message: message)
                        },
                        onRetrySpeechTranslation: { message in
                            store.retrySpeechTranslation(
                                for: message,
                                in: runtimeContext
                            )
                        },
                        onSourcePlayback: { message in
                            store.toggleSourcePlayback(message: message)
                        },
                        onSpeechTranscriptToggle: { message in
                            store.toggleSpeechTranscript(for: message)
                        },
                        onSourceLanguageSelection: { message in
                            store.presentMessageLanguagePicker(
                                for: message,
                                side: .source
                            )
                        },
                        onTargetLanguageSelection: { message in
                            store.presentMessageLanguagePicker(
                                for: message,
                                side: .target
                            )
                        },
                        onMessageListBottomProximityChanged: { isNearBottom in
                            isMessageListNearBottom = isNearBottom

                            guard isNearBottom, !viewState.messageItems.isEmpty else {
                                return
                            }

                            scrollToBottom(with: proxy, animated: false)
                        }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        HomeToolbarContent(
                            state: viewState.toolbar,
                            onOpenSessionHistory: store.openSessionHistory,
                            onOpenDownloadManager: store.openDownloadManager,
                            onStartNewSession: store.startNewSession
                        )
                    }
                    .onAppear {
                        store.onAppear(in: runtimeContext)
                        scrollToBottom(with: proxy, animated: false)
                    }
                    .onChange(of: messageIDsKey) { _, _ in
                        isMessageListNearBottom = true
                        scrollToBottom(with: proxy)
                    }
                    .onChange(of: lastMessageAutoScrollKey) { _, _ in
                        guard isMessageListNearBottom else { return }
                        scrollToBottom(with: proxy)
                    }
                    .onChange(of: chatInputBarHeight) { oldValue, newValue in
                        guard
                            !viewState.shouldShowEmptyState,
                            oldValue != newValue,
                            isMessageListNearBottom
                        else {
                            return
                        }

                        scrollToBottom(with: proxy, animated: false)
                    }
                }
                .navigationDestination(isPresented: binding(\.isDownloadManagerPresented)) {
                    downloadManagerView
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .homePresentation(
            store: store,
            viewState: viewState,
            runtimeContext: runtimeContext
        )
        .task {
            await store.refreshDownloadAvailabilityForCurrentSelection()
        }
        .onChange(of: store.isShowingLanguageSheet) { _, isPresented in
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
        .onPreferenceChange(HomeChatInputBarHeightPreferenceKey.self) { height in
            chatInputBarHeight = height
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.isDownloadManagerPresented {
                HomeChatInputBar(
                    text: binding(\.messageText),
                    isFocused: binding(\.isChatInputFocused),
                    isRecordingSpeech: store.isRecordingSpeech,
                    isSpeechBusy: store.isTranscribingSpeech || store.isInstallingSpeechModel,
                    isImmersiveVoiceModeActive: viewState.immersiveVoiceTranslationState != nil,
                    onFocusActivated: store.handleInputFocusActivated,
                    onSend: {
                        store.sendCurrentMessage(in: runtimeContext)
                    },
                    onVoiceInput: {
                        Task {
                            await store.toggleSpeechRecording(in: runtimeContext)
                        }
                    },
                    onImmersiveVoiceInput: {
                        Task {
                            await store.startImmersiveVoiceTranslation(in: runtimeContext)
                        }
                    }
                )
                .padding(.horizontal, Self.chatInputHorizontalInset)
                .padding(.top, Self.chatInputTopInset)
                .padding(.bottom, Self.chatInputBottomInset)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: HomeChatInputBarHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                    }
                }
            }
        }
    }

    private var runtimeContext: HomeRuntimeContext {
        HomeRuntimeContext(
            modelContext: modelContext,
            sessions: sessions
        )
    }

    private var currentViewState: HomeStore.ViewState {
        store.makeViewState(in: runtimeContext)
    }

    @ViewBuilder
    private func homeBackground(for viewState: HomeStore.ViewState) -> some View {
        if viewState.immersiveVoiceTranslationState != nil {
            ZStack {
                Color(uiColor: .systemBackground)

                RadialGradient(
                    colors: [
                        Color.accentColor.opacity(0.14),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 40,
                    endRadius: 420
                )
            }
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }

    private var messageListBottomSpacerHeight: CGFloat {
        guard !store.isDownloadManagerPresented else { return 0 }
        return chatInputBarHeight
            + Self.messageListBottomSpacing
            + Self.messageListBottomActionClearance
    }

    private var downloadManagerView: some View {
        let downloadManagerState = currentViewState.downloadManager

        return ModelAssetsView(
            isLoading: downloadManagerState.isLoading,
            processingRecords: downloadManagerState.processingRecords,
            resumableRecords: downloadManagerState.resumableRecords,
            failedRecords: downloadManagerState.failedRecords,
            installedRecords: downloadManagerState.installedRecords,
            availableRecords: downloadManagerState.availableRecords,
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

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<HomeStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { store[keyPath: keyPath] = $0 }
        )
    }

    private func dismissChatInputFocus() {
        guard store.isChatInputFocused else { return }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            store.isChatInputFocused = false
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard !currentViewState.shouldShowEmptyState else { return }

        let action = {
            proxy.scrollTo(Self.messageListBottomAnchorID, anchor: .bottom)
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

private struct HomeChatInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
            audioFilePlaybackService: SystemAudioFilePlaybackService(),
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: translationPackageManager,
            translationModelInventoryProvider: translationPackageManager,
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )
    )
    .modelContainer(for: [ChatSession.self, ChatMessage.self], inMemory: true)
}
