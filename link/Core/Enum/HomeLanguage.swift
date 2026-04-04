//
//  HomeLanguage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum HomeLanguage: String, CaseIterable, Identifiable, Sendable {
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

    static func fromWhisperLanguageCode(_ code: String?) -> HomeLanguage? {
        guard let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedCode.isEmpty else {
            return nil
        }

        return allCases.first { $0.whisperLanguageCode == normalizedCode }
    }
}
