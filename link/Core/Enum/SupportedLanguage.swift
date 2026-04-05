//
//  SupportedLanguage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import NaturalLanguage

nonisolated enum SupportedLanguage: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case russian
    case spanish
    case italian

    private struct Definition: Sendable {
        let displayName: String
        let compactDisplayName: String
        let translationModelCode: String
        let whisperLanguageCode: String
        let mt5PromptName: String
        let ttsLocaleIdentifier: String
        let nlLanguage: NLLanguage
        let naturalLanguageCodePrefixes: [String]

        func matchesNaturalLanguageCode(_ code: String) -> Bool {
            naturalLanguageCodePrefixes.contains { prefix in
                code == prefix || code.hasPrefix("\(prefix)-")
            }
        }
    }

    var id: String { rawValue }

    var displayName: String { definition.displayName }
    var compactDisplayName: String { definition.compactDisplayName }
    var translationModelCode: String { definition.translationModelCode }
    var whisperLanguageCode: String { definition.whisperLanguageCode }
    var mt5PromptName: String { definition.mt5PromptName }
    var ttsLocaleIdentifier: String { definition.ttsLocaleIdentifier }
    var nlLanguage: NLLanguage { definition.nlLanguage }

    static func fromWhisperLanguageCode(_ code: String?) -> Self? {
        language(forNormalizedCode: normalize(code), by: \.whisperLanguageCode)
    }

    static func fromTranslationModelCode(_ code: String?) -> Self? {
        language(forNormalizedCode: normalize(code), by: \.translationModelCode)
    }

    static func fromNaturalLanguage(_ language: NLLanguage?) -> Self? {
        guard let normalizedCode = normalize(language?.rawValue) else {
            return nil
        }

        return allCases.first { $0.definition.matchesNaturalLanguageCode(normalizedCode) }
    }

    private var definition: Definition {
        guard let definition = Self.definitions[self] else {
            preconditionFailure("Missing definition for supported language: \(rawValue)")
        }

        return definition
    }

    private static func language(
        forNormalizedCode normalizedCode: String?,
        by keyPath: KeyPath<Definition, String>
    ) -> Self? {
        guard let normalizedCode else {
            return nil
        }

        return allCases.first { $0.definition[keyPath: keyPath] == normalizedCode }
    }

    private static func normalize(_ code: String?) -> String? {
        guard let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedCode.isEmpty else {
            return nil
        }

        return normalizedCode
    }

    private static let definitions: [Self: Definition] = [
        .chinese: Definition(
            displayName: "中文",
            compactDisplayName: "中",
            translationModelCode: "zho",
            whisperLanguageCode: "zh",
            mt5PromptName: "Chinese",
            ttsLocaleIdentifier: "zh-CN",
            nlLanguage: .simplifiedChinese,
            naturalLanguageCodePrefixes: ["zh"]
        ),
        .english: Definition(
            displayName: "英文",
            compactDisplayName: "英",
            translationModelCode: "eng",
            whisperLanguageCode: "en",
            mt5PromptName: "English",
            ttsLocaleIdentifier: "en-US",
            nlLanguage: .english,
            naturalLanguageCodePrefixes: ["en"]
        ),
        .japanese: Definition(
            displayName: "日文",
            compactDisplayName: "日",
            translationModelCode: "jpn",
            whisperLanguageCode: "ja",
            mt5PromptName: "Japanese",
            ttsLocaleIdentifier: "ja-JP",
            nlLanguage: .japanese,
            naturalLanguageCodePrefixes: ["ja"]
        ),
        .korean: Definition(
            displayName: "韩文",
            compactDisplayName: "韩",
            translationModelCode: "kor",
            whisperLanguageCode: "ko",
            mt5PromptName: "Korean",
            ttsLocaleIdentifier: "ko-KR",
            nlLanguage: .korean,
            naturalLanguageCodePrefixes: ["ko"]
        ),
        .french: Definition(
            displayName: "法文",
            compactDisplayName: "法",
            translationModelCode: "fra",
            whisperLanguageCode: "fr",
            mt5PromptName: "French",
            ttsLocaleIdentifier: "fr-FR",
            nlLanguage: .french,
            naturalLanguageCodePrefixes: ["fr"]
        ),
        .german: Definition(
            displayName: "德文",
            compactDisplayName: "德",
            translationModelCode: "deu",
            whisperLanguageCode: "de",
            mt5PromptName: "German",
            ttsLocaleIdentifier: "de-DE",
            nlLanguage: .german,
            naturalLanguageCodePrefixes: ["de"]
        ),
        .russian: Definition(
            displayName: "俄文",
            compactDisplayName: "俄",
            translationModelCode: "rus",
            whisperLanguageCode: "ru",
            mt5PromptName: "Russian",
            ttsLocaleIdentifier: "ru-RU",
            nlLanguage: .russian,
            naturalLanguageCodePrefixes: ["ru"]
        ),
        .spanish: Definition(
            displayName: "西班牙文",
            compactDisplayName: "西",
            translationModelCode: "spa",
            whisperLanguageCode: "es",
            mt5PromptName: "Spanish",
            ttsLocaleIdentifier: "es-ES",
            nlLanguage: .spanish,
            naturalLanguageCodePrefixes: ["es"]
        ),
        .italian: Definition(
            displayName: "意大利文",
            compactDisplayName: "意",
            translationModelCode: "ita",
            whisperLanguageCode: "it",
            mt5PromptName: "Italian",
            ttsLocaleIdentifier: "it-IT",
            nlLanguage: .italian,
            naturalLanguageCodePrefixes: ["it"]
        )
    ]
}
