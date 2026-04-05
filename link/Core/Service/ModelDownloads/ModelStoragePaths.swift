//
//  ModelStoragePaths.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum ModelStoragePaths {
    static func applicationSupportDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelStoragePathError.applicationSupportUnavailable
        }

        return applicationSupportURL
    }

    static func baseDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try applicationSupportDirectoryURL().appendingPathComponent(
            kind == .translation ? "TranslationModels" : "SpeechModels",
            isDirectory: true
        )
    }

    static func downloadsDirectoryURL(for kind: ModelAssetKind) throws -> URL {
        try baseDirectoryURL(for: kind).appendingPathComponent("downloads", isDirectory: true)
    }

    static func downloadDirectoryURL(for descriptor: ModelDownloadDescriptor) throws -> URL {
        try downloadsDirectoryURL(for: descriptor.kind).appendingPathComponent(
            descriptor.packageId,
            isDirectory: true
        )
    }

    static func persistedStateURL(for descriptor: ModelDownloadDescriptor) throws -> URL {
        try downloadDirectoryURL(for: descriptor).appendingPathComponent("state.json", isDirectory: false)
    }

    static func partialArchiveURL(for descriptor: ModelDownloadDescriptor) throws -> URL {
        try downloadDirectoryURL(for: descriptor).appendingPathComponent("archive.part", isDirectory: false)
    }
}

nonisolated enum ModelStoragePathError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Unable to locate Application Support directory."
        }
    }
}
