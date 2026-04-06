//
//  HomeLanguageSelection.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

enum HomeMessageLanguageSide: String, Equatable, Sendable {
    case source
    case target
}

struct HomeLanguageSheetContext: Identifiable, Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case globalTarget
        case message(messageID: UUID, side: HomeMessageLanguageSide)
    }

    let origin: Origin
    let selectedLanguage: SupportedLanguage

    var id: String {
        switch origin {
        case .globalTarget:
            return "global-target"
        case .message(let messageID, let side):
            return "message-\(messageID.uuidString)-\(side.rawValue)"
        }
    }

    var title: String {
        switch origin {
        case .globalTarget:
            return "选择目标语言"
        case .message(_, .source):
            return "选择原文语言"
        case .message(_, .target):
            return "选择译文语言"
        }
    }
}
