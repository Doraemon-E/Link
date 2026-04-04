//
//  ModelDownloadTypesTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class ModelDownloadTypesTests: XCTestCase {
    func testDownloadProgressDerivesFractionFromBytes() {
        let progress = ModelDownloadProgress(
            phase: .downloading,
            downloadedBytes: 512,
            totalBytes: 1024
        )

        XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: 0.0001)
        XCTAssertFalse(progress.isResumable)
    }

    func testDescriptorBuildsStableItemID() {
        let descriptor = ModelDownloadDescriptor(
            kind: .translation,
            packageId: "opus-mt-en-zh-onnx",
            version: "1.0.0",
            title: "英文 -> 中文",
            subtitle: "翻译模型",
            archiveURL: URL(string: "https://example.com/model.zip")!,
            archiveSize: 1,
            installedSize: 1,
            sha256: "abc"
        )

        XCTAssertEqual(descriptor.id, "translation:opus-mt-en-zh-onnx")
    }

    func testHomeLanguageCanResolveTranslationModelCode() {
        XCTAssertEqual(HomeLanguage.fromTranslationModelCode("eng"), .english)
        XCTAssertEqual(HomeLanguage.fromTranslationModelCode(" zho "), .chinese)
        XCTAssertNil(HomeLanguage.fromTranslationModelCode("unknown"))
    }
}
