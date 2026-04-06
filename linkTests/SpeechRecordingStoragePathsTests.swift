//
//  SpeechRecordingStoragePathsTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import XCTest
@testable import link

final class SpeechRecordingStoragePathsTests: XCTestCase {
    func testRecordingFileURLUsesSpeechRecordingsDirectoryAndMessageID() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let messageID = UUID()
        let directoryURL = try SpeechRecordingStoragePaths.ensureRecordingsDirectoryExists(
            applicationSupportURL: rootURL
        )
        let fileURL = try SpeechRecordingStoragePaths.recordingFileURL(
            for: messageID,
            applicationSupportURL: rootURL
        )

        XCTAssertEqual(directoryURL.lastPathComponent, "SpeechRecordings")
        XCTAssertEqual(fileURL.deletingPathExtension().lastPathComponent, messageID.uuidString)
        XCTAssertEqual(fileURL.pathExtension, "caf")
        XCTAssertEqual(fileURL.deletingLastPathComponent(), directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
    }
}
