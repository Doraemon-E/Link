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

    @ObservationIgnored private let translationService: TranslationService
    @ObservationIgnored private let translationModelInstaller: TranslationModelInstaller
    @ObservationIgnored private let logger = AppLogger.viewModel

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
        let traceID = AppTrace.newTraceID()

        logger.info(
            "Queued translation request",
            metadata: [
                "assistant_message_id": assistantMessageID.uuidString,
                "input_length": "\(trimmedText.count)",
                "source_language": sourceLanguage.translationModelCode,
                "target_language": targetLanguage.translationModelCode,
                "trace_id": traceID
            ]
        )

        Task { @MainActor in
            await resolveTranslation(
                traceID: traceID,
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
        let traceID = AppTrace.newTraceID()
        let startedAt = Date()

        return await AppTrace.withTrace(
            traceID: traceID,
            metadata: Self.languageMetadata(source: source, target: target)
        ) {
            logger.info("Resolving language selection")

            guard source != target else {
                logger.info(
                    "Language selection resolved without download",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "resolution": "same_language"
                    ]
                )
                return .ready
            }

            do {
                if try await translationModelInstaller.isInstalled(source: source, target: target) {
                    logger.info(
                        "Language selection resolved without download",
                        metadata: [
                            "duration_ms": appElapsedMilliseconds(since: startedAt),
                            "resolution": "installed"
                        ]
                    )
                    return .ready
                }

                guard let package = try await translationModelInstaller.packageMetadata(source: source, target: target) else {
                    logger.error(
                        "Language selection failed because package metadata is unavailable",
                        metadata: ["duration_ms": appElapsedMilliseconds(since: startedAt)]
                    )
                    return .failure(
                        TranslationError
                            .modelPackageUnavailable(source: source, target: target)
                            .userFacingMessage
                    )
                }

                logger.info(
                    "Language selection requires download",
                    metadata: [
                        "archive_size": "\(package.archiveSize)",
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "installed_size": "\(package.installedSize)",
                        "package_id": package.packageId
                    ]
                )

                return .requiresDownload(
                    HomeLanguageDownloadPrompt(
                        packageId: package.packageId,
                        sourceLanguage: source,
                        targetLanguage: target,
                        archiveSize: package.archiveSize,
                        installedSize: package.installedSize
                    )
                )
            } catch let error as TranslationError {
                logger.error(
                    "Language selection resolution failed",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error)
                    ]
                )
                return .failure(error.userFacingMessage)
            } catch {
                logger.error(
                    "Language selection resolution failed",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error)
                    ]
                )
                return .failure("暂时无法检查翻译模型，请稍后再试。")
            }
        }
    }

    func installTranslationModel(packageId: String) async throws {
        let startedAt = Date()

        try await AppTrace.withTrace(
            metadata: ["package_id": packageId]
        ) {
            logger.info("User initiated translation model installation")

            do {
                _ = try await translationModelInstaller.install(packageId: packageId)
                logger.info(
                    "User initiated translation model installation finished",
                    metadata: ["duration_ms": appElapsedMilliseconds(since: startedAt)]
                )
            } catch {
                logger.error(
                    "User initiated translation model installation failed",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error)
                    ]
                )
                throw error
            }
        }
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
            logger.error(
                "Failed to save chat data",
                metadata: ["error": appLogErrorDescription(error)]
            )
        }
    }

    private func resolveTranslation(
        traceID: String,
        for assistantMessageID: UUID,
        originalText: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage,
        using modelContext: ModelContext
    ) async {
        let startedAt = Date()

        await AppTrace.withTrace(
            traceID: traceID,
            metadata: Self.translationRequestMetadata(
                assistantMessageID: assistantMessageID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        ) {
            logger.info(
                "Translation request started",
                metadata: ["input_length": "\(originalText.count)"]
            )

            do {
                let translatedText = try await translationService.translate(
                    text: originalText,
                    source: sourceLanguage,
                    target: targetLanguage
                )

                logger.info(
                    "Translation request finished",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "output_length": "\(translatedText.count)",
                        "status": "success"
                    ]
                )

                updateAssistantMessage(
                    id: assistantMessageID,
                    text: translatedText,
                    using: modelContext
                )
            } catch let error as TranslationError {
                logger.error(
                    "Translation request finished with translation error",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error),
                        "status": "translation_error"
                    ]
                )

                updateAssistantMessage(
                    id: assistantMessageID,
                    text: error.userFacingMessage,
                    using: modelContext
                )
            } catch {
                logger.error(
                    "Translation request finished with unexpected error",
                    metadata: [
                        "duration_ms": appElapsedMilliseconds(since: startedAt),
                        "error": appLogErrorDescription(error),
                        "status": "unexpected_error"
                    ]
                )

                updateAssistantMessage(
                    id: assistantMessageID,
                    text: "翻译失败了，请稍后再试。",
                    using: modelContext
                )
            }
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
            logger.error(
                "Assistant message update skipped because message was not found",
                metadata: ["assistant_message_id": id.uuidString]
            )
            return
        }

        message.text = text
        message.session?.updatedAt = .now
        saveContext(using: modelContext)
    }

    private static func languageMetadata(
        source: HomeLanguage,
        target: HomeLanguage
    ) -> [String: String] {
        [
            "source_language": source.translationModelCode,
            "target_language": target.translationModelCode
        ]
    }

    private static func translationRequestMetadata(
        assistantMessageID: UUID,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> [String: String] {
        languageMetadata(source: sourceLanguage, target: targetLanguage).merging(
            ["assistant_message_id": assistantMessageID.uuidString],
            uniquingKeysWith: { _, newValue in newValue }
        )
    }
}
