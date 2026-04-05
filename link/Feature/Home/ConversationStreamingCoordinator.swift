//
//  ConversationStreamingCoordinator.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum ConversationStreamingEvent: Sendable, Equatable {
    case state(TranslationStreamingState)
    case completed(messageID: UUID, text: String)
}

struct LiveUtteranceState: Sendable, Equatable {
    var stableTranscript: String = ""
    var unstableTranscript: String = ""
    var stableTranslation: String = ""
    var unstableTranslation: String = ""
    var displayTranslation: String = ""
    var detectedLanguage: SupportedLanguage?
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
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startSpeechTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<ConversationStreamingEvent, Error>

    func startLiveSpeechTranslation(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<LiveSpeechTranslationEvent, Error>

    func cancel(messageID: UUID) async
}

actor LocalConversationStreamingCoordinator: ConversationStreamingCoordinator {
    private struct LivePreviewRequest: Sendable {
        let requestID: Int
        let transcript: String
        let sourceLanguage: SupportedLanguage
        let targetLanguage: SupportedLanguage
    }

    private let translationService: TranslationService
    private let translationAssetReadinessProvider: (any TranslationAssetReadinessProviding)?
    private let speechStreamingService: (any SpeechRecognitionStreamingService)?
    private var tasksByMessageID: [UUID: Task<Void, Never>] = [:]
    private var liveStatesByMessageID: [UUID: LiveUtteranceState] = [:]
    private var liveTranscriptCandidatesByMessageID: [UUID: String] = [:]
    private var liveResolvedSourceLanguagesByMessageID: [UUID: SupportedLanguage] = [:]
    private var liveStableTranslationTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    private var livePreviewTranslationTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    private var livePreviewRequestsByMessageID: [UUID: LivePreviewRequest] = [:]
    private var liveNextPreviewRequestIDsByMessageID: [UUID: Int] = [:]
    private var liveAppliedPreviewRequestIDsByMessageID: [UUID: Int] = [:]

    init(
        translationService: TranslationService,
        translationAssetReadinessProvider: (any TranslationAssetReadinessProviding)? = nil,
        speechStreamingService: (any SpeechRecognitionStreamingService)? = nil
    ) {
        self.translationService = translationService
        self.translationAssetReadinessProvider = translationAssetReadinessProvider
        self.speechStreamingService = speechStreamingService
    }

    func startManualTranslation(
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

    func startSpeechTranslation(
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

    func startLiveSpeechTranslation(
        messageID: UUID,
        audioStream: AsyncStream<[Float]>,
        sourceLanguage: SupportedLanguage?,
        targetLanguage: SupportedLanguage
    ) -> AsyncThrowingStream<LiveSpeechTranslationEvent, Error> {
        let speechStreamingService = self.speechStreamingService

        return AsyncThrowingStream { continuation in
            guard let speechStreamingService else {
                continuation.finish(throwing: ConversationStreamingCoordinatorError.liveSpeechNotAvailable)
                return
            }

            let producer = Task {
                do {
                    let initialState = self.initializeLiveSpeechState(
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
                        case .partial(let text, _, let isFinal, let detectedLanguage):
                            if let state = try await self.consumeLiveTranscript(
                                messageID: messageID,
                                candidate: text,
                                detectedLanguage: detectedLanguage,
                                preferredSourceLanguage: sourceLanguage,
                                targetLanguage: targetLanguage,
                                forceFinalizeCandidate: isFinal,
                                continuation: continuation
                            ) {
                                continuation.yield(.state(state))
                            }
                        case .completed(let text, let detectedLanguage):
                            if let state = try await self.consumeLiveTranscript(
                                messageID: messageID,
                                candidate: text,
                                detectedLanguage: detectedLanguage,
                                preferredSourceLanguage: sourceLanguage,
                                targetLanguage: targetLanguage,
                                forceFinalizeCandidate: true,
                                continuation: continuation
                            ) {
                                continuation.yield(.state(state))
                            }
                        }
                    }

                    let finalState = self.currentLiveState(messageID: messageID)
                    continuation.yield(.completed(finalState))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.clearTask(messageID: messageID)
                self.teardownLiveSpeechState(messageID: messageID)
            }

            Task {
                self.replaceTask(producer, messageID: messageID)
            }

            continuation.onTermination = { _ in
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

    private func startTranslation(
        messageID: UUID,
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
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
                            continuation.yield(.completed(messageID: messageID, text: completedText))
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.clearTask(messageID: messageID)
            }

            Task {
                self.replaceTask(producer, messageID: messageID)
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

    private func initializeLiveSpeechState(
        messageID: UUID,
        sourceLanguage: SupportedLanguage?
    ) -> LiveUtteranceState {
        let state = LiveUtteranceState(detectedLanguage: sourceLanguage)
        liveStatesByMessageID[messageID] = state
        liveTranscriptCandidatesByMessageID[messageID] = ""
        liveNextPreviewRequestIDsByMessageID[messageID] = 0
        return state
    }

    private func currentLiveState(messageID: UUID) -> LiveUtteranceState {
        liveStatesByMessageID[messageID] ?? LiveUtteranceState()
    }

    private func normalizedLiveTranscript(for state: LiveUtteranceState) -> String {
        (state.stableTranscript + state.unstableTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentLiveTranscript(messageID: UUID) -> String {
        normalizedLiveTranscript(
            for: liveStatesByMessageID[messageID] ?? LiveUtteranceState()
        )
    }

    private func consumeLiveTranscript(
        messageID: UUID,
        candidate: String,
        detectedLanguage: SupportedLanguage?,
        preferredSourceLanguage: SupportedLanguage?,
        targetLanguage: SupportedLanguage,
        forceFinalizeCandidate: Bool,
        continuation: AsyncThrowingStream<LiveSpeechTranslationEvent, Error>.Continuation
    ) async throws -> LiveUtteranceState? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else {
            return nil
        }

        var state = liveStatesByMessageID[messageID] ?? LiveUtteranceState()
        let previousStableTranscript = state.stableTranscript
        let previousUnstableTranscript = state.unstableTranscript

        let previousResolvedSourceLanguage = liveResolvedSourceLanguagesByMessageID[messageID]
        let resolvedSourceLanguage = try await resolveLiveSourceLanguage(
            messageID: messageID,
            preferredSourceLanguage: preferredSourceLanguage,
            detectedLanguage: detectedLanguage,
            targetLanguage: targetLanguage
        )
        let sourceLanguageChanged = previousResolvedSourceLanguage != resolvedSourceLanguage

        state.detectedLanguage = detectedLanguage ?? state.detectedLanguage

        let transcriptLanguage = detectedLanguage ?? resolvedSourceLanguage ?? preferredSourceLanguage
        let mergedTranscript = mergeAccumulatedTranscript(
            committedTranscript: state.stableTranscript,
            candidate: normalizedCandidate
        )

        if forceFinalizeCandidate {
            state.stableTranscript = mergedTranscript
            state.unstableTranscript = ""
        } else {
            let committedTranscript = committedPortion(
                of: mergedTranscript,
                language: transcriptLanguage,
                minimumCommittedLength: state.stableTranscript.count
            )
            state.stableTranscript = committedTranscript
            state.unstableTranscript = String(
                mergedTranscript.dropFirst(committedTranscript.count)
            )
        }

        if state.stableTranscript != previousStableTranscript ||
            state.unstableTranscript != previousUnstableTranscript {
            state.transcriptRevision += 1
        }

        liveStatesByMessageID[messageID] = state
        liveTranscriptCandidatesByMessageID[messageID] = normalizedCandidate

        let fullTranscript = state.stableTranscript + state.unstableTranscript
        let effectiveSourceLanguage = resolvedSourceLanguage ?? detectedLanguage ?? preferredSourceLanguage

        if let effectiveSourceLanguage {
            if state.stableTranscript != previousStableTranscript || forceFinalizeCandidate || sourceLanguageChanged {
                scheduleStableTranslation(
                    messageID: messageID,
                    transcript: state.stableTranscript,
                    sourceLanguage: effectiveSourceLanguage,
                    targetLanguage: targetLanguage,
                    continuation: continuation
                )
            }

            schedulePreviewTranslation(
                messageID: messageID,
                transcript: fullTranscript,
                sourceLanguage: effectiveSourceLanguage,
                targetLanguage: targetLanguage,
                forceImmediate: forceFinalizeCandidate,
                continuation: continuation
            )
        }

        return state
    }

    private func resolveLiveSourceLanguage(
        messageID: UUID,
        preferredSourceLanguage: SupportedLanguage?,
        detectedLanguage: SupportedLanguage?,
        targetLanguage: SupportedLanguage
    ) async throws -> SupportedLanguage? {
        if let detectedLanguage {
            let currentResolvedLanguage = liveResolvedSourceLanguagesByMessageID[messageID]
            if currentResolvedLanguage != detectedLanguage,
               try await hasReadyTranslation(source: detectedLanguage, target: targetLanguage) {
                liveResolvedSourceLanguagesByMessageID[messageID] = detectedLanguage
                return detectedLanguage
            }
        }

        if let resolvedLanguage = liveResolvedSourceLanguagesByMessageID[messageID] {
            return resolvedLanguage
        }

        if let preferredSourceLanguage,
           try await hasReadyTranslation(source: preferredSourceLanguage, target: targetLanguage) {
            liveResolvedSourceLanguagesByMessageID[messageID] = preferredSourceLanguage
            return preferredSourceLanguage
        }

        if let detectedLanguage,
           try await hasReadyTranslation(source: detectedLanguage, target: targetLanguage) {
            liveResolvedSourceLanguagesByMessageID[messageID] = detectedLanguage
            return detectedLanguage
        }

        return nil
    }

    private func hasReadyTranslation(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> Bool {
        if let translationAssetReadinessProvider {
            do {
                let route = try await translationService.route(source: source, target: target)
                return try await translationAssetReadinessProvider.areTranslationAssetsReady(
                    for: route
                )
            } catch is TranslationError {
                return false
            }
        }

        return try await translationService.supports(source: source, target: target)
    }

    private func scheduleStableTranslation(
        messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        continuation: AsyncThrowingStream<LiveSpeechTranslationEvent, Error>.Continuation
    ) {
        liveStableTranslationTasksByMessageID[messageID]?.cancel()

        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            var state = liveStatesByMessageID[messageID] ?? LiveUtteranceState()
            if !state.stableTranslation.isEmpty {
                state.stableTranslation = ""
                state.translationRevision += 1
                liveStatesByMessageID[messageID] = state
                continuation.yield(.state(state))
            }
            return
        }

        let task = Task {
            do {
                let translatedText = try await self.translationService.translate(
                    text: normalizedTranscript,
                    source: sourceLanguage,
                    target: targetLanguage
                )
                try Task.checkCancellation()

                if let state = self.applyStableTranslation(
                    messageID: messageID,
                    translatedText: translatedText,
                    targetLanguage: targetLanguage
                ) {
                    continuation.yield(.state(state))
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        liveStableTranslationTasksByMessageID[messageID] = task
    }

    private func schedulePreviewTranslation(
        messageID: UUID,
        transcript: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        forceImmediate: Bool,
        continuation: AsyncThrowingStream<LiveSpeechTranslationEvent, Error>.Continuation
    ) {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            livePreviewRequestsByMessageID.removeValue(forKey: messageID)
            var state = liveStatesByMessageID[messageID] ?? LiveUtteranceState()
            let displayTranslation = state.stableTranslation
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !state.unstableTranslation.isEmpty || state.displayTranslation != displayTranslation {
                state.unstableTranslation = ""
                state.displayTranslation = displayTranslation
                state.translationRevision += 1
                liveStatesByMessageID[messageID] = state
                continuation.yield(.state(state))
            }
            return
        }

        let nextRequestID = (liveNextPreviewRequestIDsByMessageID[messageID] ?? 0) + 1
        liveNextPreviewRequestIDsByMessageID[messageID] = nextRequestID
        livePreviewRequestsByMessageID[messageID] = LivePreviewRequest(
            requestID: nextRequestID,
            transcript: normalizedTranscript,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        guard livePreviewTranslationTasksByMessageID[messageID] == nil else {
            return
        }

        let task = Task {
            await self.processPreviewTranslations(
                messageID: messageID,
                initialForceImmediate: forceImmediate,
                continuation: continuation
            )
        }
        livePreviewTranslationTasksByMessageID[messageID] = task
    }

    private func processPreviewTranslations(
        messageID: UUID,
        initialForceImmediate: Bool,
        continuation: AsyncThrowingStream<LiveSpeechTranslationEvent, Error>.Continuation
    ) async {
        var shouldSkipDelay = initialForceImmediate

        defer {
            livePreviewTranslationTasksByMessageID.removeValue(forKey: messageID)
        }

        while !Task.isCancelled {
            guard livePreviewRequestsByMessageID[messageID] != nil else {
                break
            }

            do {
                if !shouldSkipDelay {
                    try await Task.sleep(for: .milliseconds(200))
                }
                shouldSkipDelay = false
                try Task.checkCancellation()

                guard let request = livePreviewRequestsByMessageID.removeValue(forKey: messageID) else {
                    continue
                }

                guard request.transcript == currentLiveTranscript(messageID: messageID) else {
                    continue
                }

                let translatedText = try await translationService.translate(
                    text: request.transcript,
                    source: request.sourceLanguage,
                    target: request.targetLanguage
                )
                try Task.checkCancellation()

                if let state = applyPreviewTranslation(
                    messageID: messageID,
                    requestID: request.requestID,
                    sourceTranscript: request.transcript,
                    translatedText: translatedText,
                    targetLanguage: request.targetLanguage
                ) {
                    continuation.yield(.state(state))
                }
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
    }

    private func applyStableTranslation(
        messageID: UUID,
        translatedText: String,
        targetLanguage: SupportedLanguage
    ) -> LiveUtteranceState? {
        guard var state = liveStatesByMessageID[messageID] else {
            return nil
        }

        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTranslation = composeDisplayTranslation(
            previousDisplayTranslation: state.displayTranslation,
            stableTranslation: normalizedTranslation,
            previewTranslation: state.unstableTranslation,
            targetLanguage: targetLanguage
        )

        guard normalizedTranslation != state.stableTranslation ||
            displayTranslation != state.displayTranslation else {
            return nil
        }

        state.stableTranslation = normalizedTranslation
        state.displayTranslation = displayTranslation
        if state.unstableTranscript.isEmpty {
            state.unstableTranslation = normalizedTranslation
        }
        state.translationRevision += 1
        liveStatesByMessageID[messageID] = state
        return state
    }

    private func applyPreviewTranslation(
        messageID: UUID,
        requestID: Int,
        sourceTranscript: String,
        translatedText: String,
        targetLanguage: SupportedLanguage
    ) -> LiveUtteranceState? {
        guard var state = liveStatesByMessageID[messageID] else {
            return nil
        }

        let lastAppliedRequestID = liveAppliedPreviewRequestIDsByMessageID[messageID] ?? 0
        guard requestID >= lastAppliedRequestID else {
            return nil
        }

        let normalizedSourceTranscript = sourceTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSourceTranscript == normalizedLiveTranscript(for: state) else {
            return nil
        }

        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateDisplayTranslation = composeDisplayTranslation(
            previousDisplayTranslation: state.displayTranslation,
            stableTranslation: state.stableTranslation,
            previewTranslation: normalizedTranslation,
            targetLanguage: targetLanguage
        )
        let displayTranslation = resolvedPreviewDisplayTranslation(
            previousDisplayTranslation: state.displayTranslation,
            candidateDisplayTranslation: candidateDisplayTranslation,
            hasUnstableTranscript: !state.unstableTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )

        guard normalizedTranslation != state.unstableTranslation ||
            displayTranslation != state.displayTranslation else {
            return nil
        }

        state.unstableTranslation = normalizedTranslation
        state.displayTranslation = displayTranslation
        state.translationRevision += 1
        liveStatesByMessageID[messageID] = state
        liveAppliedPreviewRequestIDsByMessageID[messageID] = requestID
        return state
    }

    private func resolvedPreviewDisplayTranslation(
        previousDisplayTranslation: String,
        candidateDisplayTranslation: String,
        hasUnstableTranscript: Bool
    ) -> String {
        let normalizedPrevious = previousDisplayTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = candidateDisplayTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard hasUnstableTranscript,
              !normalizedPrevious.isEmpty,
              !normalizedCandidate.isEmpty,
              normalizedCandidate.count < normalizedPrevious.count else {
            return normalizedCandidate
        }

        return normalizedPrevious
    }

    private func teardownLiveSpeechState(messageID: UUID) {
        liveStableTranslationTasksByMessageID[messageID]?.cancel()
        livePreviewTranslationTasksByMessageID[messageID]?.cancel()
        liveStableTranslationTasksByMessageID.removeValue(forKey: messageID)
        livePreviewTranslationTasksByMessageID.removeValue(forKey: messageID)
        livePreviewRequestsByMessageID.removeValue(forKey: messageID)
        liveNextPreviewRequestIDsByMessageID.removeValue(forKey: messageID)
        liveAppliedPreviewRequestIDsByMessageID.removeValue(forKey: messageID)
        liveResolvedSourceLanguagesByMessageID.removeValue(forKey: messageID)
        liveTranscriptCandidatesByMessageID.removeValue(forKey: messageID)
        liveStatesByMessageID.removeValue(forKey: messageID)
    }

    private func mergeAccumulatedTranscript(
        committedTranscript: String,
        candidate: String
    ) -> String {
        guard !candidate.isEmpty else {
            return committedTranscript
        }

        guard !committedTranscript.isEmpty else {
            return candidate
        }

        if committedTranscript.contains(candidate) {
            return committedTranscript
        }

        if candidate.hasPrefix(committedTranscript) || candidate.contains(committedTranscript) {
            return candidate
        }

        let committedCharacters = Array(committedTranscript)
        let candidateCharacters = Array(candidate)
        let maxOverlap = min(committedCharacters.count, candidateCharacters.count)

        for overlapLength in stride(from: maxOverlap, through: 1, by: -1) {
            let committedSuffix = committedCharacters.suffix(overlapLength)
            let candidatePrefix = candidateCharacters.prefix(overlapLength)

            if Array(committedSuffix) == Array(candidatePrefix) {
                return committedTranscript + String(candidateCharacters.dropFirst(overlapLength))
            }
        }

        return committedTranscript + candidate
    }

    private func committedPortion(
        of text: String,
        language: SupportedLanguage?,
        minimumCommittedLength: Int
    ) -> String {
        committedPortion(
            of: text,
            language: language,
            minimumCommittedLength: minimumCommittedLength,
            reserveCount: transcriptTailReserveCharacterCount(for: language)
        )
    }

    private func committedPortion(
        of text: String,
        language: SupportedLanguage?,
        minimumCommittedLength: Int,
        reserveCount: Int
    ) -> String {
        guard !text.isEmpty else {
            return ""
        }

        let targetCommittedLength = max(
            minimumCommittedLength,
            text.count - reserveCount
        )
        let clampedCommittedLength = min(targetCommittedLength, text.count)

        guard clampedCommittedLength > 0 else {
            return ""
        }

        if let language, [.chinese, .japanese, .korean].contains(language) {
            return String(text.prefix(clampedCommittedLength))
        }

        let boundaryScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let scalars = Array(text.unicodeScalars)
        var lastBoundaryCharacterIndex = minimumCommittedLength
        var characterIndex = 0

        for scalar in scalars {
            characterIndex += 1
            if characterIndex > clampedCommittedLength {
                break
            }

            if boundaryScalars.contains(scalar),
               characterIndex >= minimumCommittedLength {
                lastBoundaryCharacterIndex = characterIndex
            }
        }

        let finalCommittedLength: Int
        if lastBoundaryCharacterIndex > minimumCommittedLength {
            finalCommittedLength = lastBoundaryCharacterIndex
        } else {
            finalCommittedLength = clampedCommittedLength
        }

        return String(text.prefix(finalCommittedLength))
    }

    private func transcriptTailReserveCharacterCount(for language: SupportedLanguage?) -> Int {
        guard let language else {
            return 16
        }

        if [.chinese, .japanese, .korean].contains(language) {
            return 8
        }

        return 20
    }

    private func composeDisplayTranslation(
        previousDisplayTranslation: String,
        stableTranslation: String,
        previewTranslation: String,
        targetLanguage: SupportedLanguage
    ) -> String {
        let normalizedStable = stableTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPreview = previewTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrevious = previousDisplayTranslation.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedStable.isEmpty else {
            return normalizedPreview
        }

        guard !normalizedPreview.isEmpty else {
            return normalizedStable
        }

        if let mergedTranslation = mergeStableTranslationWithPreview(
            stableTranslation: normalizedStable,
            previewTranslation: normalizedPreview,
            targetLanguage: targetLanguage
        ) {
            return mergedTranslation
        }

        if normalizedPrevious.hasPrefix(normalizedStable) {
            return normalizedPrevious
        }

        return normalizedStable
    }

    private func mergeStableTranslationWithPreview(
        stableTranslation: String,
        previewTranslation: String,
        targetLanguage: SupportedLanguage
    ) -> String? {
        if previewTranslation == stableTranslation {
            return stableTranslation
        }

        if previewTranslation.hasPrefix(stableTranslation) {
            return previewTranslation
        }

        let stableCharacters = Array(stableTranslation)
        let previewCharacters = Array(previewTranslation)
        let maxOverlap = min(stableCharacters.count, previewCharacters.count)
        let minimumOverlap = min(
            minimumDisplayTranslationOverlapCharacterCount(for: targetLanguage),
            maxOverlap
        )

        guard minimumOverlap > 0 else {
            return nil
        }

        for overlapLength in stride(from: maxOverlap, through: minimumOverlap, by: -1) {
            let stableSuffix = stableCharacters.suffix(overlapLength)
            let previewPrefix = previewCharacters.prefix(overlapLength)

            guard Array(stableSuffix) == Array(previewPrefix) else {
                continue
            }

            if !isValidDisplayTranslationOverlap(
                stableCharacters: stableCharacters,
                overlapLength: overlapLength,
                targetLanguage: targetLanguage
            ) {
                continue
            }

            return stableTranslation + String(previewCharacters.dropFirst(overlapLength))
        }

        return nil
    }

    private func minimumDisplayTranslationOverlapCharacterCount(
        for language: SupportedLanguage
    ) -> Int {
        if [.chinese, .japanese, .korean].contains(language) {
            return 2
        }

        return 4
    }

    private func isValidDisplayTranslationOverlap(
        stableCharacters: [Character],
        overlapLength: Int,
        targetLanguage: SupportedLanguage
    ) -> Bool {
        if [.chinese, .japanese, .korean].contains(targetLanguage) {
            return true
        }

        let overlapStartIndex = stableCharacters.count - overlapLength
        guard overlapStartIndex > 0 else {
            return true
        }

        let precedingCharacter = stableCharacters[overlapStartIndex - 1]
        return isDisplayTranslationBoundary(precedingCharacter)
    }

    private func isDisplayTranslationBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(scalar)
        }
    }
}
