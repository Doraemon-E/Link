//
//  SystemTextLanguageRecognitionService.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation
import NaturalLanguage

actor SystemTextLanguageRecognitionService: TextLanguageRecognitionService {
    private let recognizer = NLLanguageRecognizer()

    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw TextLanguageRecognitionError.emptyText
        }

        recognizer.reset()
        defer { recognizer.reset() }
        recognizer.languageConstraints = Self.supportedConstraintLanguages
        recognizer.processString(normalizedText)

        let rawHypotheses = recognizer.languageHypotheses(withMaximum: Self.supportedConstraintLanguages.count)
        let hypotheses = Self.aggregateHypotheses(from: rawHypotheses)

        if let bestMatch = hypotheses.max(by: { $0.value < $1.value }) {
            return TextLanguageRecognitionResult(
                language: bestMatch.key,
                confidence: bestMatch.value,
                hypotheses: hypotheses
            )
        }

        // NOTE: 降级处理，如果没有任何一个语言的置信度足够高，但 NaturalLanguage 仍然返回了一个 dominantLanguage，我们可以使用它作为备选方案，尽管它可能不在我们的支持列表中。
        if let dominantLanguage = recognizer.dominantLanguage,
           let mappedLanguage = SupportedLanguage.fromNaturalLanguage(dominantLanguage) {
            let fallbackConfidence = Float(rawHypotheses[dominantLanguage] ?? 0)
            return TextLanguageRecognitionResult(
                language: mappedLanguage,
                confidence: fallbackConfidence,
                hypotheses: [mappedLanguage: fallbackConfidence]
            )
        }

        if let dominantLanguage = recognizer.dominantLanguage {
            let languageCode = dominantLanguage.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !languageCode.isEmpty, languageCode != "und" {
                throw TextLanguageRecognitionError.unsupportedLanguage(languageCode)
            }
        }

        throw TextLanguageRecognitionError.recognitionFailed(
            "NaturalLanguage did not produce any supported language hypotheses."
        )
    }

    private static let supportedConstraintLanguages: [NLLanguage] = {
        var languages: [NLLanguage] = []

        func append(_ language: NLLanguage) {
            guard !languages.contains(language) else {
                return
            }

            languages.append(language)
        }

        for language in SupportedLanguage.allCases {
            append(language.nlLanguage)

            // NOTE:包含简体中文，因为有繁体中文，暂时还没有支持
            if language == .chinese {
                append(.traditionalChinese)
            }
        }

        return languages
    }()

    private static func aggregateHypotheses(
        from rawHypotheses: [NLLanguage: Double]
    ) -> [SupportedLanguage: Float] {
        var hypothesesByLanguage: [SupportedLanguage: Float] = [:]

        for (language, probability) in rawHypotheses {
            guard let mappedLanguage = SupportedLanguage.fromNaturalLanguage(language) else {
                continue
            }

            hypothesesByLanguage[mappedLanguage, default: 0] += Float(probability)
        }

        return hypothesesByLanguage
    }
}
