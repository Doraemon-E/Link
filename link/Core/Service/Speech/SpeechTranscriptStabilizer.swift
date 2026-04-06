//
//  SpeechTranscriptStabilizer.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated enum TranscriptSegmentationMode: Sendable {
    case continuousCharacters
    case wordSegmented
}

#if DEBUG
nonisolated struct SpeechTranscriptStabilizerDebugState: Sendable {
    nonisolated enum UnitKind: String, Sendable {
        case word
        case whitespace
        case punctuation
        case symbol
    }

    nonisolated struct Unit: Sendable, Equatable {
        let raw: String
        let kind: UnitKind
    }

    let units: [Unit]
    let persistenceCounts: [Int]
    let stableUnitCount: Int
    let segmentationMode: TranscriptSegmentationMode
    let liveTailUnitCount: Int
}
#endif

nonisolated struct SpeechTranscriptStabilizer: Sendable {
    private enum TranscriptUnitKind: Sendable {
        case word
        case whitespace
        case punctuation
        case symbol
    }

    private struct TranscriptUnit: Sendable, Equatable {
        let raw: String
        let normalized: String
        let kind: TranscriptUnitKind

        var isWhitespace: Bool {
            kind == .whitespace
        }

        var isWord: Bool {
            kind == .word
        }

        var isBoundary: Bool {
            kind != .word
        }

        var isStrongBoundary: Bool {
            kind == .punctuation &&
                raw.count == 1 &&
                raw.first.map(Self.strongBoundaryCharacters.contains) == true
        }

        var isSafeEndpointBoundary: Bool {
            switch kind {
            case .word:
                return false
            case .whitespace, .punctuation, .symbol:
                return true
            }
        }

        private static let strongBoundaryCharacters: Set<Character> = [
            "，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":"
        ]
    }

    private enum MergeStrategy: Sendable {
        case initial
        case keptCurrent(confirmedPrefixLength: Int)
        case anchoredReplace(confirmedPrefixLength: Int, preservedSuffixLength: Int)
        case appendedFromOverlap(overlapLength: Int)
    }

    private struct MergeOutcome: Sendable {
        let units: [TranscriptUnit]
        let persistenceCounts: [Int]
        let strategy: MergeStrategy
        let preservedPrefixLength: Int
    }

    private let provisionalThreshold = 2
    private let stableThreshold = 3
    private let continuousRepairWindowUnitCount = 2
    private let softPauseLiveTailReductionForContinuous = 2
    private let hardPauseLiveTailReductionForContinuous = 4
    private let softPauseLiveTailReductionForWordMode = 1
    private let hardPauseLiveTailReductionForWordMode = 2
    private let unsafeEndpointShorteningLimitForContinuous = 2
    private let unsafeEndpointShorteningLimitForWordMode = 1

    private var committedTranscript = ""
    private var latestUnits: [TranscriptUnit] = []
    private var previousUnits: [TranscriptUnit] = []
    private var previousPreviousUnits: [TranscriptUnit] = []
    private var persistenceCounts: [Int] = []
    private var stableUnitCount = 0
    private var revision = 0
    private var detectedLanguage: SupportedLanguage?
    private var currentPauseStrength: SpeechPauseStrength = .none

    var currentSnapshot: SpeechTranscriptionSnapshot {
        makeSnapshot(isEndpoint: false)
    }

    #if DEBUG
    var debugState: SpeechTranscriptStabilizerDebugState {
        SpeechTranscriptStabilizerDebugState(
            units: latestUnits.map { unit in
                SpeechTranscriptStabilizerDebugState.Unit(
                    raw: unit.raw,
                    kind: debugUnitKind(for: unit.kind)
                )
            },
            persistenceCounts: persistenceCounts,
            stableUnitCount: stableUnitCount,
            segmentationMode: currentSegmentationMode(),
            liveTailUnitCount: dynamicLiveTailUnitCount()
        )
    }
    #endif

    mutating func consume(
        candidate: String,
        detectedLanguage: SupportedLanguage?,
        isEndpoint: Bool,
        pauseStrength: SpeechPauseStrength
    ) -> SpeechTranscriptionSnapshot? {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else {
            return isEndpoint ? finalizeCurrentUtterance() : nil
        }

        let previousSnapshot = currentSnapshot
        let previousSegmentationMode = currentSegmentationMode()
        self.detectedLanguage = detectedLanguage ?? self.detectedLanguage

        if currentSegmentationMode() != previousSegmentationMode {
            rebuildActiveStateForCurrentSegmentationMode()
        }

        if isEndpoint {
            return commitEndpointCandidate(normalizedCandidate)
        }

        currentPauseStrength = pauseStrength

        let mergeOutcome = mergeLatestTranscript(with: normalizedCandidate)
        guard !mergeOutcome.units.isEmpty else {
            return emitCurrentSnapshotIfChanged(comparedTo: previousSnapshot, isEndpoint: false)
        }

        if mergeOutcome.preservedPrefixLength < lockedStablePrefixLength() {
            return emitCurrentSnapshotIfChanged(comparedTo: previousSnapshot, isEndpoint: false)
        }

        let priorUnits = latestUnits
        previousPreviousUnits = previousUnits
        previousUnits = priorUnits
        latestUnits = mergeOutcome.units
        persistenceCounts = mergeOutcome.persistenceCounts
        stableUnitCount = resolvedActiveBoundaries().stableEnd

        return emitCurrentSnapshotIfChanged(comparedTo: previousSnapshot, isEndpoint: false)
    }

    mutating func consume(
        candidate: String,
        detectedLanguage: SupportedLanguage?,
        isEndpoint: Bool,
        hasPauseHint: Bool
    ) -> SpeechTranscriptionSnapshot? {
        consume(
            candidate: candidate,
            detectedLanguage: detectedLanguage,
            isEndpoint: isEndpoint,
            pauseStrength: hasPauseHint ? .soft : .none
        )
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
        return makeSnapshot(isEndpoint: true, pauseStrengthOverride: .hard)
    }

    private var currentActiveTranscript: String {
        text(from: latestUnits)
    }

    private func makeSnapshot(
        isEndpoint: Bool,
        pauseStrengthOverride: SpeechPauseStrength? = nil
    ) -> SpeechTranscriptionSnapshot {
        let activeSegments = activeDisplaySegments()

        return SpeechTranscriptionSnapshot(
            stableTranscript: activeSegments.stable,
            provisionalTranscript: activeSegments.provisional,
            liveTranscript: activeSegments.live,
            revision: revision,
            detectedLanguage: detectedLanguage,
            isEndpoint: isEndpoint,
            pauseStrength: pauseStrengthOverride ?? currentPauseStrength
        )
    }

    private mutating func emitCurrentSnapshotIfChanged(
        comparedTo previousSnapshot: SpeechTranscriptionSnapshot,
        isEndpoint: Bool
    ) -> SpeechTranscriptionSnapshot? {
        let updatedSnapshot = makeSnapshot(isEndpoint: isEndpoint)
        guard snapshotChanged(previousSnapshot, updatedSnapshot) else {
            return nil
        }

        revision += 1
        return makeSnapshot(isEndpoint: isEndpoint)
    }

    private func snapshotChanged(
        _ lhs: SpeechTranscriptionSnapshot,
        _ rhs: SpeechTranscriptionSnapshot
    ) -> Bool {
        lhs.stableTranscript != rhs.stableTranscript ||
            lhs.provisionalTranscript != rhs.provisionalTranscript ||
            lhs.liveTranscript != rhs.liveTranscript ||
            lhs.detectedLanguage != rhs.detectedLanguage ||
            lhs.pauseStrength != rhs.pauseStrength ||
            lhs.isEndpoint != rhs.isEndpoint
    }

    private func activeDisplaySegments() -> (stable: String, provisional: String, live: String) {
        guard !latestUnits.isEmpty else {
            return (committedTranscript, "", "")
        }

        let activeSegments = activeUnitSegments()

        if !activeSegments.stable.isEmpty {
            return (
                appendTranscriptSegment(
                    to: committedTranscript,
                    segment: activeSegments.stable,
                    language: detectedLanguage
                ),
                activeSegments.provisional,
                activeSegments.live
            )
        }

        if !activeSegments.provisional.isEmpty {
            return (
                committedTranscript,
                leadingSegmentWithSeparator(
                    segment: activeSegments.provisional,
                    precedingText: committedTranscript
                ),
                activeSegments.live
            )
        }

        return (
            committedTranscript,
            "",
            leadingSegmentWithSeparator(
                segment: activeSegments.live,
                precedingText: committedTranscript
            )
        )
    }

    private func activeUnitSegments() -> (stable: String, provisional: String, live: String) {
        guard !latestUnits.isEmpty else {
            return ("", "", "")
        }

        let boundaries = resolvedActiveBoundaries()
        return (
            text(from: latestUnits.prefix(boundaries.stableEnd)),
            text(from: latestUnits[boundaries.stableEnd..<boundaries.provisionalEnd]),
            text(from: latestUnits.dropFirst(boundaries.provisionalEnd))
        )
    }

    private mutating func rebuildActiveStateForCurrentSegmentationMode() {
        guard !latestUnits.isEmpty else {
            return
        }

        let segments = activeUnitSegments()
        let stableUnits = makeUnits(from: segments.stable)
        let provisionalUnits = makeUnits(from: segments.provisional)
        let liveUnits = makeUnits(from: segments.live)

        latestUnits = stableUnits + provisionalUnits + liveUnits
        persistenceCounts =
            Array(repeating: stableThreshold, count: stableUnits.count) +
            Array(repeating: provisionalThreshold, count: provisionalUnits.count) +
            Array(repeating: 1, count: liveUnits.count)
        stableUnitCount = stableUnits.count
        previousUnits.removeAll(keepingCapacity: false)
        previousPreviousUnits.removeAll(keepingCapacity: false)
    }

    private mutating func commitEndpointCandidate(_ candidate: String) -> SpeechTranscriptionSnapshot? {
        let mergeOutcome = mergeLatestTranscript(with: candidate)
        let finalUnits = preferredEndpointUnits(from: mergeOutcome)
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
        return makeSnapshot(isEndpoint: true, pauseStrengthOverride: .hard)
    }

    private func preferredEndpointUnits(from mergeOutcome: MergeOutcome) -> [TranscriptUnit] {
        guard !latestUnits.isEmpty else {
            return mergeOutcome.units
        }

        guard !mergeOutcome.units.isEmpty else {
            return latestUnits
        }

        let currentTranscript = text(from: latestUnits).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTranscript = text(from: mergeOutcome.units).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateTranscript.isEmpty else {
            return latestUnits
        }

        guard candidateTranscript != currentTranscript else {
            return mergeOutcome.units
        }

        if mergeOutcome.preservedPrefixLength < lockedStablePrefixLength() {
            return latestUnits
        }

        guard mergeOutcome.units.count < latestUnits.count else {
            return mergeOutcome.units
        }

        if endsAtSafeEndpointBoundary(mergeOutcome.units) {
            return mergeOutcome.units
        }

        let shorteningMagnitude = endpointShorteningMagnitude(
            currentUnits: latestUnits,
            candidateUnits: mergeOutcome.units
        )
        let shorteningLimit = currentSegmentationMode() == .continuousCharacters
            ? unsafeEndpointShorteningLimitForContinuous
            : unsafeEndpointShorteningLimitForWordMode

        return shorteningMagnitude > shorteningLimit ? latestUnits : mergeOutcome.units
    }

    private mutating func clearActiveState() {
        latestUnits.removeAll(keepingCapacity: false)
        previousUnits.removeAll(keepingCapacity: false)
        previousPreviousUnits.removeAll(keepingCapacity: false)
        persistenceCounts.removeAll(keepingCapacity: false)
        stableUnitCount = 0
        currentPauseStrength = .none
    }

    private func mergeLatestTranscript(with candidate: String) -> MergeOutcome {
        let candidateUnits = makeUnits(from: candidate)
        guard !candidateUnits.isEmpty else {
            return MergeOutcome(
                units: latestUnits,
                persistenceCounts: persistenceCounts,
                strategy: .keptCurrent(confirmedPrefixLength: 0),
                preservedPrefixLength: latestUnits.count
            )
        }

        guard !latestUnits.isEmpty else {
            return MergeOutcome(
                units: candidateUnits,
                persistenceCounts: Array(repeating: 1, count: candidateUnits.count),
                strategy: .initial,
                preservedPrefixLength: 0
            )
        }

        let commonPrefixLength = longestLooseCommonPrefix(latestUnits, candidateUnits)
        if commonPrefixLength == candidateUnits.count, latestUnits.count > candidateUnits.count {
            var counts = paddedPersistenceCounts(length: latestUnits.count)
            for index in 0..<min(commonPrefixLength, counts.count) {
                counts[index] = min(counts[index] + 1, stableThreshold)
            }

            return MergeOutcome(
                units: latestUnits,
                persistenceCounts: counts,
                strategy: .keptCurrent(confirmedPrefixLength: commonPrefixLength),
                preservedPrefixLength: latestUnits.count
            )
        }

        let commonSuffixLength = longestLooseCommonSuffix(
            latestUnits,
            candidateUnits,
            excludingCommonPrefix: commonPrefixLength
        )

        if commonPrefixLength > 0 || commonSuffixLength > 0 {
            var counts = Array(repeating: 1, count: candidateUnits.count)
            for index in 0..<min(commonPrefixLength, min(latestUnits.count, candidateUnits.count)) {
                counts[index] = min(persistenceCounts[safe: index, default: 1] + 1, stableThreshold)
            }

            if commonSuffixLength > 0 {
                for offset in 0..<commonSuffixLength {
                    let oldIndex = latestUnits.count - commonSuffixLength + offset
                    let newIndex = candidateUnits.count - commonSuffixLength + offset
                    counts[newIndex] = min(persistenceCounts[safe: oldIndex, default: 1] + 1, stableThreshold)
                }
            }

            return MergeOutcome(
                units: candidateUnits,
                persistenceCounts: counts,
                strategy: .anchoredReplace(
                    confirmedPrefixLength: commonPrefixLength,
                    preservedSuffixLength: commonSuffixLength
                ),
                preservedPrefixLength: commonPrefixLength
            )
        }

        let overlapLength = longestLooseSuffixPrefixOverlap(latestUnits, candidateUnits)
        if overlapLength > 0 {
            var counts = paddedPersistenceCounts(length: latestUnits.count)
            counts.append(
                contentsOf: Array(
                    repeating: 1,
                    count: max(0, latestUnits.count + candidateUnits.count - overlapLength - counts.count)
                )
            )

            return MergeOutcome(
                units: latestUnits + candidateUnits.dropFirst(overlapLength),
                persistenceCounts: counts,
                strategy: .appendedFromOverlap(overlapLength: overlapLength),
                preservedPrefixLength: latestUnits.count
            )
        }

        return MergeOutcome(
            units: candidateUnits,
            persistenceCounts: Array(repeating: 1, count: candidateUnits.count),
            strategy: .initial,
            preservedPrefixLength: 0
        )
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

        if currentPauseStrength != .none,
           let promotedBoundary = pausePromotedStableBoundary(
               upTo: provisionalEnd,
               allowWordBoundaryFallback: currentPauseStrength == .hard
           ) {
            stableEnd = max(stableEnd, promotedBoundary)
        }

        if currentPauseStrength == .hard {
            let relaxedStableEnd = min(
                persistentPrefixLength(minimumCount: max(provisionalThreshold, stableThreshold - 1)),
                provisionalEnd
            )
            stableEnd = max(
                stableEnd,
                adjustedBoundary(for: relaxedStableEnd, preferStrongBoundary: false)
            )
        }

        stableEnd = max(lockedStablePrefixLength(), stableEnd)
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
        let baseRiskScore = tailRiskScore(text(from: riskSampleTailUnits()))

        switch currentSegmentationMode() {
        case .continuousCharacters:
            let baseTailCount: Int
            switch baseRiskScore {
            case 4...:
                baseTailCount = 14
            case 2...:
                baseTailCount = 11
            default:
                baseTailCount = 8
            }

            return max(0, baseTailCount - liveTailReductionForCurrentPauseStrength())

        case .wordSegmented:
            let baseWordCount: Int
            switch baseRiskScore {
            case 4...:
                baseWordCount = 6
            case 2...:
                baseWordCount = 5
            default:
                baseWordCount = 4
            }

            return unitCountForTrailingWords(max(0, baseWordCount - liveTailReductionForCurrentPauseStrength()))
        }
    }

    private func riskSampleTailUnits() -> ArraySlice<TranscriptUnit> {
        switch currentSegmentationMode() {
        case .continuousCharacters:
            return latestUnits.suffix(min(14, latestUnits.count))
        case .wordSegmented:
            return latestUnits.suffix(min(unitCountForTrailingWords(6), latestUnits.count))
        }
    }

    private func liveTailReductionForCurrentPauseStrength() -> Int {
        switch (currentSegmentationMode(), currentPauseStrength) {
        case (.continuousCharacters, .soft):
            return softPauseLiveTailReductionForContinuous
        case (.continuousCharacters, .hard):
            return hardPauseLiveTailReductionForContinuous
        case (.wordSegmented, .soft):
            return softPauseLiveTailReductionForWordMode
        case (.wordSegmented, .hard):
            return hardPauseLiveTailReductionForWordMode
        case (_, .none):
            return 0
        }
    }

    private func unitCountForTrailingWords(_ targetWordCount: Int) -> Int {
        guard targetWordCount > 0 else {
            return 0
        }

        var wordsSeen = 0
        var unitsCounted = 0

        for unit in latestUnits.reversed() {
            unitsCounted += 1
            if unit.isWord {
                wordsSeen += 1
                if wordsSeen >= targetWordCount {
                    return unitsCounted
                }
            }
        }

        return latestUnits.count
    }

    private func tailRiskScore(_ text: String) -> Int {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return 0
        }

        var score = 0

        if normalizedText.range(
            of: #"([$￥€£]\s*\d)|(\d\s*[%％])|(\d\s*[月日号时分秒点元块])|(\d\s*[:：/／.-]\s*\d)"#,
            options: .regularExpression
        ) != nil {
            score += 3
        }

        if normalizedText.range(
            of: #"\d{2,}|[A-Za-z]+\d+|\d+[A-Za-z]+"#,
            options: .regularExpression
        ) != nil {
            score += 2
        }

        if normalizedText.range(
            of: #"\b[A-Za-z]{2,}\b"#,
            options: .regularExpression
        ) != nil {
            score += 1
        }

        return score
    }

    private func adjustedBoundary(
        for boundary: Int,
        preferStrongBoundary: Bool
    ) -> Int {
        guard boundary > 0 else {
            return 0
        }

        switch currentSegmentationMode() {
        case .continuousCharacters:
            guard preferStrongBoundary else {
                return boundary
            }

            return nearestStrongBoundary(atOrBefore: boundary, in: latestUnits) ?? boundary

        case .wordSegmented:
            let trimmedEnd = trimmedBoundaryEnd(boundary, in: latestUnits)
            guard trimmedEnd > 0 else {
                return 0
            }

            if preferStrongBoundary,
               let strongBoundary = nearestStrongBoundary(atOrBefore: trimmedEnd, in: latestUnits) {
                return strongBoundary
            }

            return trimmedEnd
        }
    }

    private func pausePromotedStableBoundary(
        upTo provisionalEnd: Int,
        allowWordBoundaryFallback: Bool
    ) -> Int? {
        let trimmedEnd = trimmedBoundaryEnd(provisionalEnd, in: latestUnits)
        guard trimmedEnd > 0 else {
            return nil
        }

        if let strongBoundary = nearestStrongBoundary(atOrBefore: trimmedEnd, in: latestUnits) {
            return strongBoundary
        }

        guard allowWordBoundaryFallback, currentSegmentationMode() == .wordSegmented else {
            return nil
        }

        return trimmedEnd
    }

    private func trimmedBoundaryEnd(
        _ boundary: Int,
        in units: [TranscriptUnit]
    ) -> Int {
        var index = min(boundary, units.count)
        while index > 0, units[index - 1].isWhitespace {
            index -= 1
        }

        return index
    }

    private func nearestStrongBoundary(
        atOrBefore boundary: Int,
        in units: [TranscriptUnit]
    ) -> Int? {
        let trimmedEnd = trimmedBoundaryEnd(boundary, in: units)
        guard trimmedEnd > 0 else {
            return nil
        }

        for index in stride(from: trimmedEnd, through: 1, by: -1) {
            if units[index - 1].isStrongBoundary {
                return index
            }
        }

        return nil
    }

    private func lockedStablePrefixLength() -> Int {
        let stableEnd = min(stableUnitCount, latestUnits.count)
        guard stableEnd > 0 else {
            return 0
        }

        switch currentSegmentationMode() {
        case .continuousCharacters:
            return max(0, stableEnd - continuousRepairWindowUnitCount)
        case .wordSegmented:
            for index in stride(from: stableEnd - 1, through: 0, by: -1) {
                if latestUnits[index].isWord {
                    return index
                }
            }

            return max(0, stableEnd - 1)
        }
    }

    private func endsAtSafeEndpointBoundary(_ units: [TranscriptUnit]) -> Bool {
        let trimmedEnd = trimmedBoundaryEnd(units.count, in: units)
        guard trimmedEnd > 0 else {
            return false
        }

        switch currentSegmentationMode() {
        case .continuousCharacters:
            return units[trimmedEnd - 1].isStrongBoundary
        case .wordSegmented:
            return units[trimmedEnd - 1].isSafeEndpointBoundary
        }
    }

    private func endpointShorteningMagnitude(
        currentUnits: [TranscriptUnit],
        candidateUnits: [TranscriptUnit]
    ) -> Int {
        switch currentSegmentationMode() {
        case .continuousCharacters:
            let currentText = text(from: currentUnits).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateText = text(from: candidateUnits).trimmingCharacters(in: .whitespacesAndNewlines)
            return max(0, currentText.count - candidateText.count)

        case .wordSegmented:
            return max(0, wordTokenCount(in: currentUnits) - wordTokenCount(in: candidateUnits))
        }
    }

    private func wordTokenCount(in units: [TranscriptUnit]) -> Int {
        units.reduce(into: 0) { partialResult, unit in
            if unit.isWord {
                partialResult += 1
            }
        }
    }

    private func makeUnits(from text: String) -> [TranscriptUnit] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return []
        }

        switch currentSegmentationMode() {
        case .continuousCharacters:
            return characterUnits(from: normalizedText)
        case .wordSegmented:
            return wordSegmentedUnits(from: normalizedText)
        }
    }

    private func characterUnits(from text: String) -> [TranscriptUnit] {
        var units: [TranscriptUnit] = []
        units.reserveCapacity(text.count)

        for character in text {
            if character.isWhitespaceOrNewline {
                if units.last?.kind == .whitespace {
                    continue
                }

                units.append(makeUnit(raw: " ", kind: .whitespace))
                continue
            }

            units.append(makeUnit(raw: String(character), kind: classifyCharacterKind(character)))
        }

        return units
    }

    private func wordSegmentedUnits(from text: String) -> [TranscriptUnit] {
        let characters = Array(text)
        var units: [TranscriptUnit] = []
        units.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if character.isWhitespaceOrNewline {
                if units.last?.kind != .whitespace {
                    units.append(makeUnit(raw: " ", kind: .whitespace))
                }

                index += 1
                while index < characters.count, characters[index].isWhitespaceOrNewline {
                    index += 1
                }
                continue
            }

            if character.isWordSegmentCoreCharacter {
                let startIndex = index
                index += 1

                while index < characters.count {
                    let nextCharacter = characters[index]
                    if nextCharacter.isWordSegmentCoreCharacter {
                        index += 1
                        continue
                    }

                    if nextCharacter.isWordSegmentConnector,
                       index + 1 < characters.count,
                       characters[index - 1].isWordSegmentCoreCharacter,
                       characters[index + 1].isWordSegmentCoreCharacter {
                        index += 1
                        continue
                    }

                    break
                }

                let rawToken = String(characters[startIndex..<index])
                units.append(makeUnit(raw: rawToken, kind: .word))
                continue
            }

            units.append(makeUnit(raw: String(character), kind: classifyCharacterKind(character)))
            index += 1
        }

        return units
    }

    private func makeUnit(raw: String, kind: TranscriptUnitKind) -> TranscriptUnit {
        TranscriptUnit(
            raw: raw,
            normalized: normalizeComparisonValue(for: raw),
            kind: kind
        )
    }

    private func classifyCharacterKind(_ character: Character) -> TranscriptUnitKind {
        if character.isWhitespaceOrNewline {
            return .whitespace
        }

        if character.isPunctuationLike {
            return .punctuation
        }

        if character.isWordSegmentCoreCharacter {
            return .word
        }

        return .symbol
    }

    private func normalizeComparisonValue(for token: String) -> String {
        token.map(normalizeComparisonCharacter).joined().lowercased()
    }

    private func normalizeComparisonCharacter(_ character: Character) -> String {
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
        case "「", "『", "“", "”":
            return "\""
        case "」", "』":
            return "\""
        case "'", "’":
            return "'"
        case "-", "—":
            return "-"
        case "…":
            return "..."
        case "　":
            return " "
        case "％":
            return "%"
        case "／":
            return "/"
        default:
            return String(character)
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

    private func longestLooseCommonSuffix(
        _ lhs: [TranscriptUnit],
        _ rhs: [TranscriptUnit],
        excludingCommonPrefix commonPrefixLength: Int
    ) -> Int {
        let maxSuffixLength = min(lhs.count - commonPrefixLength, rhs.count - commonPrefixLength)
        guard maxSuffixLength > 0 else {
            return 0
        }

        var suffixLength = 0
        while suffixLength < maxSuffixLength {
            let leftUnit = lhs[lhs.count - suffixLength - 1]
            let rightUnit = rhs[rhs.count - suffixLength - 1]
            guard leftUnit.normalized == rightUnit.normalized else {
                break
            }

            suffixLength += 1
        }

        return suffixLength
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

        if language?.transcriptSegmentationMode == .continuousCharacters {
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

    private func currentSegmentationMode() -> TranscriptSegmentationMode {
        detectedLanguage?.transcriptSegmentationMode ?? .wordSegmented
    }

    #if DEBUG
    private func debugUnitKind(for kind: TranscriptUnitKind) -> SpeechTranscriptStabilizerDebugState.UnitKind {
        switch kind {
        case .word:
            return .word
        case .whitespace:
            return .whitespace
        case .punctuation:
            return .punctuation
        case .symbol:
            return .symbol
        }
    }
    #endif
}

private nonisolated extension SupportedLanguage {
    var transcriptSegmentationMode: TranscriptSegmentationMode {
        switch self {
        case .chinese, .japanese:
            return .continuousCharacters
        case .english, .korean, .french, .german, .russian, .spanish, .italian:
            return .wordSegmented
        }
    }
}

private nonisolated extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var isPunctuationLike: Bool {
        unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } || self == "…"
    }

    var isWordSegmentCoreCharacter: Bool {
        guard !isWhitespaceOrNewline, !isPunctuationLike else {
            return false
        }

        return unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    var isWordSegmentConnector: Bool {
        self == "'" || self == "’" || self == "-"
    }
}

private nonisolated extension Array where Element == Int {
    subscript(safe index: Int, default defaultValue: Int) -> Int {
        guard indices.contains(index) else {
            return defaultValue
        }

        return self[index]
    }
}
