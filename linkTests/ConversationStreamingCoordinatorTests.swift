//
//  ConversationStreamingCoordinatorTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class ConversationStreamingCoordinatorTests: XCTestCase {
    func testManualTranslationStreamsStateThenCompletion() async throws {
        let service = StubTranslationService(
            streamEvents: [
                .started,
                .partial(text: "Hel", revision: 1, isFinal: false),
                .partial(text: "Hello", revision: 2, isFinal: true),
                .completed(text: "Hello")
            ],
            translatedText: "Hello"
        )
        let coordinator = LocalConversationStreamingCoordinator(translationService: service)
        let messageID = UUID()

        let stream = await coordinator.startManualTranslation(
            messageID: messageID,
            text: "你好",
            sourceLanguage: .chinese,
            targetLanguage: .english
        )

        var events: [ConversationStreamingEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .state(
                    StreamingMessageState(
                        messageID: messageID,
                        committedText: "",
                        liveText: nil,
                        phase: .translating,
                        revision: 0
                    )
                ),
                .state(
                    StreamingMessageState(
                        messageID: messageID,
                        committedText: "",
                        liveText: "Hel",
                        phase: .typing,
                        revision: 1
                    )
                ),
                .state(
                    StreamingMessageState(
                        messageID: messageID,
                        committedText: "",
                        liveText: "Hello",
                        phase: .typing,
                        revision: 2
                    )
                ),
                .completed(messageID: messageID, text: "Hello")
            ]
        )
    }

    func testLiveSpeechTranslationFailsUntilStreamingServiceIsProvided() async throws {
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: StubTranslationService(
                streamEvents: [.started, .completed(text: "done")],
                translatedText: "done"
            )
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected the stream to fail when live speech is unavailable.")
        } catch let error as ConversationStreamingCoordinatorError {
            XCTAssertEqual(error, .liveSpeechNotAvailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class StubTranslationService: TranslationService, @unchecked Sendable {
    let streamEvents: [TranslationStreamEvent]
    let translatedText: String

    init(
        streamEvents: [TranslationStreamEvent],
        translatedText: String
    ) {
        self.streamEvents = streamEvents
        self.translatedText = translatedText
    }

    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool {
        _ = source
        _ = target
        return true
    }

    func route(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRoute {
        TranslationRoute(source: source, target: target, steps: [])
    }

    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String {
        _ = text
        _ = source
        _ = target
        return translatedText
    }

    func streamTranslation(
        text: String,
        source: HomeLanguage,
        target: HomeLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        _ = text
        _ = source
        _ = target

        return AsyncThrowingStream { continuation in
            for event in streamEvents {
                continuation.yield(event)
            }

            continuation.finish()
        }
    }
}
