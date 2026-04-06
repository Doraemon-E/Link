//
//  TranslationModelPackageManager.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import CryptoKit
import Foundation
import ZIPFoundation

nonisolated struct TranslationModelInstallation {
    let package: TranslationModelPackage
    let manifest: TranslationModelManifest
    let modelDirectoryURL: URL
}

actor TranslationModelPackageManager: TranslationModelProviding, TranslationAssetReadinessProviding {
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
        let badWordsIds: [[Int]]?

        enum CodingKeys: String, CodingKey {
            case maxLength = "max_length"
            case bosTokenId = "bos_token_id"
            case eosTokenId = "eos_token_id"
            case padTokenId = "pad_token_id"
            case decoderStartTokenId = "decoder_start_token_id"
            case badWordsIds = "bad_words_ids"
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

    private let catalogRepository: TranslationModelCatalogRepository
    private let baseDirectoryURLOverride: URL?

    init(
        catalogRepository: TranslationModelCatalogRepository,
        baseDirectoryURLOverride: URL? = nil
    ) {
        self.catalogRepository = catalogRepository
        self.baseDirectoryURLOverride = baseDirectoryURLOverride
    }

    func packageMetadata(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationModelPackage? {
        guard source != target else {
            return nil
        }

        return try await catalogRepository.package(source: source, target: target)
    }

    func installedPackage(for source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationModelInstallation? {
        guard let package = try await catalogRepository.package(source: source, target: target) else {
            return nil
        }

        return try validInstalledPackage(for: package)
    }

    func package(packageId: String) async throws -> TranslationModelPackage? {
        try await catalogRepository.package(packageId: packageId)
    }

    func packages() async throws -> [TranslationModelPackage] {
        try await catalogRepository.packages()
    }

    func installedPackages() async throws -> [TranslationInstalledPackageSummary] {
        let index = try loadInstalledIndex()
        var summaries: [TranslationInstalledPackageSummary] = []

        for record in index.packages.sorted(by: { $0.installedAt > $1.installedAt }) {
            guard let package = try await catalogRepository.package(packageId: record.packageId) else {
                continue
            }

            guard try validInstalledPackage(for: package) != nil else {
                continue
            }

            summaries.append(
                TranslationInstalledPackageSummary(
                    packageId: package.packageId,
                    version: package.version,
                    sourceLanguage: SupportedLanguage.fromTranslationModelCode(package.source),
                    targetLanguage: SupportedLanguage.fromTranslationModelCode(package.target),
                    archiveSize: package.archiveSize,
                    installedSize: package.installedSize,
                    installedAt: record.installedAt
                )
            )
        }

        return summaries
    }

    func translationAssetRequirement(
        for route: TranslationRoute
    ) async throws -> TranslationAssetRequirement {
        guard !route.steps.isEmpty else {
            return .ready
        }

        var missingPackages: [TranslationModelPackage] = []

        for step in route.steps {
            guard let package = try await packageMetadata(
                source: step.source,
                target: step.target
            ) else {
                throw TranslationError.modelPackageUnavailable(
                    source: step.source,
                    target: step.target
                )
            }

            if try validInstalledPackage(for: package) == nil {
                missingPackages.append(package)
            }
        }

        return TranslationAssetRequirement(missingPackages: missingPackages)
    }

    func areTranslationAssetsReady(
        for route: TranslationRoute
    ) async throws -> Bool {
        try await translationAssetRequirement(for: route).isReady
    }

    func install(packageId: String, archiveURL: URL) async throws -> TranslationModelInstallation {
        guard let package = try await catalogRepository.package(packageId: packageId) else {
            throw TranslationError.packageMissing(packageId: packageId)
        }

        return try await install(package: package, archiveURL: archiveURL)
    }

    private func install(
        package: TranslationModelPackage,
        archiveURL: URL
    ) async throws -> TranslationModelInstallation {
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

        try verifyChecksumIfNeeded(for: package, archiveURL: archiveURL)

        let extractedDirectoryURL = workingDirectoryURL.appendingPathComponent("extracted", isDirectory: true)
        try ensureDirectoryExists(at: extractedDirectoryURL)

        do {
            try FileManager.default.unzipItem(at: archiveURL, to: extractedDirectoryURL)
        } catch {
            throw TranslationError.extractionFailed(error.localizedDescription)
        }

        let payloadRootURL = try ensurePayloadRoot(
            for: package,
            extractedDirectoryURL: extractedDirectoryURL
        )

        let manifestURL = payloadRootURL.appendingPathComponent(package.manifestRelativePath, isDirectory: false)
        let manifest = try loadManifestOrSynthesizeIfPossible(
            for: package,
            modelDirectoryURL: payloadRootURL,
            manifestURL: manifestURL
        )
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
        guard FileManager.default.fileExists(atPath: packageDirectoryURL.path) else {
            return nil
        }

        let manifestURL = packageDirectoryURL.appendingPathComponent(record.manifestRelativePath, isDirectory: false)
        let manifest = try loadManifestOrSynthesizeIfPossible(
            for: package,
            modelDirectoryURL: packageDirectoryURL,
            manifestURL: manifestURL
        )
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
                  let fallbackRootURL = try inferRawModelPayloadRoot(
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
            throw TranslationError.extractionFailed("解压后没有找到 \(manifestRelativePath)。")
        }

        if uniqueRoots.count > 1 {
            throw TranslationError.extractionFailed("解压后找到了多个模型目录，请检查压缩包结构。")
        }

        return rootURL
    }

    private func inferRawModelPayloadRoot(
        extractedDirectoryURL: URL,
        package: TranslationModelPackage
    ) throws -> URL? {
        guard let requiredFileNames = rawRequiredFileNames(for: package) else {
            return nil
        }

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

        return candidates.first
    }

    private func rawRequiredFileNames(for _: TranslationModelPackage) -> [String]? {
        [
            "config.json",
            "generation_config.json",
            "tokenizer_config.json",
            "vocab.json",
            "encoder_model.onnx",
            "decoder_model.onnx"
        ]
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

    private func loadManifestOrSynthesizeIfPossible(
        for package: TranslationModelPackage,
        modelDirectoryURL: URL,
        manifestURL: URL
    ) throws -> TranslationModelManifest {
        do {
            return try loadManifest(at: manifestURL)
        } catch let error as TranslationError {
            guard case .manifestInvalid = error,
                  let manifest = try synthesizeManifestIfPossible(
                    for: package,
                    modelDirectoryURL: modelDirectoryURL,
                    manifestURL: manifestURL
                  ) else {
                throw error
            }

            return manifest
        }
    }

    private func synthesizeManifestIfPossible(
        for package: TranslationModelPackage,
        modelDirectoryURL: URL,
        manifestURL: URL
    ) throws -> TranslationModelManifest? {
        guard let requiredFileNames = rawRequiredFileNames(for: package) else {
            return nil
        }

        let fileManager = FileManager.default
        guard requiredFileNames.allSatisfy({ fileName in
            fileManager.fileExists(
                atPath: modelDirectoryURL
                    .appendingPathComponent(fileName, isDirectory: false)
                    .path
            )
        }) else {
            return nil
        }

        let manifest = try synthesizeManifest(
            for: package,
            modelDirectoryURL: modelDirectoryURL
        )
        try saveManifest(manifest, to: manifestURL)
        return manifest
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
        try synthesizeMarianManifest(for: package, modelDirectoryURL: modelDirectoryURL)
    }

    private func synthesizeMarianManifest(
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

        let tokenizer = TranslationModelManifest.Tokenizer(
            kind: .marianSentencePieceVocabulary,
            vocabularyFile: "vocab.json",
            sourceSentencePieceFile: "source.spm",
            targetSentencePieceFile: "target.spm"
        )
        let onnxFiles = TranslationModelManifest.ONNXFiles(
            encoder: "encoder_model.onnx",
            decoder: "decoder_model.onnx",
            decoderWithPast: FileManager.default.fileExists(atPath: decoderWithPastURL.path)
                ? "decoder_with_past_model.onnx"
                : nil
        )
        let suppressedTokenIds: [Int]? = generationConfig.badWordsIds?.compactMap { tokenIDs -> Int? in
            guard tokenIDs.count == 1 else {
                return nil
            }

            return tokenIDs[0]
        }
        let generation = TranslationModelManifest.Generation(
            maxInputLength: maxLength,
            maxOutputLength: maxLength,
            bosTokenId: generationConfig.bosTokenId ?? config.bosTokenId ?? 0,
            eosTokenId: generationConfig.eosTokenId ?? config.eosTokenId ?? 0,
            padTokenId: generationConfig.padTokenId ?? config.padTokenId ?? 65000,
            decoderStartTokenId: generationConfig.decoderStartTokenId
                ?? config.decoderStartTokenId
                ?? generationConfig.padTokenId
                ?? config.padTokenId
                ?? 65000,
            suppressedTokenIds: suppressedTokenIds
        )
        let tensorNames = TranslationModelManifest.TensorNames(
            encoderInputIDs: "input_ids",
            encoderAttentionMask: "attention_mask",
            encoderOutput: "last_hidden_state",
            decoderInputIDs: "input_ids",
            decoderEncoderAttentionMask: "encoder_attention_mask",
            decoderEncoderHiddenStates: "encoder_hidden_states",
            decoderOutputLogits: "logits"
        )
        let supportedLanguagePair = TranslationModelManifest.LanguagePair(
            source: normalizedLanguageCode(
                tokenizerConfig.sourceLang,
                fallback: package.source
            ),
            target: normalizedLanguageCode(
                tokenizerConfig.targetLang,
                fallback: package.target
            )
        )

        return TranslationModelManifest(
            family: package.family,
            tokenizer: tokenizer,
            onnxFiles: onnxFiles,
            generation: generation,
            tensorNames: tensorNames,
            supportedLanguagePairs: [supportedLanguagePair]
        )
    }

    private func normalizedLanguageCode(_ rawCode: String?, fallback: String) -> String {
        guard let rawCode else {
            return fallback
        }

        let normalizedCode = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedCode.isEmpty else {
            return fallback
        }

        switch normalizedCode {
        case "eng", "en", "english":
            return "eng"
        case "zho", "zh", "chi", "cmn", "chinese":
            return "zho"
        case "jpn", "ja", "jap", "japanese":
            return "jpn"
        case "kor", "ko", "korean":
            return "kor"
        case "fra", "fr", "fre", "french":
            return "fra"
        case "deu", "de", "ger", "german":
            return "deu"
        case "rus", "ru", "russian":
            return "rus"
        case "spa", "es", "spanish":
            return "spa"
        case "ita", "it", "italian":
            return "ita"
        default:
            return fallback
        }
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
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("installed.json", isDirectory: false)
        }

        return try ModelAssetStoragePaths.installedIndexURL(for: .translation)
    }

    private func packagesDirectoryURL() throws -> URL {
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("packages", isDirectory: true)
        }

        return try ModelAssetStoragePaths.packagesDirectoryURL(for: .translation)
    }

    private func packageDirectoryURL(for packageId: String) throws -> URL {
        if baseDirectoryURLOverride != nil {
            return try packagesDirectoryURL().appendingPathComponent(packageId, isDirectory: true)
        }

        return try ModelAssetStoragePaths.packageDirectoryURL(for: .translation, packageId: packageId)
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
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride.appendingPathComponent("tmp", isDirectory: true)
        }

        return try ModelAssetStoragePaths.temporaryDirectoryURL(for: .translation)
    }

    private func baseDirectoryURL() throws -> URL {
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride
        }

        return try ModelAssetStoragePaths.baseDirectoryURL(for: .translation)
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
