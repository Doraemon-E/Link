//
//  TranslationRoute.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct TranslationRoute: Equatable, Sendable {
    let source: SupportedLanguage
    let target: SupportedLanguage
    let steps: [TranslationRouteStep]
}

nonisolated struct TranslationRouteStep: Identifiable, Equatable, Sendable {
    let source: SupportedLanguage
    let target: SupportedLanguage

    var id: String { "\(source.rawValue)->\(target.rawValue)" }
}
