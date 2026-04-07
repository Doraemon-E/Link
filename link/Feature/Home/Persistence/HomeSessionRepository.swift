//
//  HomeSessionRepository.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData

@MainActor
final class HomeSessionRepository {
    static func localAudioFileURL(
        from audioURL: String?,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) -> URL? {
        guard let audioURL = audioURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioURL.isEmpty else {
            return nil
        }

        if let url = URL(string: audioURL), url.isFileURL {
            return url.standardizedFileURL
        }

        guard audioURL.hasPrefix("/") else {
            return try? SpeechRecordingStoragePaths.recordingFileURL(
                fromRelativePath: audioURL,
                fileManager: fileManager,
                applicationSupportURL: applicationSupportURL
            )
        }

        return URL(fileURLWithPath: audioURL).standardizedFileURL
    }

    func displayedMessages(
        in runtime: HomeRuntimeContext,
        presentation: HomeSessionPresentation
    ) -> [ChatMessage] {
        currentSession(in: runtime, presentation: presentation)?.sortedMessages ?? []
    }

    func currentSessionID(
        in runtime: HomeRuntimeContext,
        presentation: HomeSessionPresentation
    ) -> UUID? {
        currentSession(in: runtime, presentation: presentation)?.id
    }

    func currentSession(
        in runtime: HomeRuntimeContext,
        presentation: HomeSessionPresentation
    ) -> ChatSession? {
        switch presentation {
        case .draft:
            return nil
        case .persisted(let sessionID):
            return runtime.sessions.first { $0.id == sessionID } ?? latestNonEmptySession(in: runtime)
        case .none:
            return nil
        }
    }

    func latestNonEmptySession(in runtime: HomeRuntimeContext) -> ChatSession? {
        runtime.sessions.first { $0.hasMessages }
    }

    func message(
        id: UUID,
        in runtime: HomeRuntimeContext
    ) -> ChatMessage? {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { message in
                message.id == id
            }
        )

        return try? runtime.modelContext.fetch(descriptor).first
    }

    @discardableResult
    func createNewSession(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext,
        presentation: inout HomeSessionPresentation
    ) -> ChatSession {
        let session = ChatSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        runtime.modelContext.insert(session)
        presentation = .persisted(session.id)
        return session
    }

    func removeEmptySessions(
        in runtime: HomeRuntimeContext,
        presentation: inout HomeSessionPresentation
    ) {
        let emptySessions = runtime.sessions.filter { !$0.hasMessages }

        guard !emptySessions.isEmpty else { return }

        for session in emptySessions {
            runtime.modelContext.delete(session)
        }

        if case .persisted(let sessionID) = presentation,
           emptySessions.contains(where: { $0.id == sessionID }) {
            presentation = .none
        }

        saveContext(in: runtime)
    }

    @discardableResult
    func deleteSession(
        id: UUID,
        in runtime: HomeRuntimeContext
    ) -> Bool {
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { session in
                session.id == id
            }
        )

        guard let session = try? runtime.modelContext.fetch(descriptor).first else {
            return false
        }

        let audioFileURLs = Set(
            session.messages.compactMap { message in
                Self.localAudioFileURL(from: message.audioURL)
            }
        )

        runtime.modelContext.delete(session)

        do {
            try runtime.modelContext.save()
        } catch {
            print("Failed to delete chat session: \(error)")
            return false
        }

        let fileManager = FileManager.default
        for audioFileURL in audioFileURLs where fileManager.fileExists(atPath: audioFileURL.path) {
            try? fileManager.removeItem(at: audioFileURL)
        }

        return true
    }

    func resolveSession(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext,
        presentation: inout HomeSessionPresentation
    ) -> ChatSession {
        switch presentation {
        case .draft:
            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                in: runtime,
                presentation: &presentation
            )
        case .persisted(let sessionID):
            if let existingSession = runtime.sessions.first(where: { $0.id == sessionID }) {
                return existingSession
            }

            if let fallbackSession = latestNonEmptySession(in: runtime) {
                presentation = .persisted(fallbackSession.id)
                return fallbackSession
            }

            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                in: runtime,
                presentation: &presentation
            )
        case .none:
            return createNewSession(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                in: runtime,
                presentation: &presentation
            )
        }
    }

    func insertConversationExchange(
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        audioURL: String?,
        into session: ChatSession,
        in runtime: HomeRuntimeContext
    ) -> UUID {
        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            inputType: .text,
            sourceText: text,
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            audioURL: audioURL,
            createdAt: .now,
            sequence: nextSequence,
            session: session
        )

        runtime.modelContext.insert(message)
        session.updatedAt = message.createdAt
        saveContext(in: runtime)

        return message.id
    }

    func createLiveSpeechSession(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        in runtime: HomeRuntimeContext,
        presentation: inout HomeSessionPresentation
    ) -> HomeLiveSpeechSessionRecord {
        let session = resolveSession(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            in: runtime,
            presentation: &presentation
        )
        let nextSequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            inputType: .speech,
            sourceText: "",
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            createdAt: .now,
            sequence: nextSequence,
            session: session
        )

        runtime.modelContext.insert(message)
        session.updatedAt = message.createdAt
        saveContext(in: runtime)

        return HomeLiveSpeechSessionRecord(
            session: session,
            message: message,
            fallbackSourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func updateTranslatedMessage(
        id: UUID,
        text: String,
        in runtime: HomeRuntimeContext
    ) {
        _ = updateMessage(
            id: id,
            translatedText: text,
            in: runtime
        )
    }

    @discardableResult
    func updateMessage(
        id: UUID,
        sourceText: String? = nil,
        translatedText: String? = nil,
        sourceLanguage: SupportedLanguage? = nil,
        targetLanguage: SupportedLanguage? = nil,
        syncSessionLanguages: Bool = false,
        in runtime: HomeRuntimeContext
    ) -> ChatMessage? {
        guard let message = message(id: id, in: runtime) else {
            return nil
        }

        if let sourceText {
            message.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let translatedText {
            message.translatedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let sourceLanguage {
            message.sourceLanguage = sourceLanguage
        }

        if let targetLanguage {
            message.targetLanguage = targetLanguage
        }

        if syncSessionLanguages, let session = message.session {
            if let sourceLanguage {
                session.sourceLanguage = sourceLanguage
            }

            if let targetLanguage {
                session.targetLanguage = targetLanguage
            }
        }

        message.session?.updatedAt = .now
        saveContext(in: runtime)
        return message
    }

    func finalizeLiveSpeechTranscript(
        _ liveSpeechSession: HomeLiveSpeechSessionRecord,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        audioURL: String?,
        in runtime: HomeRuntimeContext
    ) {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        liveSpeechSession.message.sourceText = normalizedTranscript
        liveSpeechSession.message.sourceLanguage = sourceLanguage
        liveSpeechSession.message.targetLanguage = liveSpeechSession.targetLanguage
        liveSpeechSession.message.translatedText = ""
        liveSpeechSession.message.audioURL = audioURL
        liveSpeechSession.session.updatedAt = .now

        saveContext(in: runtime)
    }

    func updateSessionLanguages(
        _ session: ChatSession,
        sourceLanguage: SupportedLanguage? = nil,
        targetLanguage: SupportedLanguage? = nil,
        in runtime: HomeRuntimeContext
    ) {
        if let sourceLanguage {
            session.sourceLanguage = sourceLanguage
        }

        if let targetLanguage {
            session.targetLanguage = targetLanguage
        }

        session.updatedAt = .now
        saveContext(in: runtime)
    }

    func finalizeLiveSpeechSession(
        _ liveSpeechSession: HomeLiveSpeechSessionRecord,
        transcript: String,
        translatedText: String,
        sourceLanguage: SupportedLanguage,
        audioURL: String?,
        in runtime: HomeRuntimeContext
    ) {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        liveSpeechSession.message.sourceText = normalizedTranscript
        liveSpeechSession.message.sourceLanguage = sourceLanguage
        liveSpeechSession.message.translatedText = normalizedTranslation
        liveSpeechSession.message.targetLanguage = liveSpeechSession.targetLanguage
        liveSpeechSession.message.audioURL = audioURL
        liveSpeechSession.session.updatedAt = .now

        saveContext(in: runtime)
    }

    func discardLiveSpeechSession(
        _ liveSpeechSession: HomeLiveSpeechSessionRecord,
        in runtime: HomeRuntimeContext,
        presentation: inout HomeSessionPresentation
    ) {
        runtime.modelContext.delete(liveSpeechSession.message)
        let remainingMessages = liveSpeechSession.session.messages.filter {
            $0.id != liveSpeechSession.message.id
        }

        if remainingMessages.isEmpty {
            runtime.modelContext.delete(liveSpeechSession.session)
            if case .persisted(let sessionID) = presentation,
               sessionID == liveSpeechSession.session.id {
                presentation = .none
            }
        }

        saveContext(in: runtime)
    }

    private func saveContext(in runtime: HomeRuntimeContext) {
        do {
            try runtime.modelContext.save()
        } catch {
            print("Failed to save chat data: \(error)")
        }
    }
}
