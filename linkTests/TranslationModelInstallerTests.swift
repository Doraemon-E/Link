//
//  TranslationModelInstallerTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/5.
//

import Foundation
import XCTest
@testable import link

final class TranslationModelInstallerTests: XCTestCase {
    func testDownloadRequirementIncludesAllMissingPackagesForRoute() async throws {
        let package = makePackage(
            packageId: "opus-mt-zh-en-onnx",
            source: .chinese,
            target: .english,
            archiveSize: 12,
            installedSize: 34
        )
        let harness = try makeHarness(packages: [package])

        let requirement = try await harness.installer.downloadRequirement(
            for: TranslationRoute(
                source: .chinese,
                target: .english,
                steps: [TranslationRouteStep(source: .chinese, target: .english)]
            )
        )

        XCTAssertFalse(requirement.isReady)
        XCTAssertEqual(requirement.packageIds, [package.packageId])
        XCTAssertEqual(requirement.archiveSize, 12)
        XCTAssertEqual(requirement.installedSize, 34)
    }

    func testDownloadRequirementExcludesInstalledPackagesForMultiHopRoute() async throws {
        let firstPackage = makePackage(
            packageId: "opus-mt-zh-en-onnx",
            source: .chinese,
            target: .english,
            archiveSize: 12,
            installedSize: 34
        )
        let secondPackage = makePackage(
            packageId: "opus-mt-en-fr-onnx",
            source: .english,
            target: .french,
            archiveSize: 56,
            installedSize: 78
        )
        let harness = try makeHarness(
            packages: [firstPackage, secondPackage],
            installedPackageIDs: [firstPackage.packageId]
        )

        let requirement = try await harness.installer.downloadRequirement(
            for: TranslationRoute(
                source: .chinese,
                target: .french,
                steps: [
                    TranslationRouteStep(source: .chinese, target: .english),
                    TranslationRouteStep(source: .english, target: .french)
                ]
            )
        )

        XCTAssertEqual(requirement.packageIds, [secondPackage.packageId])
        XCTAssertEqual(requirement.archiveSize, 56)
        XCTAssertEqual(requirement.installedSize, 78)
    }

    func testDownloadRequirementIsReadyWhenAllRoutePackagesAreInstalled() async throws {
        let firstPackage = makePackage(
            packageId: "opus-mt-zh-en-onnx",
            source: .chinese,
            target: .english,
            archiveSize: 12,
            installedSize: 34
        )
        let secondPackage = makePackage(
            packageId: "opus-mt-en-fr-onnx",
            source: .english,
            target: .french,
            archiveSize: 56,
            installedSize: 78
        )
        let harness = try makeHarness(
            packages: [firstPackage, secondPackage],
            installedPackageIDs: [firstPackage.packageId, secondPackage.packageId]
        )

        let requirement = try await harness.installer.downloadRequirement(
            for: TranslationRoute(
                source: .chinese,
                target: .french,
                steps: [
                    TranslationRouteStep(source: .chinese, target: .english),
                    TranslationRouteStep(source: .english, target: .french)
                ]
            )
        )

        XCTAssertTrue(requirement.isReady)
        XCTAssertTrue(requirement.packageIds.isEmpty)
    }

    private func makeHarness(
        packages: [TranslationModelPackage],
        installedPackageIDs: [String] = []
    ) throws -> TranslationInstallerHarness {
        let baseDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: true
        )

        let bundledCatalogURL = baseDirectoryURL.appendingPathComponent(
            "bundled-catalog.json",
            isDirectory: false
        )
        try writeCatalog(
            TranslationModelCatalog(
                version: 1,
                generatedAt: Date(timeIntervalSince1970: 1_775_267_200),
                packages: packages
            ),
            to: bundledCatalogURL
        )

        let catalogService = TranslationModelCatalogService(
            remoteCatalogURL: nil,
            bundle: .main,
            bundledCatalogURLOverride: bundledCatalogURL,
            baseDirectoryURLOverride: baseDirectoryURL
        )
        let installer = TranslationModelInstaller(
            catalogService: catalogService,
            baseDirectoryURLOverride: baseDirectoryURL
        )

        for packageID in installedPackageIDs {
            guard let package = packages.first(where: { $0.packageId == packageID }) else {
                continue
            }
            try installFakePackage(package, into: baseDirectoryURL)
        }

        return TranslationInstallerHarness(
            baseDirectoryURL: baseDirectoryURL,
            installer: installer
        )
    }

    private func installFakePackage(
        _ package: TranslationModelPackage,
        into baseDirectoryURL: URL
    ) throws {
        let packagesDirectoryURL = baseDirectoryURL.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packagesDirectoryURL,
            withIntermediateDirectories: true
        )

        let packageDirectoryURL = packagesDirectoryURL.appendingPathComponent(
            package.packageId,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageDirectoryURL,
            withIntermediateDirectories: true
        )

        let manifest = makeManifest(for: package)
        let manifestURL = packageDirectoryURL.appendingPathComponent(
            package.manifestRelativePath,
            isDirectory: false
        )
        try writeManifest(manifest, to: manifestURL)

        for fileName in manifest.requiredFileNames {
            let fileURL = packageDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            try Data("stub".utf8).write(to: fileURL, options: .atomic)
        }

        let installedIndexURL = baseDirectoryURL.appendingPathComponent("installed.json", isDirectory: false)
        let existingIndex = (try? loadInstalledIndex(from: installedIndexURL)) ?? .empty
        let updatedIndex = TranslationInstalledPackagesIndex(
            packages: existingIndex.packages + [
                TranslationInstalledPackageRecord(
                    packageId: package.packageId,
                    version: package.version,
                    manifestRelativePath: package.manifestRelativePath,
                    installedAt: .now
                )
            ]
        )
        try writeInstalledIndex(updatedIndex, to: installedIndexURL)
    }

    private func makePackage(
        packageId: String,
        source: HomeLanguage,
        target: HomeLanguage,
        archiveSize: Int64,
        installedSize: Int64
    ) -> TranslationModelPackage {
        TranslationModelPackage(
            packageId: packageId,
            version: "1.0.0",
            source: source.translationModelCode,
            target: target.translationModelCode,
            family: .marian,
            archiveURL: URL(string: "https://example.com/\(packageId).zip")!,
            sha256: "",
            archiveSize: archiveSize,
            installedSize: installedSize,
            manifestRelativePath: "translation-manifest.json",
            minAppVersion: "1.0.0"
        )
    }

    private func makeManifest(for package: TranslationModelPackage) -> TranslationModelManifest {
        TranslationModelManifest(
            family: package.family,
            tokenizer: TranslationModelManifest.Tokenizer(
                kind: .sentencePiece,
                vocabularyFile: nil,
                sourceSentencePieceFile: nil,
                targetSentencePieceFile: nil,
                sentencePieceFile: "tokenizer.model",
                extraIds: nil
            ),
            onnxFiles: TranslationModelManifest.ONNXFiles(
                encoder: "encoder.onnx",
                decoder: "decoder.onnx",
                decoderWithPast: nil
            ),
            generation: TranslationModelManifest.Generation(
                maxInputLength: 256,
                maxOutputLength: 256,
                bosTokenId: 0,
                eosTokenId: 1,
                padTokenId: 1,
                decoderStartTokenId: 0,
                suppressedTokenIds: nil
            ),
            tensorNames: TranslationModelManifest.TensorNames(
                encoderInputIDs: "input_ids",
                encoderAttentionMask: "attention_mask",
                encoderOutput: "last_hidden_state",
                decoderInputIDs: "input_ids",
                decoderEncoderAttentionMask: "encoder_attention_mask",
                decoderEncoderHiddenStates: "encoder_hidden_states",
                decoderOutputLogits: "logits"
            ),
            supportedLanguagePairs: [
                TranslationModelManifest.LanguagePair(
                    source: package.source,
                    target: package.target
                )
            ]
        )
    }

    private func writeCatalog(_ catalog: TranslationModelCatalog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(to: url, options: .atomic)
    }

    private func writeManifest(_ manifest: TranslationModelManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func loadInstalledIndex(
        from url: URL
    ) throws -> TranslationInstalledPackagesIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TranslationInstalledPackagesIndex.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeInstalledIndex(
        _ index: TranslationInstalledPackagesIndex,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: url, options: .atomic)
    }
}

private final class TranslationInstallerHarness {
    let baseDirectoryURL: URL
    let installer: TranslationModelInstaller

    init(baseDirectoryURL: URL, installer: TranslationModelInstaller) {
        self.baseDirectoryURL = baseDirectoryURL
        self.installer = installer
    }

    deinit {
        try? FileManager.default.removeItem(at: baseDirectoryURL)
    }
}
