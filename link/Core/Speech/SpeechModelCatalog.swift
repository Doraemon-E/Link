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
        packages.first { $0.packageId == packageId }
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
