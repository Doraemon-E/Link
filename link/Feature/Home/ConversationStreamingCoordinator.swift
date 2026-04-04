//
//  ConversationStreamingCoordinator.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum ConversationStreamingEvent: Sendable, Equatable {
    case state(StreamingMessageState)
    case completed(messageID: UUID, text: String)
}

struct LiveUtteranceState: Sendable, Equatable {
    var stableTranscript: String = ""
    var unstableTranscript: String = ""
    var stableTranslation: String = ""
    var unstableTranslation: String = ""
    var detectedLanguage: HomeLanguage?
    var transcriptRevision: Int = 0
    var translationRevision: Int = 0
}

enum LiveSpeechTranslationEvent: Sendable, Equatable {
    case state(LiveUtteranceState)
    case completed(LiveUtteranceState)
}

enum ConversationStreamingCoordinatorError: LocalizedError, Equatable {
    case liveSpeechNotAvailable

    var errorDescription: String? {
        switch self {
        case .liveSpeechNotAvailable:
            return "Live speech translation is not available in the current build."
        }
    }
}

protocol ConversationStreamingCoordinator: Sendable {
    func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startLiveSpeechTranslation(
        messageID: UUID,
        sourceLanguage: HomeLanguage?,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<LiveSpeechTranslationEvent, Error>

    func cancel(messageID: UUID) async
}

actor LocalConversationStreamingCoordinator: ConversationStreamingCoordinator {
    private let translationService: TranslationService
    private let speechStreamingService: (any SpeechRecognitionStreamingService)?
    private var tasksByMessageID: [UUID: Task<Void, Never>] = [:]

    init(
        translationService: TranslationService,
        speechStreamingService: (any SpeechRecognitionStreamingService)? = nil
    ) {
        self.translationService = translationService
        self.speechStreamingService = speechStreamingService
    }

    func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        startTranslation(
            messageID: messageID,
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        startTranslation(
            messageID: messageID,
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func startLiveSpeechTranslation(
        messageID: UUID,
        sourceLanguage: HomeLanguage?,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<LiveSpeechTranslationEvent, Error> {
        let speechStreamingService = self.speechStreamingService
        _ = messageID
        _ = sourceLanguage
        _ = targetLanguage

        return AsyncThrowingStream { continuation in
            guard speechStreamingService != nil else {
                continuation.finish(throwing: ConversationStreamingCoordinatorError.liveSpeechNotAvailable)
                return
            }

            continuation.finish(throwing: ConversationStreamingCoordinatorError.liveSpeechNotAvailable)
        }
    }

    func cancel(messageID: UUID) async {
        tasksByMessageID[messageID]?.cancel()
        tasksByMessageID.removeValue(forKey: messageID)
    }

    private func startTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: HomeLanguage,
        targetLanguage: HomeLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        let translationService = self.translationService

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await event in translationService.streamTranslation(
                        text: text,
                        source: sourceLanguage,
                        target: targetLanguage
                    ) {
                        try Task.checkCancellation()

                        switch event {
                        case .started:
                            continuation.yield(
                                .state(
                                    StreamingMessageState(
                                        messageID: messageID,
                                        committedText: "",
                                        liveText: nil,
                                        phase: .translating,
                                        revision: 0
                                    )
                                )
                            )
                        case .partial(let partialText, let revision, _):
                            continuation.yield(
                                .state(
                                    StreamingMessageState(
                                        messageID: messageID,
                                        committedText: "",
                                        liveText: partialText,
                                        phase: .typing,
                                        revision: revision
                                    )
                                )
                            )
                        case .completed(let completedText):
                            continuation.yield(.completed(messageID: messageID, text: completedText))
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                await self.clearTask(messageID: messageID)
            }

            Task {
                await self.replaceTask(producer, messageID: messageID)
            }

            continuation.onTermination = { _ in
                producer.cancel()

                Task {
                    await self.clearTask(messageID: messageID)
                }
            }
        }
    }

    private func replaceTask(_ task: Task<Void, Never>, messageID: UUID) {
        tasksByMessageID[messageID]?.cancel()
        tasksByMessageID[messageID] = task
    }

    private func clearTask(messageID: UUID) {
        tasksByMessageID.removeValue(forKey: messageID)
    }
}
