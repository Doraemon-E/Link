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
    var downloadableLanguagePrompt: HomeLanguageDownloadPrompt?
    var deferredDownloadPrompt: HomeLanguageDownloadPrompt?
    var activeDownloadPrompt: HomeLanguageDownloadPrompt?
    var downloadErrorMessage: String?
    var isInstallingTranslationModel = false

    @ObservationIgnored private let translationService: TranslationService
    @ObservationIgnored private let translationModelInstaller: TranslationModelInstaller
    init(
        translationService: TranslationService,
        translationModelInstaller: TranslationModelInstaller
    ) {
        self.translationService = translationService
        self.translationModelInstaller = translationModelInstaller
    }

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
            text: "翻译中…",
            createdAt: now.addingTimeInterval(0.001),
            sequence: nextSequence + 1,
            session: session
        )

        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        session.updatedAt = assistantMessage.createdAt

        messageText = ""
        saveContext(using: modelContext)

        let assistantMessageID = assistantMessage.id
        let sourceLanguage = sourceLanguage
        let targetLanguage = selectedLanguage

        Task { @MainActor in
            await resolveTranslation(
                for: assistantMessageID,
                originalText: trimmedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                using: modelContext
            )
        }
    }

    func resolveLanguageSelection(
        source: HomeLanguage,
        target: HomeLanguage
    ) async -> HomeLanguageSelectionResolution {
        do {
            let route = try await translationService.route(source: source, target: target)

            if !route.requiresModelDownload {
                return .ready
            }

            return .requiresDownload(HomeLanguageDownloadPrompt(route: route))
        } catch let error as TranslationError {
            return .failure(error.userFacingMessage)
        } catch {
            return .failure("暂时无法检查翻译模型，请稍后再试。")
        }
    }

    func commitLanguageSelection(source: HomeLanguage, target: HomeLanguage) {
        sourceLanguage = source
        selectedLanguage = target
        downloadableLanguagePrompt = nil
        deferredDownloadPrompt = nil
        activeDownloadPrompt = nil
    }

    func commitLanguageSelectionRequiringDownload(
        source: HomeLanguage,
        target: HomeLanguage,
        prompt: HomeLanguageDownloadPrompt
    ) {
        sourceLanguage = source
        selectedLanguage = target
        downloadableLanguagePrompt = prompt
        deferredDownloadPrompt = prompt
        activeDownloadPrompt = nil
    }

    func presentDeferredDownloadPromptIfNeeded() {
        guard !isLanguageSheetPresented, let deferredDownloadPrompt else { return }

        activeDownloadPrompt = deferredDownloadPrompt
        self.deferredDownloadPrompt = nil
    }

    func presentDownloadPrompt() {
        guard !isInstallingTranslationModel, let downloadableLanguagePrompt else { return }
        activeDownloadPrompt = downloadableLanguagePrompt
    }

    func dismissDownloadPrompt() {
        activeDownloadPrompt = nil
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
        let source = sourceLanguage
        let target = selectedLanguage
        let prompt = await downloadPromptIfNeeded(source: source, target: target)

        guard source == sourceLanguage, target == selectedLanguage else {
            return
        }

        downloadableLanguagePrompt = prompt

        if prompt == nil {
            deferredDownloadPrompt = nil
            activeDownloadPrompt = nil
        }
    }

    func installTranslationModel(packageIds: [String]) async {
        guard !isInstallingTranslationModel else { return }
        guard !packageIds.isEmpty else { return }

        isInstallingTranslationModel = true
        downloadErrorMessage = nil
        activeDownloadPrompt = nil

        defer {
            isInstallingTranslationModel = false
        }

        do {
            for packageId in packageIds {
                _ = try await translationModelInstaller.install(packageId: packageId)
            }

            await refreshDownloadAvailabilityForCurrentSelection()
        } catch let error as TranslationError {
            print("[HomeViewModel] installTranslationModel failed for packageIds=\(packageIds.joined(separator: ",")): \(error.localizedDescription)")
            downloadErrorMessage = error.userFacingMessage
            await refreshDownloadAvailabilityForCurrentSelection()
        } catch {
            print("[HomeViewModel] installTranslationModel failed for packageIds=\(packageIds.joined(separator: ",")): \(error.localizedDescription)")
            downloadErrorMessage = "模型下载失败，请稍后重试。"
            await refreshDownloadAvailabilityForCurrentSelection()
        }
    }

    var shouldShowDownloadToolbarButton: Bool {
        isInstallingTranslationModel || downloadableLanguagePrompt != nil
    }

    var canStartDownloadFromToolbar: Bool {
        !isInstallingTranslationModel && downloadableLanguagePrompt != nil
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

    private func resolveTranslation(
        for assistantMessageID: UUID,
        originalText: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
        using modelContext: ModelContext
    ) async {
        do {
            let translatedText = try await translationService.translate(
                text: originalText,
                source: sourceLanguage,
                target: targetLanguage
            )

            updateAssistantMessage(
                id: assistantMessageID,
                text: translatedText,
                using: modelContext
            )
        } catch let error as TranslationError {
            updateAssistantMessage(
                id: assistantMessageID,
                text: error.userFacingMessage,
                using: modelContext
            )
        } catch {
            updateAssistantMessage(
                id: assistantMessageID,
                text: "翻译失败了，请稍后再试。",
                using: modelContext
            )
        }
    }

    private func updateAssistantMessage(
        id: UUID,
        text: String,
        using modelContext: ModelContext
    ) {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { message in
                message.id == id
            }
        )

        guard let message = try? modelContext.fetch(descriptor).first else {
            return
        }

        message.text = text
        message.session?.updatedAt = .now
        saveContext(using: modelContext)
    }

    private func downloadPromptIfNeeded(
        source: HomeLanguage,
        target: HomeLanguage
    ) async -> HomeLanguageDownloadPrompt? {
        do {
            let route = try await translationService.route(source: source, target: target)

            if !route.requiresModelDownload {
                return nil
            }

            return HomeLanguageDownloadPrompt(route: route)
        } catch {
            return nil
        }
    }

}
