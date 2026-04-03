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

    @State private var selectedLanguage: HomeLanguage = .english
    @State private var isLanguageSheetPresented = false
    @State private var messageText = ""
    @State private var isChatInputFocused = false
    @State private var currentSessionID: UUID?

    var body: some View {
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
                    if isChatInputFocused {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            isChatInputFocused = false
                        }
                    }
                }
                .toolbar(isChatInputFocused ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if isChatInputFocused {
                        ToolbarItem(placement: .principal) {
                            toolbarContent
                                .transition(surfaceTransition)
                        }
                    }
                }
                .animation(surfaceAnimation, value: isChatInputFocused)
                .onAppear {
                    removeEmptySessions()
                    scrollToBottom(with: proxy, animated: false)
                }
                .onChange(of: displayedMessageIDs) { _, _ in
                    scrollToBottom(with: proxy)
                }
                .onChange(of: isChatInputFocused) { oldValue, newValue in
                    if oldValue && !newValue {
                        discardEmptyCurrentSessionIfNeeded()
                    }
                }
            }
        }
        .sheet(isPresented: $isLanguageSheetPresented) {
            HomeLanguageSheet(
                selectedLanguage: $selectedLanguage,
                isPresented: $isLanguageSheetPresented
            )
        }
        .safeAreaInset(edge: .bottom) {
            HomeChatInputBar(
                text: $messageText,
                isFocused: $isChatInputFocused,
                onFocusActivated: handleInputFocusActivated,
                onSend: sendCurrentMessage
            )
        }
    }

    private var currentSession: ChatSession? {
        if let currentSessionID {
            return sessions.first { $0.id == currentSessionID }
        }

        return latestNonEmptySession
    }

    private var latestNonEmptySession: ChatSession? {
        sessions.first { $0.hasMessages }
    }

    private var displayedMessages: [ChatMessage] {
        currentSession?.sortedMessages ?? []
    }

    private var displayedMessageIDs: [UUID] {
        displayedMessages.map(\.id)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()

            if !isChatInputFocused {
                Button {
                    isLanguageSheetPresented = true
                } label: {
                    HomeLanguageChip(
                        title: selectedLanguage.displayName,
                        style: .hero
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .transition(surfaceTransition)
                .animation(surfaceAnimation.delay(0.02), value: isChatInputFocused)
            }

            ZStack {
                if isChatInputFocused {
                    Text("开始新的对话")
                        .id("focused-empty-state")
                        .transition(surfaceTransition)
                } else {
                    Text("点击下方输入框开始新的对话")
                        .id("unfocused-empty-state")
                        .transition(surfaceTransition)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .animation(surfaceAnimation.delay(0.06), value: isChatInputFocused)

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
        HStack(spacing: 10) {
            HomeLanguageChip(
                title: HomeLanguage.chinese.displayName,
                style: .toolbar
            )

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                isLanguageSheetPresented = true
            } label: {
                HomeLanguageChip(
                    title: selectedLanguage.displayName,
                    style: .toolbar
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var surfaceAnimation: Animation {
        .spring(response: 0.68, dampingFraction: 0.84, blendDuration: 0.18)
    }

    private var surfaceTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: HomeSurfaceMotionModifier(offsetY: 30, scale: 0.96, opacity: 0, blurRadius: 8),
                identity: HomeSurfaceMotionModifier(offsetY: 0, scale: 1, opacity: 1, blurRadius: 0)
            ),
            removal: .modifier(
                active: HomeSurfaceMotionModifier(offsetY: 26, scale: 0.97, opacity: 0, blurRadius: 10),
                identity: HomeSurfaceMotionModifier(offsetY: 0, scale: 1, opacity: 1, blurRadius: 0)
            )
        )
    }

    private func handleInputFocusActivated() {
        discardEmptyCurrentSessionIfNeeded()
        createNewSession()
    }

    @discardableResult
    private func createNewSession() -> ChatSession {
        let session = ChatSession()
        modelContext.insert(session)
        currentSessionID = session.id
        saveContext()
        return session
    }

    private func discardEmptyCurrentSessionIfNeeded() {
        guard let currentSessionID,
              let session = sessions.first(where: { $0.id == currentSessionID }),
              !session.hasMessages else {
            return
        }

        modelContext.delete(session)
        self.currentSessionID = nil
        saveContext()
    }

    private func removeEmptySessions() {
        let emptySessions = sessions.filter { !$0.hasMessages }

        guard !emptySessions.isEmpty else { return }

        for session in emptySessions {
            modelContext.delete(session)
        }

        if let currentSessionID,
           emptySessions.contains(where: { $0.id == currentSessionID }) {
            self.currentSessionID = nil
        }

        saveContext()
    }

    private func sendCurrentMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let session = currentSessionID == nil ? createNewSession() : currentSession
        guard let session else { return }

        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let now = Date()
        let userMessage = ChatMessage(
            sender: .user,
            text: trimmedText,
            createdAt: now,
            sequence: nextSequence,
            session: session
        )
        let assistantMessage = ChatMessage(
            sender: .assistant,
            text: trimmedText,
            createdAt: now.addingTimeInterval(0.001),
            sequence: nextSequence + 1,
            session: session
        )

        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        session.updatedAt = assistantMessage.createdAt

        messageText = ""
        saveContext()
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save chat data: \(error)")
        }
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

private struct HomeSurfaceMotionModifier: ViewModifier {
    let offsetY: CGFloat
    let scale: CGFloat
    let opacity: Double
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .center)
            .offset(y: offsetY)
            .opacity(opacity)
            .blur(radius: blurRadius)
    }
}
