//
//  TextLanguageRecognitionService.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated struct TextLanguageRecognitionResult: Sendable, Equatable {
    let language: HomeLanguage
    let confidence: Float
    let hypotheses: [HomeLanguage: Float]
}

protocol TextLanguageRecognitionService: Sendable {
    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult
}

nonisolated enum TextLanguageRecognitionError: LocalizedError {
    case emptyText
    case unsupportedLanguage(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot detect the language of empty text."
        case .unsupportedLanguage(let languageCode):
            return "Detected language is not supported: \(languageCode)"
        case .recognitionFailed(let detail):
            return "Language recognition failed: \(detail)"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .emptyText:
            return "请输入要识别语言的文字。"
        case .unsupportedLanguage(let languageCode):
            return userFacingFailureMessage(
                prefix: "暂时无法将这段文字识别为应用支持的语言",
                detail: languageCode,
                fallback: "请换一段更完整的文本后再试。"
            )
        case .recognitionFailed(let detail):
            return userFacingFailureMessage(
                prefix: "文字语言识别失败",
                detail: detail,
                fallback: "请稍后再试。"
            )
        }
    }
}

private extension TextLanguageRecognitionError {
    func userFacingFailureMessage(
        prefix: String,
        detail: String,
        fallback: String
    ) -> String {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDetail.isEmpty else {
            return "\(prefix)，\(fallback)"
        }

        return "\(prefix)：\(normalizedDetail)"
    }
}
