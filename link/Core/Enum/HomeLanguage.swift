//
//  HomeLanguage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum HomeLanguage: String, CaseIterable, Identifiable {
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
}
