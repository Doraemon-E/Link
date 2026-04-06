//
//  TypingRenderer.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct TypingRenderStep: Sendable, Equatable {
    let text: String
    let delayNanoseconds: UInt64
}

nonisolated struct TypingRenderPlan: Sendable, Equatable {
    let steps: [TypingRenderStep]

    var totalDurationNanoseconds: UInt64 {
        steps.reduce(into: UInt64.zero) { partialResult, step in
            partialResult += step.delayNanoseconds
        }
    }
}

nonisolated enum TypingRenderer {
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    static let maximumDurationNanoseconds: UInt64 = 950_000_000

    static func plan(for text: String, language: SupportedLanguage) -> TypingRenderPlan {
        guard !text.isEmpty else {
            return TypingRenderPlan(steps: [])
        }

        let chunks = displayChunks(for: text, language: language)
        guard !chunks.isEmpty else {
            return TypingRenderPlan(steps: [.init(text: text, delayNanoseconds: 0)])
        }

        guard chunks.count > 1 else {
            return TypingRenderPlan(steps: [.init(text: text, delayNanoseconds: 0)])
        }

        let visibleCharacterCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if !scalar.properties.isWhitespace {
                partialResult += 1
            }
        }

        let totalDurationSeconds = min(
            max(
                0.18 + (Double(chunks.count) * 0.016) + (Double(min(visibleCharacterCount, 120)) * 0.0016),
                0.24
            ),
            0.95
        )
        let totalDurationNanoseconds = UInt64((totalDurationSeconds * 1_000_000_000).rounded())
        let delays = weightedDelays(
            totalDurationNanoseconds: totalDurationNanoseconds,
            intervalCount: chunks.count - 1
        )

        var renderedText = ""
        var steps: [TypingRenderStep] = []
        /// 与分配内存，提高性能
        steps.reserveCapacity(chunks.count)

        for index in chunks.indices {
            renderedText += chunks[index]
            let delay = index < delays.count ? delays[index] : 0
            steps.append(
                TypingRenderStep(
                    text: renderedText,
                    delayNanoseconds: delay
                )
            )
        }

        if let lastStep = steps.last {
            steps[steps.count - 1] = TypingRenderStep(text: lastStep.text, delayNanoseconds: 0)
        }

        return TypingRenderPlan(steps: steps)
    }

    static func stream(
        text: String,
        language: SupportedLanguage,
        sleep: @escaping Sleep = defaultSleep
    ) -> AsyncThrowingStream<String, Error> {
        let plan = plan(for: text, language: language)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in plan.steps {
                        try Task.checkCancellation()
                        continuation.yield(step.text)

                        if step.delayNanoseconds > 0 {
                            try await sleep(step.delayNanoseconds)
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func defaultSleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func weightedDelays(
        totalDurationNanoseconds: UInt64,
        intervalCount: Int
    ) -> [UInt64] {
        guard intervalCount > 0 else {
            return []
        }

        guard intervalCount > 1 else {
            return [min(totalDurationNanoseconds, maximumDurationNanoseconds)]
        }

        let clampedTotalDuration = min(totalDurationNanoseconds, maximumDurationNanoseconds)
        let weights = (0..<intervalCount).map { index -> Double in
            let status = Double(index) / Double(max(intervalCount - 1, 1))
            return max(0.92, 1.08 - (status * 0.16))
        }
        let weightSum = weights.reduce(0, +)

        var delays = weights.map { weight -> UInt64 in
            UInt64((Double(clampedTotalDuration) * (weight / weightSum)).rounded())
        }

        let assignedDuration = delays.reduce(into: UInt64.zero) { partialResult, delay in
            partialResult += delay
        }

        if assignedDuration > clampedTotalDuration, let lastDelay = delays.last {
            let overflow = assignedDuration - clampedTotalDuration
            delays[delays.count - 1] = lastDelay > overflow ? lastDelay - overflow : 0
        } else if assignedDuration < clampedTotalDuration, !delays.isEmpty {
            delays[delays.count - 1] += clampedTotalDuration - assignedDuration
        }

        return delays
    }

    private static func displayChunks(for text: String, language: SupportedLanguage) -> [String] {
        switch language {
        case .chinese, .japanese, .korean:
            return cjkChunks(for: text)
        case .english, .french, .german, .russian, .spanish, .italian:
            return latinLikeChunks(for: text)
        }
    }

    private static func cjkChunks(for text: String) -> [String] {
        let characters = Array(text)
        let visibleCharacterCount = characters.reduce(into: 0) { partialResult, character in
            if !character.isWhitespaceOrNewline {
                partialResult += 1
            }
        }
        let preferredChunkLength = visibleCharacterCount < 24 ? 1 : 2

        var chunks: [String] = []
        var currentChunk = ""

        for character in characters {
            currentChunk.append(character)

            if character.isWhitespaceOrNewline ||
                character.isSentenceBoundary ||
                currentChunk.count >= preferredChunkLength {
                chunks.append(currentChunk)
                currentChunk = ""
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    private static func latinLikeChunks(for text: String) -> [String] {
        let visibleCharacterCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if !scalar.properties.isWhitespace {
                partialResult += 1
            }
        }

        if visibleCharacterCount < 18 {
            return Array(text).map(String.init)
        }

        let preferredChunkLength: Int
        switch visibleCharacterCount {
        case ..<40:
            preferredChunkLength = 1
        case ..<88:
            preferredChunkLength = 2
        default:
            preferredChunkLength = 3
        }

        var chunks: [String] = []
        var currentChunk = ""
        var visibleCountInChunk = 0

        for character in text {
            currentChunk.append(character)

            if character.isWhitespaceOrNewline {
                chunks.append(currentChunk)
                currentChunk = ""
                visibleCountInChunk = 0
                continue
            }

            visibleCountInChunk += 1

            if character.isSentenceBoundary || visibleCountInChunk >= preferredChunkLength {
                chunks.append(currentChunk)
                currentChunk = ""
                visibleCountInChunk = 0
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks.isEmpty ? Array(text).map(String.init) : chunks
    }
}

private nonisolated extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var isSentenceBoundary: Bool {
        switch self {
        case ".", ",", "!", "?", ";", ":", "，", "。", "！", "？", "；", "：", "、":
            return true
        default:
            return false
        }
    }
}
