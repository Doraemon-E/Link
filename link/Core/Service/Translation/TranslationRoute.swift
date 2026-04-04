//
//  TranslationRoute.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct TranslationRoute: Equatable, Sendable {
    let source: HomeLanguage
    let target: HomeLanguage
    let steps: [TranslationRouteStep]

    var requiresModelDownload: Bool {
        !missingSteps.isEmpty
    }

    var missingSteps: [TranslationRouteStep] {
        steps.filter { !$0.isInstalled }
    }
}

struct TranslationRouteStep: Identifiable, Equatable, Sendable {
    let source: HomeLanguage
    let target: HomeLanguage
    let packageId: String
    let archiveSize: Int64
    let installedSize: Int64
    let isInstalled: Bool

    var id: String { packageId }
}
