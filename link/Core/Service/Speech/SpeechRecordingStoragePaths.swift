//
//  SpeechRecordingStoragePaths.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated enum SpeechRecordingStoragePaths {
    private static let recordingsDirectoryName = "SpeechRecordings"

    static func recordingsDirectoryURL(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let baseURL: URL
        if let applicationSupportURL {
            baseURL = applicationSupportURL
        } else if let resolvedURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            baseURL = resolvedURL
        } else {
            throw SpeechRecordingStoragePathError.applicationSupportUnavailable
        }

        return baseURL.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
    }

    @discardableResult
    static func ensureRecordingsDirectoryExists(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let directoryURL = try recordingsDirectoryURL(
            fileManager: fileManager,
            applicationSupportURL: applicationSupportURL
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    static func recordingFileURL(
        for messageID: UUID,
        pathExtension: String = "caf",
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let directoryURL = try recordingsDirectoryURL(
            fileManager: fileManager,
            applicationSupportURL: applicationSupportURL
        )
        return directoryURL
            .appendingPathComponent(messageID.uuidString, isDirectory: false)
            .appendingPathExtension(pathExtension)
    }
}

nonisolated enum SpeechRecordingStoragePathError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Unable to locate Application Support directory for speech recordings."
        }
    }
}
