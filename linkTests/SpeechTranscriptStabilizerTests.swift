import XCTest
@testable import link

final class SpeechTranscriptStabilizerTests: XCTestCase {
    func testKoreanUsesWordSegmentedTokens() {
        var stabilizer = SpeechTranscriptStabilizer()

        _ = consume(
            &stabilizer,
            "오늘 날씨가 정말 너무 좋아요",
            language: .korean
        )

        let state = stabilizer.debugState
        XCTAssertEqual(state.segmentationMode, .wordSegmented)
        XCTAssertEqual(
            state.units.map(\.raw),
            ["오늘", " ", "날씨가", " ", "정말", " ", "너무", " ", "좋아요"]
        )
    }

    func testAnchoredMergePreservesSuffixPersistence() {
        var stabilizer = SpeechTranscriptStabilizer()
        let original = "I want to book a room tonight"
        let revised = "I want to quickly book a room tonight"

        _ = consume(&stabilizer, original, language: .english)
        _ = consume(&stabilizer, original, language: .english)
        _ = consume(&stabilizer, revised, language: .english)

        let state = stabilizer.debugState
        XCTAssertGreaterThanOrEqual(persistenceCount(for: "book", in: state), 2)
        XCTAssertGreaterThanOrEqual(persistenceCount(for: "room", in: state), 2)
        XCTAssertGreaterThanOrEqual(persistenceCount(for: "tonight", in: state), 2)
    }

    func testEndpointRejectsUnsafeTruncation() {
        var stabilizer = SpeechTranscriptStabilizer()
        let stableCandidate = "明天下午三点开会"
        let truncatedEndpoint = "明天下午三"

        _ = consume(&stabilizer, stableCandidate, language: .chinese)
        _ = consume(&stabilizer, stableCandidate, language: .chinese)

        let snapshot = consume(
            &stabilizer,
            truncatedEndpoint,
            language: .chinese,
            pauseStrength: .hard,
            isEndpoint: true
        )

        XCTAssertEqual(snapshot?.fullTranscript, stableCandidate)
    }

    func testHardPausePromotesStableMoreAggressivelyThanSoftPause() {
        let transcript = "I want to book a room for tomorrow morning"

        var softPauseStabilizer = SpeechTranscriptStabilizer()
        _ = consume(&softPauseStabilizer, transcript, language: .english)
        let softSnapshot = consume(
            &softPauseStabilizer,
            transcript,
            language: .english,
            pauseStrength: .soft
        )

        var hardPauseStabilizer = SpeechTranscriptStabilizer()
        _ = consume(&hardPauseStabilizer, transcript, language: .english)
        let hardSnapshot = consume(
            &hardPauseStabilizer,
            transcript,
            language: .english,
            pauseStrength: .hard
        )

        XCTAssertLessThan(
            softSnapshot?.stableTranscript.count ?? 0,
            hardSnapshot?.stableTranscript.count ?? 0
        )
    }

    func testTailRiskScoreKeepsAIShortButExpandsDateTail() {
        var lowRiskStabilizer = SpeechTranscriptStabilizer()
        _ = consume(
            &lowRiskStabilizer,
            "我们正在讨论 AI 产品方向",
            language: .chinese
        )

        var highRiskStabilizer = SpeechTranscriptStabilizer()
        _ = consume(
            &highRiskStabilizer,
            "我们 2026/04/06 15:00 见面",
            language: .chinese
        )

        XCTAssertEqual(lowRiskStabilizer.debugState.liveTailUnitCount, 8)
        XCTAssertEqual(highRiskStabilizer.debugState.liveTailUnitCount, 14)
    }

    func testLanguageSwitchRebuildsTokensAcrossSegmentationModes() {
        var stabilizer = SpeechTranscriptStabilizer()
        let transcript = "你好 world again"

        _ = consume(&stabilizer, transcript, language: .english)
        XCTAssertEqual(stabilizer.debugState.segmentationMode, .wordSegmented)
        XCTAssertEqual(stabilizer.debugState.units.map(\.raw), ["你好", " ", "world", " ", "again"])

        _ = consume(&stabilizer, transcript, language: .chinese)
        let state = stabilizer.debugState
        XCTAssertEqual(state.segmentationMode, .continuousCharacters)
        XCTAssertEqual(Array(state.units.map(\.raw).prefix(5)), ["你", "好", " ", "w", "o"])
    }

    func testRepairWindowKeepsEarlierStablePrefixLocked() {
        var stabilizer = SpeechTranscriptStabilizer()
        let original = "I want to book a quiet room for tonight"
        let revised = "I want to book a quiet room for tomorrow"

        _ = consume(&stabilizer, original, language: .english)
        _ = consume(
            &stabilizer,
            original,
            language: .english,
            pauseStrength: .hard
        )

        let stableBeforeRewrite = stabilizer.currentSnapshot.stableTranscript
        XCTAssertTrue(stableBeforeRewrite.contains("I want to book a quiet room"))

        _ = consume(&stabilizer, revised, language: .english)
        let snapshot = stabilizer.currentSnapshot

        XCTAssertTrue(snapshot.stableTranscript.contains("I want to book a quiet"))
        XCTAssertFalse(snapshot.liveTranscript.contains("I want to book a quiet"))
        XCTAssertTrue(snapshot.fullTranscript.contains("tomorrow"))
    }

    private func consume(
        _ stabilizer: inout SpeechTranscriptStabilizer,
        _ candidate: String,
        language: SupportedLanguage,
        pauseStrength: SpeechPauseStrength = .none,
        isEndpoint: Bool = false
    ) -> SpeechTranscriptionSnapshot? {
        stabilizer.consume(
            candidate: candidate,
            detectedLanguage: language,
            isEndpoint: isEndpoint,
            pauseStrength: pauseStrength
        )
    }

    private func persistenceCount(
        for token: String,
        in state: SpeechTranscriptStabilizerDebugState
    ) -> Int {
        guard let index = state.units.firstIndex(where: { $0.raw == token }) else {
            XCTFail("Missing token \(token) in debug state")
            return 0
        }

        return state.persistenceCounts[index]
    }
}
