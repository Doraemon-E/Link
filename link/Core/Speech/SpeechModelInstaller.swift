//
//  SpeechModelInstaller.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import CryptoKit
import Foundation
import ZIPFoundation

actor SpeechModelInstaller {
    private let catalogService: SpeechModelCatalogService

    init(catalogService: SpeechModelCatalogService) {
        self.catalogService = catalogService
    }

    func warmUpCatalog() async {
        await catalogService.warmUpCatalog()
    }

    func defaultPackageMetadata() async throws -> SpeechModelPackage? {
        try await catalogService.defaultPackage()
    }

    func isDefaultPackageInstalled() async throws -> Bool {
        guard let package = try await catalogService.defaultPackage() else {
            return false
        }

        return try validInstalledPackage(for: package) != nil
    }

    func installedDefaultPackage() async throws -> SpeechModelInstallation? {
        guard let package = try await catalogService.defaultPackage() else {
            return nil
        }

        return try validInstalledPackage(for: package)
    }

    func install(packageId: String) async throws -> SpeechModelInstallation {
        guard let package = try await catalogService.package(packageId: packageId) else {
            log("Missing package metadata for packageId=\(packageId)")
            throw SpeechRecognitionError.packageMissing(packageId)
        }

        if let installation = try validInstalledPackage(for: package) {
            log("Using cached installation for packageId=\(package.packageId)")
            return installation
        }

        do {
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
                throw SpeechRecognitionError.extractionFailed(error.localizedDescription)
            }

            let payloadRootURL = try resolvePayloadRoot(
                extractedDirectoryURL: extractedDirectoryURL,
                modelRelativePath: package.modelRelativePath
            )
            let destinationURL = try packageDirectoryURL(for: package.packageId)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            do {
                try FileManager.default.moveItem(at: payloadRootURL, to: destinationURL)
            } catch {
                throw SpeechRecognitionError.installationFailed(error.localizedDescription)
            }

            let installation = try installedPackage(for: package)
            guard let installation else {
                throw SpeechRecognitionError.installationFailed("Installed speech model is missing the expected model file.")
            }

            try upsertInstalledRecord(
                SpeechInstalledPackageRecord(
                    packageId: package.packageId,
                    version: package.version,
                    modelRelativePath: package.modelRelativePath,
                    installedAt: .now
                )
            )

            log("Install completed for packageId=\(package.packageId)")
            return installation
        } catch {
            log("Install failed for packageId=\(package.packageId): \(error.localizedDescription)")
            throw error
        }
    }

    private func installedPackage(for package: SpeechModelPackage) throws -> SpeechModelInstallation? {
        let index = try loadInstalledIndex()

        guard let record = index.packages.first(where: { $0.packageId == package.packageId }) else {
            return nil
        }

        let packageDirectoryURL = try packageDirectoryURL(for: package.packageId)
        let modelURL = packageDirectoryURL.appendingPathComponent(record.modelRelativePath, isDirectory: false)

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return nil
        }

        return SpeechModelInstallation(package: package, modelURL: modelURL)
    }

    private func validInstalledPackage(for package: SpeechModelPackage) throws -> SpeechModelInstallation? {
        do {
            return try installedPackage(for: package)
        } catch {
            log("Cached installation invalid for packageId=\(package.packageId): \(error.localizedDescription)")
            try? removeStaleInstallationIfNeeded(packageId: package.packageId)
            return nil
        }
    }

    private func downloadArchive(
        for package: SpeechModelPackage,
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
            throw SpeechRecognitionError.downloadFailed("The server did not return a successful response.")
        }

        let archiveURL = workingDirectoryURL.appendingPathComponent("\(package.packageId).zip", isDirectory: false)

        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: archiveURL)
        } catch {
            throw SpeechRecognitionError.downloadFailed(error.localizedDescription)
        }

        return archiveURL
    }

    private func verifyChecksumIfNeeded(
        for package: SpeechModelPackage,
        archiveURL: URL
    ) throws {
        let expectedHash = package.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expectedHash.isEmpty else {
            return
        }

        let actualHash = try sha256(for: archiveURL)
        guard actualHash == expectedHash else {
            throw SpeechRecognitionError.integrityCheckFailed
        }
    }

    private func sha256(for fileURL: URL) throws -> String {
        guard let inputStream = InputStream(url: fileURL) else {
            throw SpeechRecognitionError.integrityCheckFailed
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
                throw SpeechRecognitionError.integrityCheckFailed
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
        modelRelativePath: String
    ) throws -> URL {
        let directModelURL = extractedDirectoryURL.appendingPathComponent(modelRelativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: directModelURL.path) {
            return extractedDirectoryURL
        }

        let relativeComponents = modelRelativePath.split(separator: "/").map(String.init)
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: extractedDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SpeechRecognitionError.extractionFailed("Unable to inspect the extracted package contents.")
        }

        var candidateRoots: [URL] = []

        for case let fileURL as URL in enumerator {
            guard isValidModelCandidate(
                fileURL,
                extractedDirectoryURL: extractedDirectoryURL,
                modelPathComponents: relativeComponents
            ) else {
                continue
            }

            candidateRoots.append(rootDirectoryURL(forModelURL: fileURL, modelPathComponents: relativeComponents))
        }

        let uniqueRoots = Array(Set(candidateRoots.map(\.path)))
            .sorted()
            .map(URL.init(fileURLWithPath:))

        guard let rootURL = uniqueRoots.first else {
            throw SpeechRecognitionError.extractionFailed("解压后没有找到 \(modelRelativePath)。")
        }

        if uniqueRoots.count > 1 {
            throw SpeechRecognitionError.extractionFailed("解压后找到了多个候选模型目录，请检查压缩包结构。")
        }

        return rootURL
    }

    private func isValidModelCandidate(
        _ fileURL: URL,
        extractedDirectoryURL: URL,
        modelPathComponents: [String]
    ) -> Bool {
        guard !modelPathComponents.isEmpty else {
            return false
        }

        guard !fileURL.hasDirectoryPath else {
            return false
        }

        let extractedPathComponents = extractedDirectoryURL.standardizedFileURL.pathComponents
        let filePathComponents = fileURL.standardizedFileURL.pathComponents

        guard filePathComponents.count >= extractedPathComponents.count else {
            return false
        }

        let relativeComponents = Array(filePathComponents.dropFirst(extractedPathComponents.count))

        guard relativeComponents.count >= modelPathComponents.count else {
            return false
        }

        guard !relativeComponents.contains("__MACOSX") else {
            return false
        }

        return Array(relativeComponents.suffix(modelPathComponents.count)) == modelPathComponents
    }

    private func rootDirectoryURL(
        forModelURL fileURL: URL,
        modelPathComponents: [String]
    ) -> URL {
        var rootURL = fileURL

        for _ in 0..<modelPathComponents.count {
            rootURL.deleteLastPathComponent()
        }

        return rootURL
    }

    private func loadInstalledIndex() throws -> SpeechInstalledPackagesIndex {
        let installedIndexURL = try installedIndexURL()

        guard FileManager.default.fileExists(atPath: installedIndexURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: installedIndexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SpeechInstalledPackagesIndex.self, from: data)
        } catch {
            throw SpeechRecognitionError.installationFailed("Failed to read the installed speech model index.")
        }
    }

    private func upsertInstalledRecord(_ record: SpeechInstalledPackageRecord) throws {
        var index = try loadInstalledIndex()
        index.packages.removeAll { $0.packageId == record.packageId }
        index.packages.append(record)
        try saveInstalledIndex(index)
    }

    private func saveInstalledIndex(_ index: SpeechInstalledPackagesIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(index)
            try ensureBaseDirectoryExists()
            try data.write(to: try installedIndexURL(), options: .atomic)
        } catch {
            throw SpeechRecognitionError.installationFailed("Failed to write the installed speech model index.")
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
            throw SpeechRecognitionError.installationFailed("Unable to locate Application Support directory.")
        }

        return applicationSupportURL.appendingPathComponent("SpeechModels", isDirectory: true)
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

    private func log(_ message: String) {
        print("[SpeechModelInstaller] \(message)")
    }
}
