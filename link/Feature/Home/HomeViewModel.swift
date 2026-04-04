//
//  HomeViewModel.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HomeViewModel {
    enum SessionPresentation: Equatable {
        case none
        case draft
        case persisted(UUID)
    }

    var sourceLanguage: HomeLanguage = .chinese
    var selectedLanguage: HomeLanguage = .english
    var isLanguageSheetPresented = false
    var isSessionHistoryPresented = false
    var messageText = ""
    var isChatInputFocused = false
    var sessionPresentation: SessionPresentation = .none

    func onAppear(using modelContext: ModelContext, sessions: [ChatSession]) {
        removeEmptySessions(using: modelContext, sessions: sessions)
    }

    func displayedMessages(in sessions: [ChatSession]) -> [ChatMessage] {
        guard !isDraftSession else { return [] }
        return currentSession(in: sessions)?.sortedMessages ?? []
    }

    func displayedMessageIDs(in sessions: [ChatSession]) -> [UUID] {
        displayedMessages(in: sessions).map(\.id)
    }

    func shouldShowNavigationBar(in sessions: [ChatSession]) -> Bool {
        isChatInputFocused || currentSession(in: sessions) != nil
    }

    func shouldShowSessionHistoryButton(in sessions: [ChatSession]) -> Bool {
        latestNonEmptySession(in: sessions) != nil
    }

    func shouldShowNewSessionButton(in sessions: [ChatSession]) -> Bool {
        !isDraftSession && currentSession(in: sessions) != nil
    }

    func shouldShowLanguagePickerHero(in sessions: [ChatSession]) -> Bool {
        !isChatInputFocused && currentSession(in: sessions) == nil
    }

    func currentSessionID(in sessions: [ChatSession]) -> UUID? {
        currentSession(in: sessions)?.id
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
        sessionPresentation = .draft
    }

    func selectSession(id sessionID: UUID) {
        sessionPresentation = .persisted(sessionID)
        isChatInputFocused = false

        DispatchQueue.main.async {
            self.isSessionHistoryPresented = false
        }
    }

    func sendCurrentMessage(using modelContext: ModelContext, sessions: [ChatSession]) {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let session: ChatSession
        switch sessionPresentation {
        case .draft:
            session = createNewSession(using: modelContext)
        case .persisted(let sessionID):
            if let existingSession = sessions.first(where: { $0.id == sessionID }) {
                session = existingSession
            } else if let fallbackSession = latestNonEmptySession(in: sessions) {
                session = fallbackSession
                sessionPresentation = .persisted(fallbackSession.id)
            } else {
                session = createNewSession(using: modelContext)
            }
        case .none:
            session = createNewSession(using: modelContext)
        }

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
        saveContext(using: modelContext)
    }

    private var isDraftSession: Bool {
        if case .draft = sessionPresentation {
            return true
        }

        return false
    }

    private func currentSession(in sessions: [ChatSession]) -> ChatSession? {
        switch sessionPresentation {
        case .draft:
            return nil
        case .persisted(let sessionID):
            return sessions.first { $0.id == sessionID } ?? latestNonEmptySession(in: sessions)
        case .none:
            return nil
        }
    }

    private func latestNonEmptySession(in sessions: [ChatSession]) -> ChatSession? {
        sessions.first { $0.hasMessages }
    }

    @discardableResult
    private func createNewSession(using modelContext: ModelContext) -> ChatSession {
        let session = ChatSession()
        modelContext.insert(session)
        sessionPresentation = .persisted(session.id)
        return session
    }

    private func removeEmptySessions(using modelContext: ModelContext, sessions: [ChatSession]) {
        let emptySessions = sessions.filter { !$0.hasMessages }

        guard !emptySessions.isEmpty else { return }

        for session in emptySessions {
            modelContext.delete(session)
        }

        if case .persisted(let sessionID) = sessionPresentation,
           emptySessions.contains(where: { $0.id == sessionID }) {
            sessionPresentation = .none
        }

        saveContext(using: modelContext)
    }

    private func saveContext(using modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save chat data: \(error)")
        }
    }
}
