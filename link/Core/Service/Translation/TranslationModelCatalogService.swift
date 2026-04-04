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
    private let bundledCatalogURLOverride: URL?
    private let baseDirectoryURLOverride: URL?
    private var inMemoryCatalog: TranslationModelCatalog?

    init(
        remoteCatalogURL: URL? = TranslationModelHostingConfiguration.remoteCatalogURL,
        bootstrapCatalogFileName: String = "translation-catalog.json",
        bundle: Bundle = .main,
        bundledCatalogURLOverride: URL? = nil,
        baseDirectoryURLOverride: URL? = nil
    ) {
        self.remoteCatalogURL = remoteCatalogURL
        self.bootstrapCatalogFileName = bootstrapCatalogFileName
        self.bundle = bundle
        self.bundledCatalogURLOverride = bundledCatalogURLOverride
        self.baseDirectoryURLOverride = baseDirectoryURLOverride
    }

    func warmUpCatalog() async {
        _ = try? await refreshCatalog()
        _ = try? await catalog()
    }

    func catalog() async throws -> TranslationModelCatalog {
        if let inMemoryCatalog {
            return inMemoryCatalog
        }

        let cachedCatalog = try? loadCatalog(at: try cachedCatalogURL())
        let bundledCatalog = try? loadBundledCatalog()

        if let resolvedCatalog = preferredCatalog(candidate: cachedCatalog, baseline: bundledCatalog) {
            inMemoryCatalog = resolvedCatalog

            if cachedCatalog != resolvedCatalog {
                try? saveCatalog(resolvedCatalog)
            }

            return resolvedCatalog
        }

        let resolvedBundledCatalog = try loadBundledCatalog()
        inMemoryCatalog = resolvedBundledCatalog
        return resolvedBundledCatalog
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
        let bundledCatalog = try? loadBundledCatalog()
        let resolvedCatalog = preferredCatalog(candidate: refreshedCatalog, baseline: bundledCatalog)
            ?? refreshedCatalog

        try saveCatalog(resolvedCatalog)
        inMemoryCatalog = resolvedCatalog
        return resolvedCatalog
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

    func packages() async throws -> [TranslationModelPackage] {
        try await catalog().packages
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

    private func saveCatalog(_ catalog: TranslationModelCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try ensureBaseDirectoryExists()
        let data = try encoder.encode(catalog)
        try data.write(to: try cachedCatalogURL(), options: .atomic)
    }

    private func preferredCatalog(
        candidate: TranslationModelCatalog?,
        baseline: TranslationModelCatalog?
    ) -> TranslationModelCatalog? {
        switch (candidate, baseline) {
        case let (.some(candidate), .some(baseline)):
            return shouldPrefer(candidate: candidate, over: baseline) ? candidate : baseline
        case let (.some(candidate), .none):
            return candidate
        case let (.none, .some(baseline)):
            return baseline
        case (.none, .none):
            return nil
        }
    }

    private func shouldPrefer(
        candidate: TranslationModelCatalog,
        over baseline: TranslationModelCatalog
    ) -> Bool {
        if candidate.version != baseline.version {
            return candidate.version > baseline.version
        }

        switch (candidate.generatedAt, baseline.generatedAt) {
        case let (.some(candidateDate), .some(baselineDate)) where candidateDate != baselineDate:
            return candidateDate > baselineDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        return candidate == baseline
    }

    private func bundledCatalogURL() throws -> URL {
        if let bundledCatalogURLOverride {
            return bundledCatalogURLOverride
        }

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
        if let baseDirectoryURLOverride {
            return baseDirectoryURLOverride
        }

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
