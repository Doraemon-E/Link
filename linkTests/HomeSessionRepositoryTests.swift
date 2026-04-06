//
//  HomeSessionRepositoryTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData
import XCTest
@testable import link

@MainActor
final class HomeSessionRepositoryTests: XCTestCase {
    func testDeleteSessionRemovesMessagesAndLocalAudioFiles() throws {
        let repository = HomeSessionRepository()
        let modelContext = try makeModelContext()
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURLAudio = directoryURL.appendingPathComponent("file-url-audio.caf", isDirectory: false)
        let absolutePathAudio = directoryURL.appendingPathComponent("absolute-path-audio.caf", isDirectory: false)
        FileManager.default.createFile(atPath: fileURLAudio.path, contents: Data("first".utf8))
        FileManager.default.createFile(atPath: absolutePathAudio.path, contents: Data("second".utf8))

        let session = ChatSession(sourceLanguage: .english, targetLanguage: .chinese)
        let firstMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Hello",
            translatedText: "你好",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: fileURLAudio.absoluteString,
            sequence: 0,
            session: session
        )
        let secondMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Thanks",
            translatedText: "谢谢",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            audioURL: absolutePathAudio.path,
            sequence: 1,
            session: session
        )

        modelContext.insert(session)
        modelContext.insert(firstMessage)
        modelContext.insert(secondMessage)
        try modelContext.save()

        XCTAssertTrue(
            repository.deleteSession(
                id: session.id,
                in: runtimeContext(modelContext: modelContext)
            )
        )

        XCTAssertTrue(try fetchSessions(in: modelContext).isEmpty)
        XCTAssertTrue(try fetchMessages(in: modelContext).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURLAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absolutePathAudio.path))
    }

    func testDeleteSessionIgnoresMissingAndNonLocalAudioURLs() throws {
        let repository = HomeSessionRepository()
        let modelContext = try makeModelContext()
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let missingAudioPath = directoryURL
            .appendingPathComponent("missing-audio.caf", isDirectory: false)
            .path

        let session = ChatSession(sourceLanguage: .japanese, targetLanguage: .english)
        let missingFileMessage = ChatMessage(
            inputType: .speech,
            sourceText: "こんにちは",
            translatedText: "Hello",
            sourceLanguage: .japanese,
            targetLanguage: .english,
            audioURL: missingAudioPath,
            sequence: 0,
            session: session
        )
        let remoteFileMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Bonsoir",
            translatedText: "Good evening",
            sourceLanguage: .french,
            targetLanguage: .english,
            audioURL: "https://example.com/audio.caf",
            sequence: 1,
            session: session
        )
        let invalidAudioMessage = ChatMessage(
            inputType: .speech,
            sourceText: "Hola",
            translatedText: "Hi",
            sourceLanguage: .spanish,
            targetLanguage: .english,
            audioURL: "not-a-local-url",
            sequence: 2,
            session: session
        )

        modelContext.insert(session)
        modelContext.insert(missingFileMessage)
        modelContext.insert(remoteFileMessage)
        modelContext.insert(invalidAudioMessage)
        try modelContext.save()

        XCTAssertTrue(
            repository.deleteSession(
                id: session.id,
                in: runtimeContext(modelContext: modelContext)
            )
        )

        XCTAssertTrue(try fetchSessions(in: modelContext).isEmpty)
        XCTAssertTrue(try fetchMessages(in: modelContext).isEmpty)
    }

    private func makeModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func runtimeContext(modelContext: ModelContext) -> HomeRuntimeContext {
        HomeRuntimeContext(
            modelContext: modelContext,
            sessions: (try? fetchSessions(in: modelContext)) ?? []
        )
    }

    private func fetchSessions(in modelContext: ModelContext) throws -> [ChatSession] {
        try modelContext.fetch(FetchDescriptor<ChatSession>())
    }

    private func fetchMessages(in modelContext: ModelContext) throws -> [ChatMessage] {
        try modelContext.fetch(FetchDescriptor<ChatMessage>())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
