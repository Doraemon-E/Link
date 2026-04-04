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
    @State private var viewModel = HomeViewModel()
    @State private var languageSheetMode: HomeLanguageSheet.Mode = .full

    init() {}

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

                        ToolbarItem(placement: .topBarTrailing) {
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
                mode: languageSheetMode
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
        .safeAreaInset(edge: .bottom) {
            HomeChatInputBar(
                text: $viewModel.messageText,
                isFocused: $viewModel.isChatInputFocused,
                onFocusActivated: viewModel.handleInputFocusActivated,
                onSend: {
                    viewModel.sendCurrentMessage(using: modelContext, sessions: sessions)
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
                    HomeLanguageChip(
                        sourceTitle: nil,
                        targetTitle: viewModel.selectedLanguage.displayName,
                        style: .hero
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
            systemName: "line.3.horizontal",
            accessibilityLabel: "历史会话",
            isEnabled: shouldShowSessionHistoryButton,
            action: viewModel.openSessionHistory
        )
    }

    private var newSessionToolbarButton: some View {
        toolbarIconButton(
            systemName: "square.and.pencil",
            accessibilityLabel: "新增会话",
            isEnabled: shouldShowNewSessionButton,
            action: viewModel.startNewSession
        )
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

    private func toolbarIconButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
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

#Preview {
    HomeView()
        .modelContainer(for: [ChatSession.self, ChatMessage.self], inMemory: true)
}
