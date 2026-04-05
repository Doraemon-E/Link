//
//  TextLanguageRecognitionServiceTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/5.
//

import NaturalLanguage
import XCTest
@testable import link

final class TextLanguageRecognitionServiceTests: XCTestCase {
    private var service: SystemTextLanguageRecognitionService!

    override func setUp() {
        super.setUp()
        service = SystemTextLanguageRecognitionService()
    }

    func testHomeLanguageCanResolveNaturalLanguageCodes() {
        XCTAssertEqual(HomeLanguage.chinese.nlLanguage, .simplifiedChinese)
        XCTAssertEqual(HomeLanguage.fromNaturalLanguage(.english), .english)
        XCTAssertEqual(HomeLanguage.fromNaturalLanguage(.traditionalChinese), .chinese)
        XCTAssertNil(HomeLanguage.fromNaturalLanguage(NLLanguage(rawValue: "pt")))
    }

    func testRecognizeLanguageReturnsExpectedBestGuessForSupportedLanguages() async throws {
        let samples: [(HomeLanguage, String)] = [
            (
                .english,
                "This application identifies the language of a paragraph and returns a reliable result to the rest of the system."
            ),
            (
                .chinese,
                "这个应用会根据输入的文字内容自动判断语言，并把识别结果稳定地返回给上层功能使用。"
            ),
            (
                .japanese,
                "このアプリは入力された文章の言語を判定し、その結果を上位の機能へ安定して渡します。"
            ),
            (
                .korean,
                "이 앱은 입력된 문장의 언어를 판별하고 그 결과를 상위 기능에 안정적으로 전달합니다."
            ),
            (
                .french,
                "Cette application identifie la langue d'un paragraphe et transmet un résultat fiable au reste du système."
            )
        ]

        for (expectedLanguage, sample) in samples {
            let result = try await service.recognizeLanguage(for: sample)

            XCTAssertEqual(
                result.language,
                expectedLanguage,
                "Expected \(expectedLanguage.rawValue) for sample: \(sample)"
            )
            assertValidResult(result)
        }
    }

    func testRecognizeLanguageRejectsEmptyText() async {
        await assertEmptyTextError(for: "")
        await assertEmptyTextError(for: "  \n\t  ")
    }

    func testRecognizeLanguageReturnsBestGuessForShortText() async throws {
        let result = try await service.recognizeLanguage(for: "你好")

        XCTAssertEqual(result.language, .chinese)
        assertValidResult(result)
    }

    func testRecognizeLanguageReturnsBestGuessForMixedLanguageText() async throws {
        let result = try await service.recognizeLanguage(
            for: "Hello there, this message is mostly in English, 但是最后一句用了中文。"
        )

        XCTAssertTrue([HomeLanguage.english, .chinese].contains(result.language))
        assertValidResult(result)
    }

    private func assertEmptyTextError(for text: String) async {
        do {
            _ = try await service.recognizeLanguage(for: text)
            XCTFail("Expected recognizeLanguage(for:) to throw for empty text.")
        } catch let error as TextLanguageRecognitionError {
            guard case .emptyText = error else {
                XCTFail("Expected emptyText error, got \(error).")
                return
            }
        } catch {
            XCTFail("Expected TextLanguageRecognitionError, got \(error).")
        }
    }

    private func assertValidResult(_ result: TextLanguageRecognitionResult) {
        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1)
        XCTAssertFalse(result.hypotheses.isEmpty)
        XCTAssertNotNil(result.hypotheses[result.language])

        for probability in result.hypotheses.values {
            XCTAssertGreaterThanOrEqual(probability, 0)
            XCTAssertLessThanOrEqual(probability, 1)
        }
    }
}
