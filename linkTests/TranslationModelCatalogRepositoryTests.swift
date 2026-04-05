//
//  TranslationModelCatalogRepositoryTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class TranslationModelCatalogRepositoryTests: XCTestCase {
    func testCatalogPrefersBundledCatalogWhenCachedCatalogIsStale() async throws {
        let baseDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: baseDirectoryURL) }

        let bundledCatalog = TranslationModelCatalog(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_775_267_200),
            packages: [
                makePackage(
                    packageId: "opus-mt-en-jap-onnx",
                    source: "eng",
                    target: "jpn",
                    family: .marian
                )
            ]
        )
        let cachedCatalog = TranslationModelCatalog(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_775_267_200),
            packages: [
                makePackage(
                    packageId: "mt5-small-en-ja-onnx",
                    source: "eng",
                    target: "jpn",
                    family: .mt5
                )
            ]
        )

        let bundledCatalogURL = baseDirectoryURL.appendingPathComponent("bundled-catalog.json", isDirectory: false)
        let cachedCatalogURL = baseDirectoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        try write(catalog: bundledCatalog, to: bundledCatalogURL)
        try write(catalog: cachedCatalog, to: cachedCatalogURL)

        let repository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main,
            bundledCatalogURLOverride: bundledCatalogURL,
            baseDirectoryURLOverride: baseDirectoryURL
        )

        let catalog = try await repository.catalog()
        let package = catalog.package(source: .english, target: .japanese)

        XCTAssertEqual(package?.packageId, "opus-mt-en-jap-onnx")

        let repairedCachedCatalog = try loadCatalog(from: cachedCatalogURL)
        XCTAssertEqual(repairedCachedCatalog, bundledCatalog)
    }

    func testCatalogPrefersCachedCatalogWhenCachedCatalogIsNewer() async throws {
        let baseDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: baseDirectoryURL) }

        let bundledCatalog = TranslationModelCatalog(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_775_267_200),
            packages: [
                makePackage(
                    packageId: "opus-mt-en-jap-onnx",
                    source: "eng",
                    target: "jpn",
                    family: .marian
                )
            ]
        )
        let cachedCatalog = TranslationModelCatalog(
            version: 2,
            generatedAt: Date(timeIntervalSince1970: 1_775_353_600),
            packages: [
                makePackage(
                    packageId: "opus-mt-en-jap-onnx-v2",
                    source: "eng",
                    target: "jpn",
                    family: .marian
                )
            ]
        )

        let bundledCatalogURL = baseDirectoryURL.appendingPathComponent("bundled-catalog.json", isDirectory: false)
        let cachedCatalogURL = baseDirectoryURL.appendingPathComponent("catalog.json", isDirectory: false)
        try write(catalog: bundledCatalog, to: bundledCatalogURL)
        try write(catalog: cachedCatalog, to: cachedCatalogURL)

        let repository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main,
            bundledCatalogURLOverride: bundledCatalogURL,
            baseDirectoryURLOverride: baseDirectoryURL
        )

        let catalog = try await repository.catalog()
        let package = catalog.package(source: .english, target: .japanese)

        XCTAssertEqual(package?.packageId, "opus-mt-en-jap-onnx-v2")
    }

    private func makePackage(
        packageId: String,
        source: String,
        target: String,
        family: TranslationModelManifest.Family
    ) -> TranslationModelPackage {
        TranslationModelPackage(
            packageId: packageId,
            version: "1.0.0",
            source: source,
            target: target,
            family: family,
            archiveURL: URL(string: "https://example.com/\(packageId).zip")!,
            sha256: "",
            archiveSize: 1,
            installedSize: 1,
            manifestRelativePath: "translation-manifest.json",
            minAppVersion: "1.0.0"
        )
    }

    private func write(catalog: TranslationModelCatalog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(to: url, options: .atomic)
    }

    private func loadCatalog(from url: URL) throws -> TranslationModelCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranslationModelCatalog.self, from: Data(contentsOf: url))
    }
}
