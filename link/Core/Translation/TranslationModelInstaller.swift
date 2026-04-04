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
    private struct RawMarianConfig: Decodable {
        let bosTokenId: Int?
        let eosTokenId: Int?
        let padTokenId: Int?
        let decoderStartTokenId: Int?
        let maxPositionEmbeddings: Int?

        enum CodingKeys: String, CodingKey {
            case bosTokenId = "bos_token_id"
            case eosTokenId = "eos_token_id"
            case padTokenId = "pad_token_id"
            case decoderStartTokenId = "decoder_start_token_id"
            case maxPositionEmbeddings = "max_position_embeddings"
        }
    }

    private struct RawGenerationConfig: Decodable {
        let maxLength: Int?
        let bosTokenId: Int?
        let eosTokenId: Int?
        let padTokenId: Int?
        let decoderStartTokenId: Int?

        enum CodingKeys: String, CodingKey {
            case maxLength = "max_length"
            case bosTokenId = "bos_token_id"
            case eosTokenId = "eos_token_id"
            case padTokenId = "pad_token_id"
            case decoderStartTokenId = "decoder_start_token_id"
        }
    }

    private struct RawTokenizerConfig: Decodable {
        let modelMaxLength: Int?
        let sourceLang: String?
        let targetLang: String?

        enum CodingKeys: String, CodingKey {
            case modelMaxLength = "model_max_length"
            case sourceLang = "source_lang"
            case targetLang = "target_lang"
        }
    }

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
            log("Missing package metadata for packageId=\(packageId)")
            throw TranslationError.packageMissing(packageId: packageId)
        }

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

            let archiveURL = try await downloadArchive(for: package, into: workingDirectoryURL)
            try verifyChecksumIfNeeded(for: package, archiveURL: archiveURL)

            let extractedDirectoryURL = workingDirectoryURL.appendingPathComponent("extracted", isDirectory: true)
            try ensureDirectoryExists(at: extractedDirectoryURL)

            do {
                try FileManager.default.unzipItem(at: archiveURL, to: extractedDirectoryURL)
                log("Unzipped packageId=\(package.packageId) into \(extractedDirectoryURL.path)")
            } catch {
                log("Unzip failed for packageId=\(package.packageId): \(error.localizedDescription)")
                throw TranslationError.extractionFailed(error.localizedDescription)
            }

            let payloadRootURL = try ensurePayloadRoot(
                for: package,
                extractedDirectoryURL: extractedDirectoryURL
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
                log("Failed to move packageId=\(package.packageId) into destination: \(error.localizedDescription)")
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

            log("Install completed for packageId=\(package.packageId), destination=\(destinationURL.path)")

            return TranslationModelInstallation(
                package: package,
                manifest: manifest,
                modelDirectoryURL: destinationURL
                    .appendingPathComponent(package.manifestRelativePath, isDirectory: false)
                    .deletingLastPathComponent()
            )
        } catch {
            log("Install failed for packageId=\(package.packageId): \(error.localizedDescription)")
            throw error
        }
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
            log("Cached installation invalid for packageId=\(package.packageId): \(error.localizedDescription)")
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
        log("Downloading packageId=\(package.packageId) from \(package.archiveURL.absoluteString)")
        let (temporaryFileURL, response) = try await session.download(from: package.archiveURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode else {
            log("Download failed for packageId=\(package.packageId): unexpected response")
            throw TranslationError.downloadFailed("The server did not return a successful response.")
        }

        let archiveURL = workingDirectoryURL.appendingPathComponent("\(package.packageId).zip", isDirectory: false)

        do {
            try FileManager.default.moveItem(at: temporaryFileURL, to: archiveURL)
        } catch {
            log("Failed to move downloaded archive for packageId=\(package.packageId): \(error.localizedDescription)")
            throw TranslationError.downloadFailed(error.localizedDescription)
        }

        log("Downloaded packageId=\(package.packageId) to \(archiveURL.path)")
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
            log("Checksum mismatch for archive=\(archiveURL.lastPathComponent), expected=\(expectedHash), actual=\(actualHash)")
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

    private func ensurePayloadRoot(
        for package: TranslationModelPackage,
        extractedDirectoryURL: URL
    ) throws -> URL {
        do {
            return try resolvePayloadRoot(
                extractedDirectoryURL: extractedDirectoryURL,
                manifestRelativePath: package.manifestRelativePath
            )
        } catch let error as TranslationError {
            guard case .extractionFailed = error,
                  let fallbackRootURL = try inferRawMarianPayloadRoot(
                    extractedDirectoryURL: extractedDirectoryURL,
                    package: package
                  ) else {
                throw error
            }

            let manifestURL = fallbackRootURL.appendingPathComponent(
                package.manifestRelativePath,
                isDirectory: false
            )
            let manifest = try synthesizeManifest(
                for: package,
                modelDirectoryURL: fallbackRootURL
            )
            try saveManifest(manifest, to: manifestURL)
            log("Synthesized manifest for packageId=\(package.packageId) at \(manifestURL.path)")
            return fallbackRootURL
        }
    }

    private func resolvePayloadRoot(
        extractedDirectoryURL: URL,
        manifestRelativePath: String
    ) throws -> URL {
        let directManifestURL = extractedDirectoryURL.appendingPathComponent(manifestRelativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: directManifestURL.path) {
            return extractedDirectoryURL
        }

        let manifestPathComponents = manifestRelativePath
            .split(separator: "/")
            .map(String.init)
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: extractedDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TranslationError.extractionFailed("Unable to inspect the extracted package contents.")
        }

        var candidateRoots: [URL] = []

        for case let fileURL as URL in enumerator {
            guard isValidManifestCandidate(
                fileURL,
                extractedDirectoryURL: extractedDirectoryURL,
                manifestPathComponents: manifestPathComponents
            ) else {
                continue
            }

            let rootURL = rootDirectoryURL(
                forManifestURL: fileURL,
                manifestPathComponents: manifestPathComponents
            )
            candidateRoots.append(rootURL)
        }

        let uniqueRoots = Array(Set(candidateRoots.map(\.path)))
            .sorted()
            .map(URL.init(fileURLWithPath:))

        guard let rootURL = uniqueRoots.first else {
            log("Manifest not found after extraction. expectedPath=\(manifestRelativePath), extractedDirectory=\(extractedDirectoryURL.path)")
            logExtractedContents(at: extractedDirectoryURL)
            throw TranslationError.extractionFailed("解压后没有找到 \(manifestRelativePath)。")
        }

        if uniqueRoots.count > 1 {
            log("Multiple manifest roots found after extraction for path=\(manifestRelativePath): \(uniqueRoots.map(\.path).joined(separator: ", "))")
            throw TranslationError.extractionFailed("解压后找到了多个模型目录，请检查压缩包结构。")
        }

        log("Resolved payload root for manifestPath=\(manifestRelativePath): \(rootURL.path)")
        return rootURL
    }

    private func inferRawMarianPayloadRoot(
        extractedDirectoryURL: URL,
        package: TranslationModelPackage
    ) throws -> URL? {
        guard package.family == .marian else {
            return nil
        }

        let requiredFileNames = [
            "config.json",
            "generation_config.json",
            "tokenizer_config.json",
            "vocab.json",
            "encoder_model.onnx",
            "decoder_model.onnx"
        ]

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: extractedDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidateDirectories: Set<String> = []

        for case let fileURL as URL in enumerator {
            guard !fileURL.hasDirectoryPath else { continue }
            candidateDirectories.insert(fileURL.deletingLastPathComponent().path)
        }

        let candidates = candidateDirectories
            .sorted()
            .map(URL.init(fileURLWithPath:))
            .filter { directoryURL in
                requiredFileNames.allSatisfy { fileName in
                    fileManager.fileExists(
                        atPath: directoryURL
                            .appendingPathComponent(fileName, isDirectory: false)
                            .path
                    )
                }
            }

        if candidates.count > 1 {
            log("Multiple raw Marian roots found for packageId=\(package.packageId): \(candidates.map(\.path).joined(separator: ", "))")
        }

        if let candidate = candidates.first {
            log("Detected raw Marian export root for packageId=\(package.packageId): \(candidate.path)")
        }

        return candidates.first
    }

    private func isValidManifestCandidate(
        _ fileURL: URL,
        extractedDirectoryURL: URL,
        manifestPathComponents: [String]
    ) -> Bool {
        guard !manifestPathComponents.isEmpty else {
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

        guard relativeComponents.count >= manifestPathComponents.count else {
            return false
        }

        guard !relativeComponents.contains("__MACOSX") else {
            return false
        }

        return Array(relativeComponents.suffix(manifestPathComponents.count)) == manifestPathComponents
    }

    private func rootDirectoryURL(
        forManifestURL fileURL: URL,
        manifestPathComponents: [String]
    ) -> URL {
        var rootURL = fileURL

        for _ in 0..<manifestPathComponents.count {
            rootURL.deleteLastPathComponent()
        }

        return rootURL
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

    private func synthesizeManifest(
        for package: TranslationModelPackage,
        modelDirectoryURL: URL
    ) throws -> TranslationModelManifest {
        let config = try loadJSON(
            RawMarianConfig.self,
            from: modelDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
        )
        let generationConfig = try loadJSON(
            RawGenerationConfig.self,
            from: modelDirectoryURL.appendingPathComponent("generation_config.json", isDirectory: false)
        )
        let tokenizerConfig = try loadJSON(
            RawTokenizerConfig.self,
            from: modelDirectoryURL.appendingPathComponent("tokenizer_config.json", isDirectory: false)
        )

        let maxLength = generationConfig.maxLength
            ?? tokenizerConfig.modelMaxLength
            ?? config.maxPositionEmbeddings
            ?? 512

        let decoderWithPastURL = modelDirectoryURL.appendingPathComponent(
            "decoder_with_past_model.onnx",
            isDirectory: false
        )

        return TranslationModelManifest(
            family: package.family,
            tokenizer: .init(
                kind: .marianSentencePieceVocabulary,
                vocabularyFile: "vocab.json",
                sourceSentencePieceFile: "source.spm",
                targetSentencePieceFile: "target.spm"
            ),
            onnxFiles: .init(
                encoder: "encoder_model.onnx",
                decoder: "decoder_model.onnx",
                decoderWithPast: FileManager.default.fileExists(atPath: decoderWithPastURL.path)
                    ? "decoder_with_past_model.onnx"
                    : nil
            ),
            generation: .init(
                maxInputLength: maxLength,
                maxOutputLength: maxLength,
                bosTokenId: generationConfig.bosTokenId ?? config.bosTokenId ?? 0,
                eosTokenId: generationConfig.eosTokenId ?? config.eosTokenId ?? 0,
                padTokenId: generationConfig.padTokenId ?? config.padTokenId ?? 65000,
                decoderStartTokenId: generationConfig.decoderStartTokenId
                    ?? config.decoderStartTokenId
                    ?? generationConfig.padTokenId
                    ?? config.padTokenId
                    ?? 65000
            ),
            tensorNames: .init(
                encoderInputIDs: "input_ids",
                encoderAttentionMask: "attention_mask",
                encoderOutput: "last_hidden_state",
                decoderInputIDs: "input_ids",
                decoderEncoderAttentionMask: "encoder_attention_mask",
                decoderEncoderHiddenStates: "encoder_hidden_states",
                decoderOutputLogits: "logits"
            ),
            supportedLanguagePairs: [
                .init(
                    source: tokenizerConfig.sourceLang ?? package.source,
                    target: tokenizerConfig.targetLang ?? package.target
                )
            ]
        )
    }

    private func saveManifest(_ manifest: TranslationModelManifest, to manifestURL: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw TranslationError.manifestInvalid("Failed to write synthesized manifest: \(error.localizedDescription)")
        }
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TranslationError.manifestInvalid("Failed to load \(url.lastPathComponent): \(error.localizedDescription)")
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

    private func log(_ message: String) {
        print("[TranslationModelInstaller] \(message)")
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
            let relativePath = fileURL.path.replacingOccurrences(
                of: directoryURL.path + "/",
                with: ""
            )
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
