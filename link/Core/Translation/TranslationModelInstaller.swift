//
//  TranslationModelInstaller.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import CryptoKit
import Foundation
import ZIPFoundation

struct TranslationModelInstallation {
    let package: TranslationModelPackage
    let manifest: TranslationModelManifest
    let modelDirectoryURL: URL
}

actor TranslationModelInstaller {
    private let catalogService: TranslationModelCatalogService

    init(
        catalogService: TranslationModelCatalogService
    ) {
        self.catalogService = catalogService
    }

    func warmUpCatalog() async {
        await catalogService.warmUpCatalog()
    }

    func packageMetadata(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationModelPackage? {
        guard source != target else {
            return nil
        }

        return try await catalogService.package(source: source, target: target)
    }

    func isInstalled(source: HomeLanguage, target: HomeLanguage) async throws -> Bool {
        guard source != target else {
            return true
        }

        return try await installedPackage(for: source, target: target) != nil
    }

    func ensureInstalled(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationModelInstallation {
        if source == target {
            throw TranslationError.modelPackageUnavailable(source: source, target: target)
        }

        if let installation = try await installedPackage(for: source, target: target) {
            return installation
        }

        guard let package = try await catalogService.package(source: source, target: target) else {
            throw TranslationError.modelPackageUnavailable(source: source, target: target)
        }

        return try await install(packageId: package.packageId)
    }

    func installedPackage(for source: HomeLanguage, target: HomeLanguage) async throws -> TranslationModelInstallation? {
        guard let package = try await catalogService.package(source: source, target: target) else {
            return nil
        }

        return try validInstalledPackage(for: package)
    }

    func install(packageId: String) async throws -> TranslationModelInstallation {
        guard let package = try await catalogService.package(packageId: packageId) else {
            throw TranslationError.packageMissing(packageId: packageId)
        }

        if let installation = try validInstalledPackage(for: package) {
            return installation
        }

        try removeStaleInstallationIfNeeded(packageId: package.packageId)

        try ensureDirectoryExists(at: try packagesDirectoryURL())
        try ensureDirectoryExists(at: try temporaryDirectoryURL())

        let workingDirectoryURL = try makeWorkingDirectory()
        defer {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
        }

        let archiveURL = try await downloadArchive(for: package, into: workingDirectoryURL)
        try verifyChecksumIfNeeded(for: package, archiveURL: archiveURL)

        let extractedDirectoryURL = workingDirectoryURL.appendingPathComponent("extracted", isDirectory: true)
        try ensureDirectoryExists(at: extractedDirectoryURL)

        do {
            try FileManager.default.unzipItem(at: archiveURL, to: extractedDirectoryURL)
        } catch {
            throw TranslationError.extractionFailed(error.localizedDescription)
        }

        let payloadRootURL = try resolvePayloadRoot(
            extractedDirectoryURL: extractedDirectoryURL,
            manifestRelativePath: package.manifestRelativePath
        )

        let manifestURL = payloadRootURL.appendingPathComponent(package.manifestRelativePath, isDirectory: false)
        let manifest = try loadManifest(at: manifestURL)
        let modelDirectoryURL = manifestURL.deletingLastPathComponent()

        try validate(package: package, manifest: manifest, modelDirectoryURL: modelDirectoryURL)

        let destinationURL = try packageDirectoryURL(for: package.packageId)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.moveItem(at: payloadRootURL, to: destinationURL)
        } catch {
            throw TranslationError.installationFailed("Failed to store package \(package.packageId): \(error.localizedDescription)")
        }

        try upsertInstalledRecord(
            TranslationInstalledPackageRecord(
                packageId: package.packageId,
                version: package.version,
                manifestRelativePath: package.manifestRelativePath,
                installedAt: .now
            )
        )

        return TranslationModelInstallation(
            package: package,
            manifest: manifest,
            modelDirectoryURL: destinationURL
                .appendingPathComponent(package.manifestRelativePath, isDirectory: false)
                .deletingLastPathComponent()
        )
    }

    func remove(packageId: String) async throws {
        let packageURL = try packageDirectoryURL(for: packageId)
        if FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.removeItem(at: packageURL)
        }

        var index = try loadInstalledIndex()
        index.packages.removeAll { $0.packageId == packageId }
        try saveInstalledIndex(index)
    }

    private func installedPackage(for package: TranslationModelPackage) throws -> TranslationModelInstallation? {
        let index = try loadInstalledIndex()

        guard let record = index.packages.first(where: { $0.packageId == package.packageId }) else {
            return nil
        }

        let packageDirectoryURL = try packageDirectoryURL(for: record.packageId)
        let manifestURL = packageDirectoryURL.appendingPathComponent(record.manifestRelativePath, isDirectory: false)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest = try loadManifest(at: manifestURL)
        let modelDirectoryURL = manifestURL.deletingLastPathComponent()
        try validate(package: package, manifest: manifest, modelDirectoryURL: modelDirectoryURL)

        return TranslationModelInstallation(
            package: package,
            manifest: manifest,
            modelDirectoryURL: modelDirectoryURL
        )
    }

    private func validInstalledPackage(for package: TranslationModelPackage) throws -> TranslationModelInstallation? {
        do {
            return try installedPackage(for: package)
        } catch {
            try? removeStaleInstallationIfNeeded(packageId: package.packageId)
            return nil
        }
    }

    private func validate(
        package: TranslationModelPackage,
        manifest: TranslationModelManifest,
        modelDirectoryURL: URL
    ) throws {
        guard manifest.family == package.family else {
            throw TranslationError.manifestInvalid("Catalog family does not match package manifest.")
        }

        guard manifest.supportedLanguagePairs.contains(where: {
            $0.source == package.source && $0.target == package.target
        }) else {
            throw TranslationError.manifestInvalid("Manifest does not declare the expected language pair.")
        }

        for fileName in manifest.requiredFileNames {
            let fileURL = modelDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw TranslationError.installationFailed("Installed package is missing \(fileName).")
            }
        }
    }

    private func downloadArchive(
        for package: TranslationModelPackage,
        into workingDirectoryURL: URL
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration)
        let (temporaryFileURL, response) = try await session.download(from: package.archiveURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode else {
            throw TranslationError.downloadFailed("The server did not return a successful response.")
        }

        let archiveURL = workingDirectoryURL.appendingPathComponent("\(package.packageId).zip", isDirectory: false)

        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: archiveURL)
        } catch {
            throw TranslationError.downloadFailed(error.localizedDescription)
        }

        return archiveURL
    }

    private func verifyChecksumIfNeeded(
        for package: TranslationModelPackage,
        archiveURL: URL
    ) throws {
        let expectedHash = package.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expectedHash.isEmpty else {
            return
        }

        let actualHash = try sha256(for: archiveURL)
        guard actualHash == expectedHash else {
            throw TranslationError.integrityCheckFailed
        }
    }

    private func sha256(for fileURL: URL) throws -> String {
        guard let inputStream = InputStream(url: fileURL) else {
            throw TranslationError.integrityCheckFailed
        }

        inputStream.open()
        defer { inputStream.close() }

        var hasher = SHA256()
        let bufferSize = 1_048_576
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while inputStream.hasBytesAvailable {
            let readCount = inputStream.read(buffer, maxLength: bufferSize)

            if readCount < 0 {
                throw TranslationError.integrityCheckFailed
            }

            if readCount == 0 {
                break
            }

            hasher.update(data: Data(bytes: buffer, count: readCount))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resolvePayloadRoot(
        extractedDirectoryURL: URL,
        manifestRelativePath: String
    ) throws -> URL {
        let directManifestURL = extractedDirectoryURL.appendingPathComponent(manifestRelativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: directManifestURL.path) {
            return extractedDirectoryURL
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: extractedDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        guard children.count == 1 else {
            throw TranslationError.extractionFailed("Unable to resolve the extracted package root.")
        }

        let candidateRootURL = children[0]
        let candidateManifestURL = candidateRootURL.appendingPathComponent(manifestRelativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidateManifestURL.path) else {
            throw TranslationError.extractionFailed("The package manifest was not found after extraction.")
        }

        return candidateRootURL
    }

    private func loadManifest(at manifestURL: URL) throws -> TranslationModelManifest {
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(TranslationModelManifest.self, from: data)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.manifestInvalid(error.localizedDescription)
        }
    }

    private func loadInstalledIndex() throws -> TranslationInstalledPackagesIndex {
        let installedIndexURL = try installedIndexURL()

        guard FileManager.default.fileExists(atPath: installedIndexURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: installedIndexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranslationInstalledPackagesIndex.self, from: data)
        } catch {
            throw TranslationError.installationFailed("Failed to read the installed model index.")
        }
    }

    private func upsertInstalledRecord(_ record: TranslationInstalledPackageRecord) throws {
        var index = try loadInstalledIndex()
        index.packages.removeAll { $0.packageId == record.packageId }
        index.packages.append(record)
        try saveInstalledIndex(index)
    }

    private func saveInstalledIndex(_ index: TranslationInstalledPackagesIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(index)
            try ensureBaseDirectoryExists()
            try data.write(to: try installedIndexURL(), options: .atomic)
        } catch {
            throw TranslationError.installationFailed("Failed to write the installed model index.")
        }
    }

    private func installedIndexURL() throws -> URL {
        try baseDirectoryURL().appendingPathComponent("installed.json", isDirectory: false)
    }

    private func packagesDirectoryURL() throws -> URL {
        try baseDirectoryURL().appendingPathComponent("packages", isDirectory: true)
    }

    private func packageDirectoryURL(for packageId: String) throws -> URL {
        try packagesDirectoryURL().appendingPathComponent(packageId, isDirectory: true)
    }

    private func removeStaleInstallationIfNeeded(packageId: String) throws {
        let packageURL = try packageDirectoryURL(for: packageId)
        if FileManager.default.fileExists(atPath: packageURL.path) {
            try? FileManager.default.removeItem(at: packageURL)
        }

        var index = try loadInstalledIndex()
        let originalCount = index.packages.count
        index.packages.removeAll { $0.packageId == packageId }

        if index.packages.count != originalCount {
            try saveInstalledIndex(index)
        }
    }

    private func temporaryDirectoryURL() throws -> URL {
        try baseDirectoryURL().appendingPathComponent("tmp", isDirectory: true)
    }

    private func baseDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw TranslationError.installationFailed("Unable to locate Application Support directory.")
        }

        return applicationSupportURL.appendingPathComponent("TranslationModels", isDirectory: true)
    }

    private func makeWorkingDirectory() throws -> URL {
        let workingDirectoryURL = try temporaryDirectoryURL()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ensureDirectoryExists(at: workingDirectoryURL)
        return workingDirectoryURL
    }

    private func ensureBaseDirectoryExists() throws {
        try ensureDirectoryExists(at: try baseDirectoryURL())
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}
