//
//  TranslationModelCatalogService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum TranslationModelHostingConfiguration {
    static let remoteCatalogURL = URL(string: "https://link.hackerapp.site/link/translation/translation-catalog.json")
}

actor TranslationModelCatalogService {
    private let remoteCatalogURL: URL?
    private let bootstrapCatalogFileName: String
    private let bundle: Bundle
    private var inMemoryCatalog: TranslationModelCatalog?

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
        _ = try? await refreshCatalog()
        _ = try? await catalog()
    }

    func catalog() async throws -> TranslationModelCatalog {
        if let inMemoryCatalog {
            return inMemoryCatalog
        }

        if let cachedCatalog = try? loadCatalog(at: try cachedCatalogURL()) {
            inMemoryCatalog = cachedCatalog
            return cachedCatalog
        }

        let bundledCatalog = try loadBundledCatalog()
        inMemoryCatalog = bundledCatalog
        return bundledCatalog
    }

    func refreshCatalog() async throws -> TranslationModelCatalog {
        guard let remoteCatalogURL else {
            return try await catalog()
        }

        let (data, response) = try await URLSession.shared.data(from: remoteCatalogURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode else {
            throw TranslationError.catalogUnavailable
        }

        let refreshedCatalog = try decodeCatalog(from: data)
        try ensureBaseDirectoryExists()
        try data.write(to: try cachedCatalogURL(), options: .atomic)
        inMemoryCatalog = refreshedCatalog
        return refreshedCatalog
    }

    func package(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationModelPackage? {
        let currentCatalog = try await catalog()
        if let package = currentCatalog.package(source: source, target: target) {
            return package
        }

        if let refreshedCatalog = try? await refreshCatalog() {
            return refreshedCatalog.package(source: source, target: target)
        }

        return nil
    }

    func package(packageId: String) async throws -> TranslationModelPackage? {
        let currentCatalog = try await catalog()
        if let package = currentCatalog.package(packageId: packageId) {
            return package
        }

        if let refreshedCatalog = try? await refreshCatalog() {
            return refreshedCatalog.package(packageId: packageId)
        }

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
}
