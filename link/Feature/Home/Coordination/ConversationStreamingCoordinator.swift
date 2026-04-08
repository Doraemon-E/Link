//
//  ConversationStreamingCoordinator.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

protocol ConversationStreamingCoordinator: Sendable {
    func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startLiveSpeechTranscription(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?
    ) -> AsyncThrowingStream<LiveSpeechTranscriptionEvent, Error>

    func cancel(messageID: UUID) async
}

actor LocalConversationStreamingCoordinator: ConversationStreamingCoordinator {
    private let translationService: TranslationService
    private let speechStreamingService: (any SpeechRecognitionStreamingService)?
    private var tasksByMessageID: [UUID: Task<Void, Never>] = [:]
    private var liveStatesByMessageID: [UUID: LiveUtteranceState] = [:]

    init(
        translationService: TranslationService,
        translationAssetReadinessProvider: (any TranslationAssetReadinessProviding)? = nil,
        speechStreamingService: (any SpeechRecognitionStreamingService)? = nil
    ) {
        _ = translationAssetReadinessProvider
        self.translationService = translationService
        self.speechStreamingService = speechStreamingService
    }

    nonisolated func startManualTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        startTranslation(
            messageID: messageID,
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    nonisolated func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        startTranslation(
            messageID: messageID,
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    nonisolated func startLiveSpeechTranscription(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?
    ) -> AsyncThrowingStream<LiveSpeechTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    Self.log(
                        "Live transcription started messageID=\(messageID) sourceLanguage=\(sourceLanguage?.rawValue ?? "auto")"
                    )
                    guard let speechStreamingService = self.speechStreamingService else {
                        continuation.finish(
                            throwing: ConversationStreamingCoordinatorError.liveSpeechNotAvailable
                        )
                        return
                    }

                    let initialState = await self.initializeLiveSpeechState(
                        messageID: messageID,
                        sourceLanguage: sourceLanguage
                    )
                    continuation.yield(.state(initialState))

                    let stream = speechStreamingService.streamTranscription(audioStream: audioStream)
                    for try await event in stream {
                        try Task.checkCancellation()

                        switch event {
                        case .started:
                            continue
                        case .updated(let snapshot), .completed(let snapshot):
                            if let state = await self.consumeLiveTranscriptSnapshot(
                                messageID: messageID,
                                snapshot: snapshot,
                                preferredSourceLanguage: sourceLanguage
                            ) {
                                continuation.yield(.state(state))
                            }
                        }
                    }

                    let finalState = await self.currentLiveState(messageID: messageID)
                    Self.log(
                        "Live transcription completed messageID=\(messageID) transcript=\(Self.preview(finalState.fullTranscript))"
                    )
                    continuation.yield(.completed(finalState))
                    continuation.finish()
                } catch is CancellationError {
                    Self.log("Live transcription cancelled messageID=\(messageID)")
                    continuation.finish()
                } catch {
                    Self.log(
                        "Live transcription failed messageID=\(messageID) error=\(error.localizedDescription)"
                    )
                    continuation.finish(throwing: error)
                }

                await self.clearTask(messageID: messageID)
                await self.teardownLiveSpeechState(messageID: messageID)
            }

            Task {
                await self.replaceTask(producer, messageID: messageID)
            }

            continuation.onTermination = { _ in
                Self.log("Live transcription terminated messageID=\(messageID)")
                producer.cancel()

                Task {
                    await self.clearTask(messageID: messageID)
                    await self.teardownLiveSpeechState(messageID: messageID)
                }
            }
        }
    }

    func cancel(messageID: UUID) async {
        tasksByMessageID[messageID]?.cancel()
        tasksByMessageID.removeValue(forKey: messageID)
        teardownLiveSpeechState(messageID: messageID)
    }

    private nonisolated func startTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    Self.log(
                        "Translation stream started messageID=\(messageID) source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue) text=\(Self.preview(text))"
                    )
                    let translationService = self.translationService
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
                                    TranslationStreamingState(
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
                                    TranslationStreamingState(
                                        messageID: messageID,
                                        committedText: "",
                                        liveText: partialText,
                                        phase: .typing,
                                        revision: revision
                                    )
                                )
                            )
                        case .completed(let completedText):
                            Self.log(
                                "Translation stream completed event messageID=\(messageID) text=\(Self.preview(completedText))"
                            )
                            continuation.yield(.completed(messageID: messageID, text: completedText))
                        }
                    }

                    Self.log("Translation stream finished messageID=\(messageID)")
                    continuation.finish()
                } catch is CancellationError {
                    Self.log("Translation stream cancelled messageID=\(messageID)")
                    continuation.finish()
                } catch {
                    Self.log(
                        "Translation stream failed messageID=\(messageID) error=\(error.localizedDescription)"
                    )
                    continuation.finish(throwing: error)
                }

                await self.clearTask(messageID: messageID)
            }

            Task {
                await self.replaceTask(producer, messageID: messageID)
            }

            continuation.onTermination = { _ in
                Self.log("Translation stream terminated messageID=\(messageID)")
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

    private func initializeLiveSpeechState(
        messageID: UUID,
        sourceLanguage: SupportedLanguage?
    ) -> LiveUtteranceState {
        let state = LiveUtteranceState(detectedLanguage: sourceLanguage)
        liveStatesByMessageID[messageID] = state
        return state
    }

    private func currentLiveState(messageID: UUID) -> LiveUtteranceState {
        liveStatesByMessageID[messageID] ?? LiveUtteranceState()
    }

    private func consumeLiveTranscriptSnapshot(
        messageID: UUID,
        snapshot: SpeechTranscriptionSnapshot,
        preferredSourceLanguage: SupportedLanguage?
    ) -> LiveUtteranceState? {
        let normalizedTranscript = snapshot.fullTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedTranscript.isEmpty ||
                snapshot.detectedLanguage != nil ||
                preferredSourceLanguage != nil else {
            return nil
        }

        var state = liveStatesByMessageID[messageID] ?? LiveUtteranceState()
        let previousState = state
        state.stableTranscript = snapshot.stableTranscript
        state.provisionalTranscript = snapshot.provisionalTranscript
        state.liveTranscript = snapshot.liveTranscript
        state.detectedLanguage = snapshot.detectedLanguage ?? state.detectedLanguage ?? preferredSourceLanguage
        state.transcriptRevision = snapshot.revision
        state.isEndpoint = snapshot.isEndpoint

        guard state != previousState else {
            return nil
        }

        liveStatesByMessageID[messageID] = state
        return state
    }

    private func teardownLiveSpeechState(messageID: UUID) {
        liveStatesByMessageID.removeValue(forKey: messageID)
    }

    private nonisolated static func log(_ message: String) {
        print("[ConversationStreamingCoordinator] \(message)")
    }

    private nonisolated static func preview(_ text: String?, maxLength: Int = 120) -> String {
        guard let text else {
            return "\"\""
        }

        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "\"\""
        }

        let preview = normalized.count > maxLength
            ? String(normalized.prefix(maxLength)) + "..."
            : normalized
        return "\"\(preview)\""
    }
}
