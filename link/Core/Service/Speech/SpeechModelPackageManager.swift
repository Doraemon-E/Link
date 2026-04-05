//
//  SpeechModelPackageManager.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import CryptoKit
import Foundation
import ZIPFoundation

actor SpeechModelPackageManager {
    private let catalogRepository: SpeechModelCatalogRepository
    private let baseDirectoryURLOverride: URL?

    init(
        catalogRepository: SpeechModelCatalogRepository,
        baseDirectoryURLOverride: URL? = nil
    ) {
        self.catalogRepository = catalogRepository
        self.baseDirectoryURLOverride = baseDirectoryURLOverride
    }

    func warmUpCatalog() async {
        await catalogRepository.warmUpCatalog()
    }

    func defaultPackageMetadata() async throws -> SpeechModelPackage? {
        try await catalogRepository.defaultPackage()
    }

    func isDefaultPackageInstalled() async throws -> Bool {
        guard let package = try await catalogRepository.defaultPackage() else {
            return false
        }

        return try validInstalledPackage(for: package) != nil
    }

    func installedDefaultPackage() async throws -> SpeechModelInstallation? {
        guard let package = try await catalogRepository.defaultPackage() else {
            return nil
        }

        return try validInstalledPackage(for: package)
    }

    func package(packageId: String) async throws -> SpeechModelPackage? {
        try await catalogRepository.package(packageId: packageId)
    }

    func packages() async throws -> [SpeechModelPackage] {
        try await catalogRepository.packages()
    }

    func installedPackages() async throws -> [SpeechInstalledPackageSummary] {
        let index = try loadInstalledIndex()
        var summaries: [SpeechInstalledPackageSummary] = []

        for record in index.packages.sorted(by: { $0.installedAt > $1.installedAt }) {
            guard let package = try await catalogRepository.package(packageId: record.packageId) else {
                continue
            }

            guard try validInstalledPackage(for: package) != nil else {
                continue
            }

            summaries.append(
                SpeechInstalledPackageSummary(
                    packageId: package.packageId,
                    version: package.version,
                    archiveSize: package.archiveSize,
                    installedSize: package.installedSize,
                    installedAt: record.installedAt
                )
            )
        }

        return summaries
    }

    func install(packageId: String) async throws -> SpeechModelInstallation {
        guard let package = try await catalogRepository.package(packageId: packageId) else {
            log("Missing package metadata for packageId=\(packageId)")
            throw SpeechRecognitionError.packageMissing(packageId)
        }

        return try await install(package: package, archiveURLOverride: nil)
    }

    func install(packageId: String, archiveURL: URL) async throws -> SpeechModelInstallation {
        guard let package = try await catalogRepository.package(packageId: packageId) else {
            log("Missing package metadata for packageId=\(packageId)")
            throw SpeechRecognitionError.packageMissing(packageId)
        }

        return try await install(package: package, archiveURLOverride: archiveURL)
    }

    func remove(packageId: String) async throws {
        for candidatePackageId in candidatePackageIDs(for: packageId) {
            let packageURL = try packageDirectoryURL(for: candidatePackageId)
            if FileManager.default.fileExists(atPath: packageURL.path) {
                try FileManager.default.removeItem(at: packageURL)
            }
        }

        var index = try loadInstalledIndex()
        let normalizedPackageId = SpeechModelPackage.normalizePackageId(packageId)
        index.packages.removeAll {
            SpeechModelPackage.normalizePackageId($0.packageId) == normalizedPackageId
        }
        try saveInstalledIndex(index)
    }

    private func install(
        package: SpeechModelPackage,
        archiveURLOverride: URL?
    ) async throws -> SpeechModelInstallation {
        if let installation = try validInstalledPackage(for: package) {
            log("Using cached installation for packageId=\(package.packageId)")
            return installation
        }

        do {
            log("Starting install for packageId=\(package.packageId), archiveURL=\(package.archiveURL.absoluteString)")

            try removeStaleInstallationIfNeeded(packageId: package.packageId)
            try ensureDirectoryExists(at: try packagesDirectoryURL())
            try ensureDirectoryExists(at: try temporaryDirectoryURL())

            let workingDirectoryURL = try makeWorkingDirectory()
            defer {
                try? FileManager.default.removeItem(at: workingDirectoryURL)
            }

            let archiveURL: URL
            if let archiveURLOverride {
                archiveURL = archiveURLOverride
            } else {
                archiveURL = try await downloadArchive(for: package, into: workingDirectoryURL)
            }
            try verifyChecksumIfNeeded(for: package, archiveURL: archiveURL)

            let extractedDirectoryURL = workingDirectoryURL.appendingPathComponent("extracted", isDirectory: true)
            try ensureDirectoryExists(at: extractedDirectoryURL)

            do {
                try FileManager.default.unzipItem(at: archiveURL, to: extractedDirectoryURL)
                log("Unzipped packageId=\(package.packageId) into \(extractedDirectoryURL.path)")
                logExtractedContents(at: extractedDirectoryURL)
            } catch {
                log("Unzip failed for packageId=\(package.packageId): \(error.localizedDescription)")
                throw SpeechRecognitionError.extractionFailed(error.localizedDescription)
            }

            let payloadRootURL = try resolvePayloadRoot(
                for: package,
                extractedDirectoryURL: extractedDirectoryURL
            )
            let destinationURL = try packageDirectoryURL(for: package.packageId)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            do {
                try FileManager.default.moveItem(at: payloadRootURL, to: destinationURL)
            } catch {
                log("Failed to move packageId=\(package.packageId) into destination: \(error.localizedDescription)")
                throw SpeechRecognitionError.installationFailed(error.localizedDescription)
            }

            let resolvedModelRelativePath = try resolveInstalledModelRelativePath(
                for: package,
                packageDirectoryURL: destinationURL
            )
            let installation = SpeechModelInstallation(
                package: package,
                modelURL: destinationURL.appendingPathComponent(
                    resolvedModelRelativePath,
                    isDirectory: false
                )
            )

            try upsertInstalledRecord(
                SpeechInstalledPackageRecord(
                    packageId: package.packageId,
                    version: package.version,
                    modelRelativePath: resolvedModelRelativePath,
                    installedAt: .now
                )
            )

            log("Install completed for packageId=\(package.packageId), destination=\(destinationURL.path), modelPath=\(resolvedModelRelativePath)")
            return installation
        } catch {
            log("Install failed for packageId=\(package.packageId): \(error.localizedDescription)")
            throw error
        }
    }

    private func installedPackage(for package: SpeechModelPackage) throws -> SpeechModelInstallation? {
        let index = try loadInstalledIndex()

        guard let record = index.packages.first(where: {
            SpeechModelPackage.normalizePackageId($0.packageId) == package.packageId
        }) else {
            return nil
        }

        let packageDirectoryURL = try packageDirectoryURL(for: record.packageId)
        let resolvedModelRelativePath = try resolveInstalledModelRelativePath(
            for: package,
            packageDirectoryURL: packageDirectoryURL,
            preferredRelativePath: record.modelRelativePath
        )
        let modelURL = packageDirectoryURL.appendingPathComponent(
            resolvedModelRelativePath,
            isDirectory: false
        )

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
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration)
        log("Downloading packageId=\(package.packageId) from \(package.archiveURL.absoluteString)")
        let (temporaryFileURL, response) = try await session.download(from: package.archiveURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode else {
            log("Download failed for packageId=\(package.packageId): unexpected response")
            throw SpeechRecognitionError.downloadFailed("The server did not return a successful response.")
        }

        let archiveURL = workingDirectoryURL.appendingPathComponent("\(package.packageId).zip", isDirectory: false)

        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: archiveURL)
        } catch {
            log("Failed to move downloaded archive for packageId=\(package.packageId): \(error.localizedDescription)")
            throw SpeechRecognitionError.downloadFailed(error.localizedDescription)
        }

        log("Downloaded packageId=\(package.packageId) to \(archiveURL.path)")
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
            log("Checksum mismatch for archive=\(archiveURL.lastPathComponent), expected=\(expectedHash), actual=\(actualHash)")
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
        for package: SpeechModelPackage,
        extractedDirectoryURL: URL
    ) throws -> URL {
        let modelRelativePath = package.modelRelativePath
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

        if let rootURL = uniqueRoots.first, uniqueRoots.count == 1 {
            log("Resolved payload root for modelPath=\(modelRelativePath): \(rootURL.path)")
            return rootURL
        }

        if package.family == .whisper,
           let fallback = try detectWhisperModel(in: extractedDirectoryURL) {
            log("Detected Whisper model file after extraction: \(fallback.relativePath)")
            log("Resolved payload root for modelPath=\(modelRelativePath) via Whisper fallback: \(fallback.rootURL.path)")
            return fallback.rootURL
        }

        guard let rootURL = uniqueRoots.first else {
            log("Model not found after extraction. expectedPath=\(modelRelativePath), extractedDirectory=\(extractedDirectoryURL.path)")
            logExtractedContents(at: extractedDirectoryURL)
            throw SpeechRecognitionError.extractionFailed("解压后没有找到 \(modelRelativePath)。")
        }

        if uniqueRoots.count > 1 {
            let rootPaths = uniqueRoots.map(\.path).joined(separator: ", ")
            log("Multiple model roots found after extraction for path=\(modelRelativePath): \(rootPaths)")
            throw SpeechRecognitionError.extractionFailed("解压后找到了多个候选模型目录，请检查压缩包结构。")
        }

        log("Resolved payload root for modelPath=\(modelRelativePath): \(rootURL.path)")
        return rootURL
    }

    private func resolveInstalledModelRelativePath(
        for package: SpeechModelPackage,
        packageDirectoryURL: URL,
        preferredRelativePath: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default

        for relativePath in [preferredRelativePath, package.modelRelativePath].compactMap({ $0 }) {
            let modelURL = packageDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: modelURL.path) {
                return relativePath
            }
        }

        if package.family == .whisper,
           let fallback = try detectWhisperModel(in: packageDirectoryURL) {
            log("Falling back to detected Whisper model path for packageId=\(package.packageId): \(fallback.relativePath)")
            return fallback.relativePath
        }

        throw SpeechRecognitionError.installationFailed("Installed speech model is missing the expected model file.")
    }

    private func detectWhisperModel(
        in directoryURL: URL
    ) throws -> (rootURL: URL, relativePath: String)? {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(rootURL: URL, relativePath: String)] = []

        for case let fileURL as URL in enumerator {
            guard !fileURL.hasDirectoryPath else { continue }

            guard let relativePath = relativePath(from: directoryURL, to: fileURL) else {
                continue
            }

            guard !relativePath.contains("__MACOSX") else { continue }

            let lowercasedName = fileURL.lastPathComponent.lowercased()
            guard lowercasedName.hasSuffix(".gguf") || lowercasedName.hasSuffix(".bin") else {
                continue
            }

            guard lowercasedName.contains("ggml") || lowercasedName.contains("whisper") else {
                continue
            }

            candidates.append((fileURL.deletingLastPathComponent(), relativePath))
        }

        let uniqueCandidates = Array(
            Dictionary(
                candidates.map { ($0.relativePath, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        ).sorted { $0.relativePath < $1.relativePath }

        guard let candidate = uniqueCandidates.first else {
            return nil
        }

        if uniqueCandidates.count > 1 {
            let paths = uniqueCandidates.map(\.relativePath).joined(separator: ", ")
            log("Multiple Whisper model candidates found: \(paths)")
            throw SpeechRecognitionError.extractionFailed("解压后找到了多个语音模型文件，请检查压缩包结构。")
        }

        return candidate
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

        let extractedPathComponents = extractedDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let filePathComponents = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents

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

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String? {
        let normalizedRootComponents = rootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let normalizedFileComponents = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents

        guard normalizedFileComponents.starts(with: normalizedRootComponents) else {
            return nil
        }

        let relativeComponents = normalizedFileComponents.dropFirst(normalizedRootComponents.count)
        guard !relativeComponents.isEmpty else {
            return fileURL.lastPathComponent
        }

        return relativeComponents.joined(separator: "/")
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
        let normalizedPackageId = SpeechModelPackage.normalizePackageId(record.packageId)
        index.packages.removeAll {
            SpeechModelPackage.normalizePackageId($0.packageId) == normalizedPackageId
        }
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
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("installed.json", isDirectory: false)
        }

        return try ModelAssetStoragePaths.installedIndexURL(for: .speech)
    }

    private func packagesDirectoryURL() throws -> URL {
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("packages", isDirectory: true)
        }

        return try ModelAssetStoragePaths.packagesDirectoryURL(for: .speech)
    }

    private func packageDirectoryURL(for packageId: String) throws -> URL {
        if baseDirectoryURLOverride != nil {
            return try packagesDirectoryURL().appendingPathComponent(packageId, isDirectory: true)
        }

        return try ModelAssetStoragePaths.packageDirectoryURL(for: .speech, packageId: packageId)
    }

    private func removeStaleInstallationIfNeeded(packageId: String) throws {
        for candidatePackageId in candidatePackageIDs(for: packageId) {
            let packageURL = try packageDirectoryURL(for: candidatePackageId)
            if FileManager.default.fileExists(atPath: packageURL.path) {
                try? FileManager.default.removeItem(at: packageURL)
            }
        }

        var index = try loadInstalledIndex()
        let originalCount = index.packages.count
        let normalizedPackageId = SpeechModelPackage.normalizePackageId(packageId)
        index.packages.removeAll {
            SpeechModelPackage.normalizePackageId($0.packageId) == normalizedPackageId
        }

        if index.packages.count != originalCount {
            try saveInstalledIndex(index)
        }
    }

    private func candidatePackageIDs(for packageId: String) -> [String] {
        let normalizedPackageId = SpeechModelPackage.normalizePackageId(packageId)
        if normalizedPackageId == packageId {
            return [normalizedPackageId, normalizedPackageId + ".zip"]
        }

        return [normalizedPackageId, packageId]
    }

    private func temporaryDirectoryURL() throws -> URL {
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("tmp", isDirectory: true)
        }

        return try ModelAssetStoragePaths.temporaryDirectoryURL(for: .speech)
    }

    private func baseDirectoryURL() throws -> URL {
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride
        }

        return try ModelAssetStoragePaths.baseDirectoryURL(for: .speech)
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
        print("[SpeechModelPackageManager] \(message)")
    }

    private func logExtractedContents(at directoryURL: URL) {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            log("Failed to enumerate extracted contents at \(directoryURL.path)")
            return
        }

        var entries: [String] = []

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(from: directoryURL, to: fileURL) else {
                continue
            }
            let suffix = fileURL.hasDirectoryPath ? "/" : ""
            entries.append(relativePath + suffix)

            if entries.count >= 60 {
                break
            }
        }

        if entries.isEmpty {
            log("Extracted directory is empty: \(directoryURL.path)")
            return
        }

        log("Extracted contents sample (\(entries.count) entries): \(entries.joined(separator: ", "))")
    }
}
