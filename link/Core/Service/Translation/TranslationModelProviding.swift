//
//  TranslationModelProviding.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated struct TranslationAssetRequirement: Equatable, Sendable {
    let missingPackages: [TranslationModelPackage]

    var packageIds: [String] {
        missingPackages.map(\.packageId)
    }

    var archiveSize: Int64 {
        missingPackages.reduce(0) { $0 + $1.archiveSize }
    }

    var installedSize: Int64 {
        missingPackages.reduce(0) { $0 + $1.installedSize }
    }

    var isReady: Bool {
        missingPackages.isEmpty
    }

    static let ready = TranslationAssetRequirement(missingPackages: [])
}

nonisolated protocol TranslationModelProviding: Sendable {
    func packageMetadata(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> TranslationModelPackage?

    func installedPackage(
        for source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> TranslationModelInstallation?
}

nonisolated protocol TranslationAssetReadinessProviding: Sendable {
    func translationAssetRequirement(
        for route: TranslationRoute
    ) async throws -> TranslationAssetRequirement

    func areTranslationAssetsReady(
        for route: TranslationRoute
    ) async throws -> Bool
}
