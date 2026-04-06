//
//  SpeechTranscriptStabilizer.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated struct SpeechTranscriptStabilizer: Sendable {
    private var committedTranscript = ""
    private var activeCommittedTranscript = ""
    private var activeUnstableTranscript = ""
    private var revision = 0
    private var detectedLanguage: SupportedLanguage?

    var currentSnapshot: SpeechTranscriptionSnapshot {
        makeSnapshot(isEndpoint: false)
    }

    mutating func consume(
        candidate: String,
        detectedLanguage: SupportedLanguage?,
        isEndpoint: Bool
    ) -> SpeechTranscriptionSnapshot? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else {
            return isEndpoint ? finalizeCurrentUtterance() : nil
        }

        let previousSnapshot = makeSnapshot(isEndpoint: false)
        self.detectedLanguage = detectedLanguage ?? self.detectedLanguage

        let mergedTranscript = mergeAccumulatedTranscript(
            committedTranscript: activeCommittedTranscript,
            candidate: normalizedCandidate
        )

        if isEndpoint {
            activeCommittedTranscript = mergedTranscript
            activeUnstableTranscript = ""
            committedTranscript = appendTranscriptSegment(
                to: committedTranscript,
                segment: activeCommittedTranscript,
                language: self.detectedLanguage
            )
            activeCommittedTranscript = ""
        } else {
            let committedPortion = committedPortion(
                of: mergedTranscript,
                language: self.detectedLanguage,
                minimumCommittedLength: activeCommittedTranscript.count
            )
            activeCommittedTranscript = committedPortion
            activeUnstableTranscript = String(
                mergedTranscript.dropFirst(committedPortion.count)
            )
        }

        let shouldEmit = isEndpoint ||
            previousSnapshot.stableTranscript != previewStableTranscript ||
            previousSnapshot.unstableTranscript != previewUnstableTranscript ||
            previousSnapshot.detectedLanguage != self.detectedLanguage

        guard shouldEmit else {
            return nil
        }

        revision += 1
        return makeSnapshot(isEndpoint: isEndpoint)
    }

    mutating func finalizeCurrentUtterance() -> SpeechTranscriptionSnapshot? {
        let fallbackTranscript = (activeCommittedTranscript + activeUnstableTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackTranscript.isEmpty else {
            return nil
        }

        activeCommittedTranscript = fallbackTranscript
        activeUnstableTranscript = ""
        committedTranscript = appendTranscriptSegment(
            to: committedTranscript,
            segment: activeCommittedTranscript,
            language: detectedLanguage
        )
        activeCommittedTranscript = ""
        revision += 1
        return makeSnapshot(isEndpoint: true)
    }

    private var previewStableTranscript: String {
        appendTranscriptSegment(
            to: committedTranscript,
            segment: activeCommittedTranscript,
            language: detectedLanguage
        )
    }

    private var previewUnstableTranscript: String {
        guard !activeUnstableTranscript.isEmpty else {
            return ""
        }

        let stablePrefix = previewStableTranscript
        let separator = transcriptSeparatorPrefix(
            previous: stablePrefix,
            next: activeUnstableTranscript,
            language: detectedLanguage
        )
        return stablePrefix == committedTranscript ? separator + activeUnstableTranscript : activeUnstableTranscript
    }

    private func makeSnapshot(isEndpoint: Bool) -> SpeechTranscriptionSnapshot {
        SpeechTranscriptionSnapshot(
            stableTranscript: previewStableTranscript,
            unstableTranscript: previewUnstableTranscript,
            revision: revision,
            detectedLanguage: detectedLanguage,
            isEndpoint: isEndpoint
        )
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

    private func transcriptTailReserveCharacterCount(
        for language: SupportedLanguage?
    ) -> Int {
        guard let language else {
            return 16
        }

        if [.chinese, .japanese, .korean].contains(language) {
            return 8
        }

        return 20
    }

    private func appendTranscriptSegment(
        to transcript: String,
        segment: String,
        language: SupportedLanguage?
    ) -> String {
        let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSegment.isEmpty else {
            return transcript
        }

        let separator = transcriptSeparatorPrefix(
            previous: transcript,
            next: normalizedSegment,
            language: language
        )
        return transcript + separator + normalizedSegment
    }

    private func transcriptSeparatorPrefix(
        previous: String,
        next: String,
        language: SupportedLanguage?
    ) -> String {
        let normalizedPrevious = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrevious.isEmpty, !normalizedNext.isEmpty else {
            return ""
        }

        if let language, [.chinese, .japanese, .korean].contains(language) {
            return ""
        }

        guard let previousCharacter = normalizedPrevious.last,
              let nextCharacter = normalizedNext.first else {
            return ""
        }

        if previousCharacter.isWhitespaceOrNewline || nextCharacter.isWhitespaceOrNewline {
            return ""
        }

        if previousCharacter.isSentenceBoundary || nextCharacter.isSentenceBoundary {
            return " "
        }

        return " "
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
