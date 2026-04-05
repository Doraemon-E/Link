//
//  ModelAssetStoragePaths.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum ModelAssetStoragePaths {
    static func applicationSupportDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelAssetStoragePathError.applicationSupportUnavailable
        }

        return applicationSupportURL
    }

    static func baseDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try applicationSupportDirectoryURL()
            .appendingPathComponent(kind.baseDirectoryName, isDirectory: true)
    }

    static func downloadsDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent("downloads", isDirectory: true)
    }

    static func transferDirectoryURL(for asset: ModelAsset) throws -> URL {
        try downloadsDirectoryURL(for: asset.kind).appendingPathComponent(
            asset.packageId,
            isDirectory: true
        )
    }

    static func persistedTransferStateURL(for asset: ModelAsset) throws -> URL {
        try transferDirectoryURL(for: asset).appendingPathComponent("state.json", isDirectory: false)
    }

    static func partialArchiveURL(for asset: ModelAsset) throws -> URL {
        try transferDirectoryURL(for: asset).appendingPathComponent("archive.part", isDirectory: false)
    }

    static func packagesDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent("packages", isDirectory: true)
    }

    static func packageDirectoryURL(for kind: ModelAssetKind, packageId: String) throws -> URL {
        try packagesDirectoryURL(for: kind).appendingPathComponent(packageId, isDirectory: true)
    }

    static func installedIndexURL(for kind: ModelAssetKind) throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent("installed.json", isDirectory: false)
    }

    static func temporaryDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent("tmp", isDirectory: true)
    }

    static func catalogCacheURL(for kind: ModelAssetKind, fileName: String = "catalog.json") throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent(fileName, isDirectory: false)
    }
}

private extension ModelAssetKind {
    var baseDirectoryName: String {
        switch self {
        case .translation:
            return "TranslationModels"
        case .speech:
            return "SpeechModels"
        }
    }
}

nonisolated enum ModelAssetStoragePathError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Unable to locate Application Support directory."
        }
    }
}
