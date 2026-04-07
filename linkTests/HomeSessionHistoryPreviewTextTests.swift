//
//  HomeSessionHistoryPreviewTextTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/7.
//

import XCTest
@testable import link

final class HomeSessionHistoryPreviewTextTests: XCTestCase {
    func testResolvePrefersLatestSourceTextWhenTranslationAlsoExists() {
        let messages = [
            makeMessage(sequence: 0, sourceText: "Older source", translatedText: "旧翻译"),
            makeMessage(sequence: 1, sourceText: "Latest source", translatedText: "最新翻译")
        ]

        let previewText = HomeSessionHistoryPreviewText.resolve(fromSortedMessages: messages)

        XCTAssertEqual(previewText, "Latest source")
    }

    func testResolveSkipsLatestMessageWhenSourceTextIsEmpty() {
        let messages = [
            makeMessage(sequence: 0, sourceText: "Older source", translatedText: "较早原文对应翻译"),
            makeMessage(sequence: 1, sourceText: " \n\t ", translatedText: "Latest translation")
        ]

        let previewText = HomeSessionHistoryPreviewText.resolve(fromSortedMessages: messages)

        XCTAssertEqual(previewText, "Older source")
    }

    func testResolveReturnsFallbackWhenAllSourceTextIsEmpty() {
        let messages = [
            makeMessage(sequence: 0, sourceText: "", translatedText: "Only translation"),
            makeMessage(sequence: 1, sourceText: "  ", translatedText: "Another translation")
        ]

        let previewText = HomeSessionHistoryPreviewText.resolve(fromSortedMessages: messages)

        XCTAssertEqual(previewText, HomeSessionHistoryPreviewText.emptySessionFallback)
    }

    func testResolveTrimsWhitespaceBeforeReturningSourceText() {
        let messages = [
            makeMessage(sequence: 0, sourceText: "  Trimmed source \n", translatedText: "翻译")
        ]

        let previewText = HomeSessionHistoryPreviewText.resolve(fromSortedMessages: messages)

        XCTAssertEqual(previewText, "Trimmed source")
    }

    private func makeMessage(
        sequence: Int,
        sourceText: String,
        translatedText: String
    ) -> ChatMessage {
        ChatMessage(
            sourceText: sourceText,
            translatedText: translatedText,
            sequence: sequence
        )
    }
}
