//
//  ModelAssetTypesTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class ModelAssetTypesTests: XCTestCase {
    func testTransferStatusDerivesFractionFromBytes() throws {
        let progress = ModelAssetTransferStatus(
            state: .downloading,
            downloadedBytes: 512,
            totalBytes: 1024,
            bytesPerSecond: 256
        )
        let bytesPerSecond = try XCTUnwrap(progress.bytesPerSecond)
        let estimatedRemainingTime = try XCTUnwrap(progress.estimatedRemainingTime)

        XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bytesPerSecond, 256, accuracy: 0.0001)
        XCTAssertEqual(estimatedRemainingTime, 2, accuracy: 0.0001)
        XCTAssertFalse(progress.isResumable)
    }

    func testTransferStatusClearsInvalidTransferSpeed() {
        let progress = ModelAssetTransferStatus(
            state: .downloading,
            downloadedBytes: 512,
            totalBytes: 1024,
            bytesPerSecond: 0
        )

        XCTAssertNil(progress.bytesPerSecond)
        XCTAssertNil(progress.estimatedRemainingTime)
    }

    func testAssetBuildsStableItemID() {
        let descriptor = ModelAsset(
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

    func testSupportedLanguageCanResolveTranslationModelCode() {
        XCTAssertEqual(SupportedLanguage.fromTranslationModelCode("eng"), .english)
        XCTAssertEqual(SupportedLanguage.fromTranslationModelCode(" zho "), .chinese)
        XCTAssertNil(SupportedLanguage.fromTranslationModelCode("unknown"))
    }
}
