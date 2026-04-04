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
                .toolbar(shouldShowNavigationBar ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if shouldShowNavigationBar {
                        if shouldShowSessionHistoryButton {
                            ToolbarItem(placement: .topBarLeading) {
                                sessionHistoryToolbarButton
                            }
                        } else if shouldShowNewSessionButton {
                            ToolbarItem(placement: .topBarLeading) {
                                toolbarButtonPlaceholder
                            }
                        }

                        ToolbarItem(placement: .principal) {
                            toolbarContent
                        }

                        if shouldShowNewSessionButton {
                            ToolbarItem(placement: .topBarTrailing) {
                                newSessionToolbarButton
                            }
                        } else if shouldShowSessionHistoryButton {
                            ToolbarItem(placement: .topBarTrailing) {
                                toolbarButtonPlaceholder
                            }
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
                isPresented: $viewModel.isLanguageSheetPresented
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
                    viewModel.isLanguageSheetPresented = true
                } label: {
                    HomeLanguageChip(
                        sourceTitle: viewModel.sourceLanguage.displayName,
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
        Button {
            viewModel.openSessionHistory()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("历史会话")
    }

    private var newSessionToolbarButton: some View {
        Button {
            viewModel.startNewSession()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("新增会话")
    }

    private var toolbarButtonPlaceholder: some View {
        Image(systemName: "square.and.pencil")
            .frame(width: 20, height: 20)
            .frame(width: 44, height: 44)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var toolbarLanguagePickerButton: some View {
        Button {
            viewModel.isLanguageSheetPresented = true
        } label: {
            ViewThatFits(in: .horizontal) {
                HomeLanguageChip(
                    sourceTitle: viewModel.sourceLanguage.displayName,
                    targetTitle: viewModel.selectedLanguage.displayName,
                    style: .toolbar
                )

                HomeLanguageChip(
                    sourceTitle: viewModel.sourceLanguage.compactDisplayName,
                    targetTitle: viewModel.selectedLanguage.displayName,
                    style: .toolbar
                )

                toolbarLanguagePickerCompactLabel(
                    sourceTitle: viewModel.sourceLanguage.compactDisplayName,
                    targetTitle: viewModel.selectedLanguage.compactDisplayName
                )
            }
            .frame(maxWidth: 220)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color(uiColor: .separator).opacity(0.2))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("翻译语言")
        .accessibilityValue("\(viewModel.sourceLanguage.displayName)到\(viewModel.selectedLanguage.displayName)")
    }

    private func toolbarLanguagePickerCompactLabel(sourceTitle: String, targetTitle: String) -> some View {
        HStack(spacing: 6) {
            Text(sourceTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(targetTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
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
