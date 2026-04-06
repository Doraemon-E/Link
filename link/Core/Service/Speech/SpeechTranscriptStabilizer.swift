//
//  SpeechTranscriptStabilizer.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated struct SpeechTranscriptStabilizer: Sendable {
    private struct TranscriptUnit: Sendable, Equatable {
        let raw: String
        let normalized: String

        var isWhitespace: Bool {
            raw.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        var isBoundary: Bool {
            isWhitespace || raw.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0)
            }
        }

        var isStrongBoundary: Bool {
            raw.count == 1 && raw.first.map(Self.strongBoundaryCharacters.contains) == true
        }

        private static let strongBoundaryCharacters: Set<Character> = [
            "，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":"
        ]
    }

    private enum MergeStrategy: Sendable {
        case initial
        case keptCurrent(confirmedPrefixLength: Int)
        case replacedTail(confirmedPrefixLength: Int)
        case appendedFromOverlap
    }

    private struct MergeOutcome: Sendable {
        let units: [TranscriptUnit]
        let strategy: MergeStrategy
    }

    private let provisionalThreshold = 2
    private let stableThreshold = 3
    private let pauseLiveTailReductionForCJK = 2
    private let pauseLiveTailReductionCharactersForNonCJK = 4

    private var committedTranscript = ""
    private var latestUnits: [TranscriptUnit] = []
    private var previousUnits: [TranscriptUnit] = []
    private var previousPreviousUnits: [TranscriptUnit] = []
    private var persistenceCounts: [Int] = []
    private var stableUnitCount = 0
    private var revision = 0
    private var detectedLanguage: SupportedLanguage?
    private var currentHasPauseHint = false

    var currentSnapshot: SpeechTranscriptionSnapshot {
        makeSnapshot(isEndpoint: false)
    }

    mutating func consume(
        candidate: String,
        detectedLanguage: SupportedLanguage?,
        isEndpoint: Bool,
        hasPauseHint: Bool
    ) -> SpeechTranscriptionSnapshot? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else {
            return isEndpoint ? finalizeCurrentUtterance() : nil
        }

        let previousSnapshot = currentSnapshot
        self.detectedLanguage = detectedLanguage ?? self.detectedLanguage

        if isEndpoint {
            return commitEndpointCandidate(normalizedCandidate)
        }

        currentHasPauseHint = hasPauseHint

        let mergeOutcome = mergeLatestTranscript(with: normalizedCandidate)
        let acceptedUnits = mergeOutcome.units
        guard !acceptedUnits.isEmpty else {
            return nil
        }

        let sharedPrefixLength: Int
        switch mergeOutcome.strategy {
        case .keptCurrent(let confirmedPrefixLength), .replacedTail(let confirmedPrefixLength):
            sharedPrefixLength = confirmedPrefixLength
        case .initial, .appendedFromOverlap:
            sharedPrefixLength = 0
        }

        if sharedPrefixLength < stableUnitCount {
            let shouldEmitPauseOnly = previousSnapshot.detectedLanguage != self.detectedLanguage ||
                previousSnapshot.hasPauseHint != currentHasPauseHint
            guard shouldEmitPauseOnly else {
                return nil
            }

            revision += 1
            return makeSnapshot(isEndpoint: false)
        }

        let priorUnits = latestUnits
        previousPreviousUnits = previousUnits
        previousUnits = priorUnits
        latestUnits = acceptedUnits
        persistenceCounts = updatedPersistenceCounts(for: mergeOutcome)
        stableUnitCount = resolvedActiveBoundaries().stableEnd

        let updatedSnapshot = makeSnapshot(isEndpoint: false)
        let shouldEmit = previousSnapshot.stableTranscript != updatedSnapshot.stableTranscript ||
            previousSnapshot.provisionalTranscript != updatedSnapshot.provisionalTranscript ||
            previousSnapshot.liveTranscript != updatedSnapshot.liveTranscript ||
            previousSnapshot.detectedLanguage != updatedSnapshot.detectedLanguage ||
            previousSnapshot.hasPauseHint != updatedSnapshot.hasPauseHint

        guard shouldEmit else {
            return nil
        }

        revision += 1
        return makeSnapshot(isEndpoint: false)
    }

    mutating func finalizeCurrentUtterance() -> SpeechTranscriptionSnapshot? {
        let finalTranscript = currentActiveTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else {
            clearActiveState()
            return nil
        }

        committedTranscript = appendTranscriptSegment(
            to: committedTranscript,
            segment: finalTranscript,
            language: detectedLanguage
        )

        clearActiveState()
        revision += 1
        return makeSnapshot(isEndpoint: true, hasPauseHintOverride: true)
    }

    private var currentActiveTranscript: String {
        text(from: latestUnits)
    }

    private func makeSnapshot(
        isEndpoint: Bool,
        hasPauseHintOverride: Bool? = nil
    ) -> SpeechTranscriptionSnapshot {
        let activeSegments = activeDisplaySegments()

        return SpeechTranscriptionSnapshot(
            stableTranscript: activeSegments.stable,
            provisionalTranscript: activeSegments.provisional,
            liveTranscript: activeSegments.live,
            revision: revision,
            detectedLanguage: detectedLanguage,
            isEndpoint: isEndpoint,
            hasPauseHint: hasPauseHintOverride ?? currentHasPauseHint
        )
    }

    private func activeDisplaySegments() -> (stable: String, provisional: String, live: String) {
        guard !latestUnits.isEmpty else {
            return (committedTranscript, "", "")
        }

        let boundaries = resolvedActiveBoundaries()
        let activeStable = text(from: latestUnits.prefix(boundaries.stableEnd))
        let activeProvisional = text(from: latestUnits[boundaries.stableEnd..<boundaries.provisionalEnd])
        let activeLive = text(from: latestUnits.dropFirst(boundaries.provisionalEnd))

        if !activeStable.isEmpty {
            return (
                appendTranscriptSegment(
                    to: committedTranscript,
                    segment: activeStable,
                    language: detectedLanguage
                ),
                activeProvisional,
                activeLive
            )
        }

        if !activeProvisional.isEmpty {
            return (
                committedTranscript,
                leadingSegmentWithSeparator(
                    segment: activeProvisional,
                    precedingText: committedTranscript
                ),
                activeLive
            )
        }

        return (
            committedTranscript,
            "",
            leadingSegmentWithSeparator(
                segment: activeLive,
                precedingText: committedTranscript
            )
        )
    }

    private mutating func commitEndpointCandidate(_ candidate: String) -> SpeechTranscriptionSnapshot? {
        let finalUnits = mergeLatestTranscript(with: candidate).units
        let finalTranscript = text(from: finalUnits).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else {
            return finalizeCurrentUtterance()
        }

        committedTranscript = appendTranscriptSegment(
            to: committedTranscript,
            segment: finalTranscript,
            language: detectedLanguage
        )

        clearActiveState()
        revision += 1
        return makeSnapshot(isEndpoint: true, hasPauseHintOverride: true)
    }

    private mutating func clearActiveState() {
        latestUnits.removeAll(keepingCapacity: false)
        previousUnits.removeAll(keepingCapacity: false)
        previousPreviousUnits.removeAll(keepingCapacity: false)
        persistenceCounts.removeAll(keepingCapacity: false)
        stableUnitCount = 0
        currentHasPauseHint = false
    }

    private func mergeLatestTranscript(with candidate: String) -> MergeOutcome {
        let candidateUnits = makeUnits(from: candidate)
        guard !candidateUnits.isEmpty else {
            return MergeOutcome(units: latestUnits, strategy: .keptCurrent(confirmedPrefixLength: 0))
        }

        guard !latestUnits.isEmpty else {
            return MergeOutcome(units: candidateUnits, strategy: .initial)
        }

        let commonPrefixLength = longestLooseCommonPrefix(latestUnits, candidateUnits)
        if commonPrefixLength == candidateUnits.count, latestUnits.count > candidateUnits.count {
            return MergeOutcome(
                units: latestUnits,
                strategy: .keptCurrent(confirmedPrefixLength: commonPrefixLength)
            )
        }

        if commonPrefixLength > 0 {
            let mergedUnits = Array(latestUnits.prefix(commonPrefixLength)) +
                Array(candidateUnits.dropFirst(commonPrefixLength))
            return MergeOutcome(
                units: mergedUnits,
                strategy: .replacedTail(confirmedPrefixLength: commonPrefixLength)
            )
        }

        let overlapLength = longestLooseSuffixPrefixOverlap(latestUnits, candidateUnits)
        if overlapLength > 0 {
            return MergeOutcome(
                units: latestUnits + candidateUnits.dropFirst(overlapLength),
                strategy: .appendedFromOverlap
            )
        }

        return MergeOutcome(units: candidateUnits, strategy: .initial)
    }

    private func updatedPersistenceCounts(for outcome: MergeOutcome) -> [Int] {
        switch outcome.strategy {
        case .initial:
            return Array(repeating: 1, count: outcome.units.count)
        case .keptCurrent(let confirmedPrefixLength):
            var counts = paddedPersistenceCounts(length: outcome.units.count)
            for index in 0..<min(confirmedPrefixLength, counts.count) {
                counts[index] = min(counts[index] + 1, stableThreshold)
            }
            return counts
        case .replacedTail(let confirmedPrefixLength):
            var counts = Array(repeating: 1, count: outcome.units.count)
            for index in 0..<min(confirmedPrefixLength, min(persistenceCounts.count, counts.count)) {
                counts[index] = min(persistenceCounts[index] + 1, stableThreshold)
            }
            return counts
        case .appendedFromOverlap:
            var counts = paddedPersistenceCounts(length: latestUnits.count)
            counts.append(
                contentsOf: Array(
                    repeating: 1,
                    count: max(0, outcome.units.count - counts.count)
                )
            )
            return counts
        }
    }

    private func paddedPersistenceCounts(length: Int) -> [Int] {
        guard persistenceCounts.count < length else {
            return Array(persistenceCounts.prefix(length))
        }

        return persistenceCounts + Array(repeating: 1, count: length - persistenceCounts.count)
    }

    private func resolvedActiveBoundaries() -> (stableEnd: Int, provisionalEnd: Int) {
        guard !latestUnits.isEmpty else {
            return (0, 0)
        }

        let rawStableEnd = persistentPrefixLength(minimumCount: stableThreshold)
        let rawProvisionalEnd = persistentPrefixLength(minimumCount: provisionalThreshold)
        let nonLiveEnd = max(0, latestUnits.count - dynamicLiveTailUnitCount())

        var provisionalEnd = min(rawProvisionalEnd, nonLiveEnd)
        provisionalEnd = adjustedBoundary(
            for: provisionalEnd,
            preferStrongBoundary: false
        )

        var stableEnd = min(rawStableEnd, provisionalEnd)
        stableEnd = adjustedBoundary(
            for: stableEnd,
            preferStrongBoundary: true
        )

        if currentHasPauseHint, let promotedBoundary = pausePromotedStableBoundary(upTo: provisionalEnd) {
            stableEnd = max(stableEnd, promotedBoundary)
        }

        stableEnd = max(stableUnitCount, stableEnd)
        provisionalEnd = max(stableEnd, provisionalEnd)
        return (stableEnd, provisionalEnd)
    }

    private func persistentPrefixLength(minimumCount: Int) -> Int {
        var prefixLength = 0

        for count in persistenceCounts {
            guard count >= minimumCount else {
                break
            }

            prefixLength += 1
        }

        return prefixLength
    }

    private func dynamicLiveTailUnitCount() -> Int {
        let language = detectedLanguage
        let baseTailCount: Int

        if language?.usesContinuousScript == true {
            let defaultTail = 8
            let expandedTail = 14
            let riskText = text(from: latestUnits.suffix(min(defaultTail, latestUnits.count)))
            baseTailCount = containsHighRiskTailContent(riskText) ? expandedTail : defaultTail

            if currentHasPauseHint {
                return max(0, baseTailCount - pauseLiveTailReductionForCJK)
            }

            return baseTailCount
        }

        let defaultTail = tailUnitCountForNonContinuousScript(
            targetWordCount: 4,
            characterFallback: 12
        )
        let riskText = text(from: latestUnits.suffix(min(defaultTail, latestUnits.count)))
        let expandedTail = containsHighRiskTailContent(riskText)
            ? tailUnitCountForNonContinuousScript(targetWordCount: 6, characterFallback: 18)
            : defaultTail

        guard currentHasPauseHint else {
            return expandedTail
        }

        return max(0, expandedTail - pauseLiveTailReductionCharactersForNonCJK)
    }

    private func tailUnitCountForNonContinuousScript(
        targetWordCount: Int,
        characterFallback: Int
    ) -> Int {
        var wordsSeen = 0
        var charactersCounted = 0
        var isInsideWord = false

        for unit in latestUnits.reversed() {
            charactersCounted += 1

            if unit.isBoundary {
                if wordsSeen >= targetWordCount {
                    return charactersCounted
                }

                isInsideWord = false
                continue
            }

            if !isInsideWord {
                wordsSeen += 1
                isInsideWord = true
                if wordsSeen >= targetWordCount {
                    return charactersCounted
                }
            }
        }

        return min(latestUnits.count, characterFallback)
    }

    private func containsHighRiskTailContent(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        let riskScalars = CharacterSet(charactersIn: "$￥€£%元块月日号时分秒点:：/.-")
        var consecutiveASCIILetterCount = 0

        for character in text {
            if character.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
                return true
            }

            if "零一二三四五六七八九十百千万亿两".contains(character) {
                return true
            }

            if character.unicodeScalars.contains(where: riskScalars.contains) {
                return true
            }

            if character.isASCIILetter {
                consecutiveASCIILetterCount += 1
                if consecutiveASCIILetterCount >= 2 {
                    return true
                }
            } else {
                consecutiveASCIILetterCount = 0
            }
        }

        return false
    }

    private func adjustedBoundary(
        for boundary: Int,
        preferStrongBoundary: Bool
    ) -> Int {
        guard boundary > 0 else {
            return 0
        }

        if detectedLanguage?.usesContinuousScript == true {
            guard preferStrongBoundary else {
                return boundary
            }

            return nearestStrongBoundary(atOrBefore: boundary) ?? boundary
        }

        if preferStrongBoundary, let strongBoundary = nearestStrongBoundary(atOrBefore: boundary) {
            return strongBoundary
        }

        return nearestWordBoundary(atOrBefore: boundary) ?? 0
    }

    private func pausePromotedStableBoundary(upTo provisionalEnd: Int) -> Int? {
        let trimmedEnd = trimmedBoundaryEnd(provisionalEnd)
        guard trimmedEnd > 0 else {
            return nil
        }

        return latestUnits[trimmedEnd - 1].isStrongBoundary ? trimmedEnd : nil
    }

    private func trimmedBoundaryEnd(_ boundary: Int) -> Int {
        var index = min(boundary, latestUnits.count)
        while index > 0, latestUnits[index - 1].isWhitespace {
            index -= 1
        }

        return index
    }

    private func nearestStrongBoundary(atOrBefore boundary: Int) -> Int? {
        let trimmedEnd = trimmedBoundaryEnd(boundary)
        guard trimmedEnd > 0 else {
            return nil
        }

        for index in stride(from: trimmedEnd, through: 1, by: -1) {
            if latestUnits[index - 1].isStrongBoundary {
                return index
            }
        }

        return nil
    }

    private func nearestWordBoundary(atOrBefore boundary: Int) -> Int? {
        let trimmedEnd = min(boundary, latestUnits.count)
        guard trimmedEnd > 0 else {
            return nil
        }

        for index in stride(from: trimmedEnd, through: 1, by: -1) {
            if latestUnits[index - 1].isBoundary {
                return index
            }
        }

        return nil
    }

    private func makeUnits(from text: String) -> [TranscriptUnit] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return []
        }

        var units: [TranscriptUnit] = []
        units.reserveCapacity(normalizedText.count)

        for character in normalizedText {
            if character.isWhitespaceOrNewline {
                if units.last?.normalized == " " {
                    continue
                }

                units.append(TranscriptUnit(raw: " ", normalized: " "))
                continue
            }

            units.append(
                TranscriptUnit(
                    raw: String(character),
                    normalized: normalizeComparisonValue(for: character)
                )
            )
        }

        return units
    }

    private func normalizeComparisonValue(for character: Character) -> String {
        switch character {
        case "，":
            return ","
        case "。":
            return "."
        case "！":
            return "!"
        case "？":
            return "?"
        case "；":
            return ";"
        case "：":
            return ":"
        case "（":
            return "("
        case "）":
            return ")"
        case "【":
            return "["
        case "】":
            return "]"
        case "「", "『":
            return "\""
        case "」", "』":
            return "\""
        default:
            let string = String(character)
            if string.unicodeScalars.allSatisfy(\.isASCII) {
                return string.lowercased()
            }

            return string
        }
    }

    private func text<S: Sequence>(from units: S) -> String where S.Element == TranscriptUnit {
        units.map(\.raw).joined()
    }

    private func longestLooseCommonPrefix(
        _ lhs: [TranscriptUnit],
        _ rhs: [TranscriptUnit]
    ) -> Int {
        var count = 0

        for (leftUnit, rightUnit) in zip(lhs, rhs) {
            guard leftUnit.normalized == rightUnit.normalized else {
                break
            }

            count += 1
        }

        return count
    }

    private func longestLooseSuffixPrefixOverlap(
        _ lhs: [TranscriptUnit],
        _ rhs: [TranscriptUnit]
    ) -> Int {
        let maxOverlap = min(lhs.count, rhs.count)
        guard maxOverlap > 0 else {
            return 0
        }

        for overlapLength in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsSuffix = lhs.suffix(overlapLength)
            let rhsPrefix = rhs.prefix(overlapLength)
            if zip(lhsSuffix, rhsPrefix).allSatisfy({ $0.normalized == $1.normalized }) {
                return overlapLength
            }
        }

        return 0
    }

    private func leadingSegmentWithSeparator(
        segment: String,
        precedingText: String
    ) -> String {
        guard !segment.isEmpty else {
            return ""
        }

        let separator = transcriptSeparatorPrefix(
            previous: precedingText,
            next: segment,
            language: detectedLanguage
        )
        return separator + segment
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

        if language?.usesContinuousScript == true {
            return ""
        }

        guard let previousCharacter = normalizedPrevious.last,
              let nextCharacter = normalizedNext.first else {
            return ""
        }

        if previousCharacter.isWhitespaceOrNewline || nextCharacter.isWhitespaceOrNewline {
            return ""
        }

        return " "
    }
}

private nonisolated extension SupportedLanguage {
    var usesContinuousScript: Bool {
        [.chinese, .japanese, .korean].contains(self)
    }
}

private nonisolated extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var isASCIILetter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.isASCII &&
                CharacterSet.letters.contains(scalar)
        }
    }
}
