//
//  TranslationModelCatalogService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum TranslationModelHostingConfiguration {
    static let remoteCatalogURL = URL(string: "https://link.hackerapp.site/link/translation/catalog.json")
}

actor TranslationModelCatalogService {
    private let remoteCatalogURL: URL?
    private let bootstrapCatalogFileName: String
    private let bundle: Bundle
    private var inMemoryCatalog: TranslationModelCatalog?
    private let logger = AppLogger.translationCatalog

    init(
        remoteCatalogURL: URL? = TranslationModelHostingConfiguration.remoteCatalogURL,
        bootstrapCatalogFileName: String = "translation-catalog.json",
        bundle: Bundle = .main
    ) {
        self.remoteCatalogURL = remoteCatalogURL
        self.bootstrapCatalogFileName = bootstrapCatalogFileName
        self.bundle = bundle
    }

    func warmUpCatalog() async {
        logger.info(
            "Catalog warm up started",
            metadata: ["remote_catalog_configured": "\(remoteCatalogURL != nil)"]
        )

        do {
            _ = try await refreshCatalog()
        } catch {
            logger.error(
                "Catalog refresh failed during warm up",
                metadata: ["error": appLogErrorDescription(error)]
            )
        }

        do {
            let catalog = try await catalog()
            logger.info(
                "Catalog warm up finished",
                metadata: Self.catalogMetadata(catalog)
            )
        } catch {
            logger.error(
                "Catalog load failed during warm up",
                metadata: ["error": appLogErrorDescription(error)]
            )
        }
    }

    func catalog() async throws -> TranslationModelCatalog {
        if let inMemoryCatalog {
            logger.debug(
                "Loaded catalog from memory",
                metadata: Self.catalogMetadata(inMemoryCatalog)
            )
            return inMemoryCatalog
        }

        if let cachedCatalog = try? loadCatalog(at: try cachedCatalogURL()) {
            inMemoryCatalog = cachedCatalog
            logger.info(
                "Loaded catalog from cache",
                metadata: Self.catalogMetadata(cachedCatalog)
            )
            return cachedCatalog
        }

        let bundledCatalog = try loadBundledCatalog()
        inMemoryCatalog = bundledCatalog
        logger.info(
            "Loaded catalog from bundled resource",
            metadata: Self.catalogMetadata(bundledCatalog)
        )
        return bundledCatalog
    }

    func refreshCatalog() async throws -> TranslationModelCatalog {
        guard let remoteCatalogURL else {
            logger.debug("Skipped catalog refresh because no remote catalog URL is configured")
            return try await catalog()
        }

        let startedAt = Date()
        logger.info(
            "Refreshing catalog from remote source",
            metadata: ["catalog_url": remoteCatalogURL.absoluteString]
        )

        do {
            let (data, response) = try await URLSession.shared.data(from: remoteCatalogURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode else {
                logger.error(
                    "Remote catalog refresh failed because the response status is invalid",
                    metadata: ["duration_ms": appElapsedMilliseconds(since: startedAt)]
                )
                throw TranslationError.catalogUnavailable
            }

            let refreshedCatalog = try decodeCatalog(from: data)
            try ensureBaseDirectoryExists()
            try data.write(to: try cachedCatalogURL(), options: .atomic)
            inMemoryCatalog = refreshedCatalog

            logger.info(
                "Remote catalog refresh finished",
                metadata: Self.catalogMetadata(refreshedCatalog).merging(
                    ["duration_ms": appElapsedMilliseconds(since: startedAt)],
                    uniquingKeysWith: { _, newValue in newValue }
                )
            )
            return refreshedCatalog
        } catch {
            logger.error(
                "Remote catalog refresh failed",
                metadata: [
                    "duration_ms": appElapsedMilliseconds(since: startedAt),
                    "error": appLogErrorDescription(error)
                ]
            )
            throw error
        }
    }

    func package(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationModelPackage? {
        logger.debug(
            "Resolving package metadata by language pair",
            metadata: Self.languageMetadata(source: source, target: target)
        )

        let currentCatalog = try await catalog()
        if let package = currentCatalog.package(source: source, target: target) {
            logger.info(
                "Resolved package metadata by language pair",
                metadata: Self.packageMetadata(package)
                    .merging(Self.languageMetadata(source: source, target: target)) { _, newValue in newValue }
            )
            return package
        }

        if let refreshedCatalog = try? await refreshCatalog() {
            let package = refreshedCatalog.package(source: source, target: target)
            logger.info(
                "Resolved package metadata after catalog refresh",
                metadata: Self.resultMetadata(
                    package: package,
                    fallbackMetadata: Self.languageMetadata(source: source, target: target)
                )
            )
            return package
        }

        logger.error(
            "Package metadata unavailable because catalog refresh failed",
            metadata: Self.languageMetadata(source: source, target: target)
        )
        return nil
    }

    func package(packageId: String) async throws -> TranslationModelPackage? {
        logger.debug(
            "Resolving package metadata by package identifier",
            metadata: ["package_id": packageId]
        )

        let currentCatalog = try await catalog()
        if let package = currentCatalog.package(packageId: packageId) {
            logger.info(
                "Resolved package metadata by package identifier",
                metadata: Self.packageMetadata(package)
            )
            return package
        }

        if let refreshedCatalog = try? await refreshCatalog() {
            let package = refreshedCatalog.package(packageId: packageId)
            logger.info(
                "Resolved package metadata after catalog refresh",
                metadata: Self.resultMetadata(package: package, fallbackMetadata: ["package_id": packageId])
            )
            return package
        }

        logger.error(
            "Package metadata unavailable because catalog refresh failed",
            metadata: ["package_id": packageId]
        )
        return nil
    }

    private func decodeCatalog(from data: Data) throws -> TranslationModelCatalog {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranslationModelCatalog.self, from: data)
        } catch {
            throw TranslationError.catalogInvalid(error.localizedDescription)
        }
    }

    private func loadCatalog(at url: URL) throws -> TranslationModelCatalog {
        do {
            let data = try Data(contentsOf: url)
            return try decodeCatalog(from: data)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.catalogUnavailable
        }
    }

    private func loadBundledCatalog() throws -> TranslationModelCatalog {
        let catalogURL = try bundledCatalogURL()
        return try loadCatalog(at: catalogURL)
    }

    private func bundledCatalogURL() throws -> URL {
        let candidateDirectories = bundledCandidateDirectories()

        for directoryURL in candidateDirectories {
            let catalogURL = directoryURL.appendingPathComponent(bootstrapCatalogFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                return catalogURL
            }
        }

        throw TranslationError.catalogMissing
    }

    private func cachedCatalogURL() throws -> URL {
        try baseDirectoryURL().appendingPathComponent("catalog.json", isDirectory: false)
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

    private func ensureBaseDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: try baseDirectoryURL(),
            withIntermediateDirectories: true
        )
    }

    private func bundledCandidateDirectories() -> [URL] {
        guard let resourceURL = bundle.resourceURL else {
            return []
        }

        return [
            resourceURL.appendingPathComponent("Resource", isDirectory: true),
            resourceURL
        ]
    }

    private static func catalogMetadata(_ catalog: TranslationModelCatalog) -> [String: String] {
        var metadata = [
            "catalog_version": "\(catalog.version)",
            "package_count": "\(catalog.packages.count)"
        ]

        if let generatedAt = catalog.generatedAt?.ISO8601Format() {
            metadata["generated_at"] = generatedAt
        }

        return metadata
    }

    private static func languageMetadata(
        source: HomeLanguage,
        target: HomeLanguage
    ) -> [String: String] {
        [
            "source_language": source.translationModelCode,
            "target_language": target.translationModelCode
        ]
    }

    private static func packageMetadata(_ package: TranslationModelPackage) -> [String: String] {
        [
            "package_id": package.packageId,
            "package_version": package.version,
            "source_language": package.source,
            "target_language": package.target
        ]
    }

    private static func resultMetadata(
        package: TranslationModelPackage?,
        fallbackMetadata: [String: String]
    ) -> [String: String] {
        guard let package else {
            return fallbackMetadata.merging(["result": "not_found"]) { _, newValue in newValue }
        }

        return fallbackMetadata.merging(packageMetadata(package)) { _, newValue in newValue }
    }
}
