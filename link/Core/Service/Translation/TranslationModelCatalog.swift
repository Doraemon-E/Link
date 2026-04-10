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

    func package(source: SupportedLanguage, target: SupportedLanguage) -> TranslationModelPackage? {
        guard source != target else {
            return nil
        }

        return packages.first {
            $0.supports(source: source, target: target)
        }
    }

    func package(packageId: String) -> TranslationModelPackage? {
        packages.first { $0.packageId == packageId }
    }
}

nonisolated struct TranslationModelPackage: Codable, Identifiable, Equatable, Sendable {
    let packageId: String
    let version: String
    let family: TranslationModelManifest.Family
    let supportedLanguages: [String]
    let archiveURL: URL
    let sha256: String
    let archiveSize: Int64
    let installedSize: Int64
    let manifestRelativePath: String
    let minAppVersion: String

    var id: String { packageId }

    private enum CodingKeys: String, CodingKey {
        case packageId
        case version
        case source
        case target
        case family
        case supportedLanguages
        case archiveURL
        case sha256
        case archiveSize
        case installedSize
        case manifestRelativePath
        case minAppVersion
    }

    init(
        packageId: String,
        version: String,
        family: TranslationModelManifest.Family,
        supportedLanguages: [String],
        archiveURL: URL,
        sha256: String,
        archiveSize: Int64,
        installedSize: Int64,
        manifestRelativePath: String,
        minAppVersion: String
    ) {
        self.packageId = packageId
        self.version = version
        self.family = family
        self.supportedLanguages = Array(
            Set(
                supportedLanguages.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
            )
        ).sorted()
        self.archiveURL = archiveURL
        self.sha256 = sha256
        self.archiveSize = archiveSize
        self.installedSize = installedSize
        self.manifestRelativePath = manifestRelativePath
        self.minAppVersion = minAppVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supportedLanguages = try container.decodeIfPresent([String].self, forKey: .supportedLanguages)
            ?? [
                try container.decodeIfPresent(String.self, forKey: .source),
                try container.decodeIfPresent(String.self, forKey: .target),
            ].compactMap { $0 }

        self.init(
            packageId: try container.decode(String.self, forKey: .packageId),
            version: try container.decode(String.self, forKey: .version),
            family: try container.decode(TranslationModelManifest.Family.self, forKey: .family),
            supportedLanguages: supportedLanguages,
            archiveURL: try container.decode(URL.self, forKey: .archiveURL),
            sha256: try container.decode(String.self, forKey: .sha256),
            archiveSize: try container.decode(Int64.self, forKey: .archiveSize),
            installedSize: try container.decode(Int64.self, forKey: .installedSize),
            manifestRelativePath: try container.decode(String.self, forKey: .manifestRelativePath),
            minAppVersion: try container.decode(String.self, forKey: .minAppVersion)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageId, forKey: .packageId)
        try container.encode(version, forKey: .version)
        try container.encode(family, forKey: .family)
        try container.encode(supportedLanguages, forKey: .supportedLanguages)
        try container.encode(archiveURL, forKey: .archiveURL)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(archiveSize, forKey: .archiveSize)
        try container.encode(installedSize, forKey: .installedSize)
        try container.encode(manifestRelativePath, forKey: .manifestRelativePath)
        try container.encode(minAppVersion, forKey: .minAppVersion)
    }

    func supports(source: SupportedLanguage, target: SupportedLanguage) -> Bool {
        supportedLanguages.contains(source.translationModelCode) &&
            supportedLanguages.contains(target.translationModelCode)
    }
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

nonisolated struct TranslationInstalledPackageSummary: Equatable, Sendable {
    let packageId: String
    let version: String
    let supportedLanguages: [SupportedLanguage]
    let archiveSize: Int64
    let installedSize: Int64
    let installedAt: Date
}
