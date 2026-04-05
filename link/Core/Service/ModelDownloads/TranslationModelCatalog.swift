//
//  TranslationModelCatalog.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct TranslationModelCatalog: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Date?
    let packages: [TranslationModelPackage]

    func package(source: HomeLanguage, target: HomeLanguage) -> TranslationModelPackage? {
        packages.first {
            $0.source == source.translationModelCode &&
            $0.target == target.translationModelCode
        }
    }

    func package(packageId: String) -> TranslationModelPackage? {
        packages.first { $0.packageId == packageId }
    }
}

nonisolated struct TranslationModelPackage: Codable, Identifiable, Equatable, Sendable {
    let packageId: String
    let version: String
    let source: String
    let target: String
    let family: TranslationModelManifest.Family
    let archiveURL: URL
    let sha256: String
    let archiveSize: Int64
    let installedSize: Int64
    let manifestRelativePath: String
    let minAppVersion: String

    var id: String { packageId }
}

nonisolated struct TranslationInstalledPackagesIndex: Codable, Sendable {
    var packages: [TranslationInstalledPackageRecord]

    static let empty = TranslationInstalledPackagesIndex(packages: [])
}

nonisolated struct TranslationInstalledPackageRecord: Codable, Equatable, Sendable {
    let packageId: String
    let version: String
    let manifestRelativePath: String
    let installedAt: Date
}
