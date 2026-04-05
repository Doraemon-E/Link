//
//  HomeLanguage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import NaturalLanguage

nonisolated enum HomeLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case russian
    case spanish
    case italian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "英文"
        case .japanese:
            return "日文"
        case .korean:
            return "韩文"
        case .french:
            return "法文"
        case .german:
            return "德文"
        case .russian:
            return "俄文"
        case .spanish:
            return "西班牙文"
        case .italian:
            return "意大利文"
        }
    }

    var compactDisplayName: String {
        switch self {
        case .chinese:
            return "中"
        case .english:
            return "英"
        case .japanese:
            return "日"
        case .korean:
            return "韩"
        case .french:
            return "法"
        case .german:
            return "德"
        case .russian:
            return "俄"
        case .spanish:
            return "西"
        case .italian:
            return "意"
        }
    }

    var translationModelCode: String {
        switch self {
        case .chinese:
            return "zho"
        case .english:
            return "eng"
        case .japanese:
            return "jpn"
        case .korean:
            return "kor"
        case .french:
            return "fra"
        case .german:
            return "deu"
        case .russian:
            return "rus"
        case .spanish:
            return "spa"
        case .italian:
            return "ita"
        }
    }

    var whisperLanguageCode: String {
        switch self {
        case .chinese:
            return "zh"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .russian:
            return "ru"
        case .spanish:
            return "es"
        case .italian:
            return "it"
        }
    }

    var mt5PromptName: String {
        switch self {
        case .chinese:
            return "Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .russian:
            return "Russian"
        case .spanish:
            return "Spanish"
        case .italian:
            return "Italian"
        }
    }

    var ttsLocaleIdentifier: String {
        switch self {
        case .chinese:
            return "zh-CN"
        case .english:
            return "en-US"
        case .japanese:
            return "ja-JP"
        case .korean:
            return "ko-KR"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .russian:
            return "ru-RU"
        case .spanish:
            return "es-ES"
        case .italian:
            return "it-IT"
        }
    }

    var nlLanguage: NLLanguage {
        switch self {
        case .chinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        case .french:
            return .french
        case .german:
            return .german
        case .russian:
            return .russian
        case .spanish:
            return .spanish
        case .italian:
            return .italian
        }
    }

    static func fromWhisperLanguageCode(_ code: String?) -> HomeLanguage? {
        guard let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedCode.isEmpty else {
            return nil
        }

        return allCases.first { $0.whisperLanguageCode == normalizedCode }
    }

    static func fromTranslationModelCode(_ code: String?) -> HomeLanguage? {
        guard let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedCode.isEmpty else {
            return nil
        }

        return allCases.first { $0.translationModelCode == normalizedCode }
    }

    static func fromNaturalLanguage(_ language: NLLanguage?) -> HomeLanguage? {
        guard let normalizedCode = language?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedCode.isEmpty else {
            return nil
        }

        switch normalizedCode {
        case let code where code == "zh" || code.hasPrefix("zh-"):
            return .chinese
        case let code where code == "en" || code.hasPrefix("en-"):
            return .english
        case let code where code == "ja" || code.hasPrefix("ja-"):
            return .japanese
        case let code where code == "ko" || code.hasPrefix("ko-"):
            return .korean
        case let code where code == "fr" || code.hasPrefix("fr-"):
            return .french
        case let code where code == "de" || code.hasPrefix("de-"):
            return .german
        case let code where code == "ru" || code.hasPrefix("ru-"):
            return .russian
        case let code where code == "es" || code.hasPrefix("es-"):
            return .spanish
        case let code where code == "it" || code.hasPrefix("it-"):
            return .italian
        default:
            return nil
        }
    }
}
