//
//  TranslationRoute.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct TranslationRoute: Equatable, Sendable {
    let source: HomeLanguage
    let target: HomeLanguage
    let steps: [TranslationRouteStep]
}

nonisolated struct TranslationRouteStep: Identifiable, Equatable, Sendable {
    let source: HomeLanguage
    let target: HomeLanguage

    var id: String { "\(source.rawValue)->\(target.rawValue)" }
}
