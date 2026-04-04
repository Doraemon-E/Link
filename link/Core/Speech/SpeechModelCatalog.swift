//
//  SpeechModelCatalog.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct SpeechModelCatalog: Codable {
    let version: Int
    let generatedAt: Date?
    let packages: [SpeechModelPackage]

    func package(packageId: String) -> SpeechModelPackage? {
        let normalizedPackageId = SpeechModelPackage.normalizePackageId(packageId)
        return packages.first { $0.packageId == normalizedPackageId }
    }

    var defaultPackage: SpeechModelPackage? {
        packages.first
    }
}

struct SpeechModelPackage: Codable, Identifiable, Equatable, Sendable {
    enum Family: String, Codable, Sendable {
        case whisper
    }

    let packageId: String
    let version: String
    let family: Family
    let archiveURL: URL
    let sha256: String
    let archiveSize: Int64
    let installedSize: Int64
    let modelRelativePath: String
    let minAppVersion: String

    var id: String { packageId }

    static func normalizePackageId(_ packageId: String) -> String {
        guard packageId.lowercased().hasSuffix(".zip") else {
            return packageId
        }

        return String(packageId.dropLast(4))
    }

    init(
        packageId: String,
        version: String,
        family: Family,
        archiveURL: URL,
        sha256: String,
        archiveSize: Int64,
        installedSize: Int64,
        modelRelativePath: String,
        minAppVersion: String
    ) {
        self.packageId = Self.normalizePackageId(packageId)
        self.version = version
        self.family = family
        self.archiveURL = archiveURL
        self.sha256 = sha256
        self.archiveSize = archiveSize
        self.installedSize = installedSize
        self.modelRelativePath = modelRelativePath
        self.minAppVersion = minAppVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            packageId: try container.decode(String.self, forKey: .packageId),
            version: try container.decode(String.self, forKey: .version),
            family: try container.decode(Family.self, forKey: .family),
            archiveURL: try container.decode(URL.self, forKey: .archiveURL),
            sha256: try container.decode(String.self, forKey: .sha256),
            archiveSize: try container.decode(Int64.self, forKey: .archiveSize),
            installedSize: try container.decode(Int64.self, forKey: .installedSize),
            modelRelativePath: try container.decode(String.self, forKey: .modelRelativePath),
            minAppVersion: try container.decode(String.self, forKey: .minAppVersion)
        )
    }
}

struct SpeechInstalledPackagesIndex: Codable {
    var packages: [SpeechInstalledPackageRecord]

    static let empty = SpeechInstalledPackagesIndex(packages: [])
}

struct SpeechInstalledPackageRecord: Codable, Equatable {
    let packageId: String
    let version: String
    let modelRelativePath: String
    let installedAt: Date
}

struct SpeechModelInstallation: Sendable {
    let package: SpeechModelPackage
    let modelURL: URL
}
