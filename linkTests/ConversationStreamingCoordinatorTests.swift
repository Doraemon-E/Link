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
            audioStream: emptyAudioStream(),
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

    func testLiveSpeechTranslationStabilizesPrefixAndCompletes() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setTranslateResult("ZH:hello ", for: "hello ")
        translationService.setTranslateResult("ZH:hello world", for: "hello world")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .partial(text: "hello wor", revision: 1, isFinal: false, detectedLanguage: .english),
                .partial(text: "hello world", revision: 2, isFinal: false, detectedLanguage: .english),
                .completed(text: "hello world", detectedLanguage: .english)
            ]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        var states: [LiveUtteranceState] = []
        for try await event in stream {
            switch event {
            case .state(let state), .completed(let state):
                states.append(state)
            }
        }

        XCTAssertTrue(
            states.contains(where: {
                $0.stableTranscript == "hello " &&
                $0.unstableTranscript == "world"
            })
        )
        XCTAssertTrue(states.contains(where: { $0.displayTranslation == "ZH:hello world" }))
        XCTAssertEqual(states.last?.stableTranscript, "hello world")
        XCTAssertEqual(states.last?.unstableTranscript, "")
        XCTAssertEqual(states.last?.displayTranslation, "ZH:hello world")
    }

    func testLiveSpeechPreviewCancellationOnlyKeepsLatestCandidate() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setTranslateResult("ZH:hello", for: "hello")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .partial(text: "he", revision: 1, isFinal: false, detectedLanguage: .english),
                .completed(text: "hello", detectedLanguage: .english)
            ]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        for try await _ in stream {}

        let translateInputs = await translationService.translateInputs()
        XCTAssertFalse(translateInputs.contains("he"))
        XCTAssertTrue(translateInputs.contains("hello"))
    }

    func testLiveSpeechPreviewIgnoresStaleTranslationResults() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setTranslateResult("ZH:hello", for: "hello")
        translationService.setTranslateResult("ZH:hello world", for: "hello world")
        translationService.setTranslateDelay(milliseconds: 300, for: "hello")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .partial(text: "hello", revision: 1, isFinal: false, detectedLanguage: .english),
                .partial(text: "hello world", revision: 2, isFinal: false, detectedLanguage: .english),
                .completed(text: "hello world", detectedLanguage: .english)
            ],
            eventDelaysMilliseconds: [0, 0, 250, 0]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        var states: [LiveUtteranceState] = []
        for try await event in stream {
            switch event {
            case .state(let state), .completed(let state):
                states.append(state)
            }
        }

        XCTAssertFalse(states.contains(where: { $0.displayTranslation == "ZH:hello" }))
        XCTAssertTrue(states.contains(where: { $0.displayTranslation == "ZH:hello world" }))
    }

    func testLiveSpeechTranslationUsesDetectedLanguageWhenSupported() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setSupports(.japanese, target: .chinese, value: true)
        translationService.setSupports(.english, target: .chinese, value: false)
        translationService.setTranslateResult("ZH:こんにちは", for: "こんにちは")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .completed(text: "こんにちは", detectedLanguage: .japanese)
            ]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        for try await _ in stream {}

        let calls = await translationService.translationCalls()
        XCTAssertTrue(calls.contains { $0.text == "こんにちは" && $0.source == .japanese && $0.target == .chinese })
    }

    func testLiveSpeechTranslationPreviewCanCorrectToShorterTranscript() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setTranslateResult("ZH:hello world world", for: "hello world world")
        translationService.setTranslateResult("ZH:hello world", for: "hello world")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .partial(text: "hello world world", revision: 1, isFinal: false, detectedLanguage: .english),
                .partial(text: "hello world", revision: 2, isFinal: false, detectedLanguage: .english),
                .completed(text: "hello world", detectedLanguage: .english)
            ]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .english,
            targetLanguage: .chinese
        )

        var states: [LiveUtteranceState] = []
        for try await event in stream {
            switch event {
            case .state(let state), .completed(let state):
                states.append(state)
            }
        }

        XCTAssertTrue(states.contains {
            $0.stableTranscript.isEmpty &&
            $0.unstableTranscript == "hello world" &&
            $0.displayTranslation == "ZH:hello world world"
        })
        XCTAssertEqual(states.last?.stableTranscript, "hello world")
        XCTAssertEqual(states.last?.stableTranslation, "ZH:hello world")
        XCTAssertEqual(states.last?.unstableTranslation, "ZH:hello world")
        XCTAssertEqual(states.last?.displayTranslation, "ZH:hello world")
    }

    func testLiveSpeechTranslationDisplayLocksStablePrefixAndAdjustsTail() async throws {
        let translationService = StubTranslationService(
            streamEvents: [],
            translatedText: ""
        )
        translationService.setTranslateResult("Hello ", for: "你好")
        translationService.setTranslateResult("Hello old tail", for: "你好世界甲乙丙丁戊己")
        translationService.setTranslateResult("Hello new tail", for: "你好世界天地玄黄宇宙")

        let speechService = StubSpeechStreamingService(
            events: [
                .started,
                .partial(text: "你好世界甲乙丙丁戊己", revision: 1, isFinal: false, detectedLanguage: .chinese),
                .partial(text: "你好世界天地玄黄宇宙", revision: 2, isFinal: false, detectedLanguage: .chinese),
                .completed(text: "你好世界天地玄黄宇宙", detectedLanguage: .chinese)
            ]
        )
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        let stream = await coordinator.startLiveSpeechTranslation(
            messageID: UUID(),
            audioStream: emptyAudioStream(),
            sourceLanguage: .chinese,
            targetLanguage: .english
        )

        var states: [LiveUtteranceState] = []
        for try await event in stream {
            switch event {
            case .state(let state), .completed(let state):
                states.append(state)
            }
        }

        XCTAssertTrue(states.contains {
            $0.stableTranslation == "Hello " &&
            $0.displayTranslation == "Hello old tail"
        })
        XCTAssertTrue(states.contains {
            $0.stableTranslation == "Hello " &&
            $0.displayTranslation == "Hello new tail"
        })
        XCTAssertFalse(states.contains {
            $0.displayTranslation.contains("Hello old tailHello new tail")
        })
    }

    private func emptyAudioStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private final class StubSpeechStreamingService: SpeechRecognitionStreamingService, @unchecked Sendable {
    let events: [SpeechTranscriptEvent]
    let eventDelaysMilliseconds: [Int]

    init(
        events: [SpeechTranscriptEvent],
        eventDelaysMilliseconds: [Int] = []
    ) {
        self.events = events
        self.eventDelaysMilliseconds = eventDelaysMilliseconds
    }

    func streamTranscription(
        audioStream: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<SpeechTranscriptEvent, Error> {
        _ = audioStream

        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, event) in events.enumerated() {
                    if index < eventDelaysMilliseconds.count,
                       eventDelaysMilliseconds[index] > 0 {
                        try? await Task.sleep(
                            for: .milliseconds(eventDelaysMilliseconds[index])
                        )
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private final class StubTranslationService: TranslationService, @unchecked Sendable {
    struct TranslationCall: Equatable {
        let text: String
        let source: HomeLanguage
        let target: HomeLanguage
    }

    let streamEvents: [TranslationStreamEvent]
    let translatedText: String

    private let lock = NSLock()
    private var translateResultsByText: [String: String] = [:]
    private var translateDelayMillisecondsByText: [String: Int] = [:]
    private var supportsByPair: [String: Bool] = [:]
    private var recordedTranslateInputs: [String] = []
    private var recordedTranslationCalls: [TranslationCall] = []

    init(
        streamEvents: [TranslationStreamEvent],
        translatedText: String
    ) {
        self.streamEvents = streamEvents
        self.translatedText = translatedText
    }

    func setTranslateResult(_ result: String, for text: String) {
        lock.lock()
        translateResultsByText[text] = result
        lock.unlock()
    }

    func setTranslateDelay(milliseconds: Int, for text: String) {
        lock.lock()
        translateDelayMillisecondsByText[text] = milliseconds
        lock.unlock()
    }

    func setSupports(_ source: HomeLanguage, target: HomeLanguage, value: Bool) {
        lock.lock()
        supportsByPair["\(source.rawValue)->\(target.rawValue)"] = value
        lock.unlock()
    }

    func translateInputs() async -> [String] {
        lock.lock()
        let inputs = recordedTranslateInputs
        lock.unlock()
        return inputs
    }

    func translationCalls() async -> [TranslationCall] {
        lock.lock()
        let calls = recordedTranslationCalls
        lock.unlock()
        return calls
    }

    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool {
        lock.lock()
        let value = supportsByPair["\(source.rawValue)->\(target.rawValue)"] ?? true
        lock.unlock()
        return value
    }

    func route(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRoute {
        TranslationRoute(source: source, target: target, steps: [])
    }

    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String {
        let result: String
        let delayMilliseconds: Int

        lock.lock()
        recordedTranslateInputs.append(text)
        recordedTranslationCalls.append(
            TranslationCall(text: text, source: source, target: target)
        )
        result = translateResultsByText[text] ?? translatedText
        delayMilliseconds = translateDelayMillisecondsByText[text] ?? 0
        lock.unlock()

        if delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }

        return result
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
