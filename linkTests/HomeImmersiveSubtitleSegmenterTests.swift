//
//  HomeImmersiveSubtitleSegmenterTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/7.
//

import XCTest
@testable import link

final class HomeImmersiveSubtitleSegmenterTests: XCTestCase {
    func testSentenceEndingPunctuationCommitsCompletedSegments() {
        let result = HomeImmersiveSubtitleSegmenter.segment(
            text: "你好。再见",
            flushActiveText: false
        )

        XCTAssertEqual(result.committedSegments, ["你好。"])
        XCTAssertEqual(result.activeText, "再见")
    }

    func testCommaDoesNotCommitSegment() {
        let result = HomeImmersiveSubtitleSegmenter.segment(
            text: "你好，再见",
            flushActiveText: false
        )

        XCTAssertEqual(result.committedSegments, [])
        XCTAssertEqual(result.activeText, "你好，再见")
    }

    func testEndpointFlushesTrailingActiveTextIntoCommittedSegments() {
        let result = HomeImmersiveSubtitleSegmenter.segment(
            text: "你好。再见",
            flushActiveText: true
        )

        XCTAssertEqual(result.committedSegments, ["你好。", "再见"])
        XCTAssertEqual(result.activeText, "")
    }
}
