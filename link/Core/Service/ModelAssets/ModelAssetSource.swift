//
//  ModelAssetSource.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated protocol ModelAssetSource: Sendable {
    var kind: ModelAssetKind { get }

    func availableRecords() async throws -> [ModelAssetRecord]
    func installedRecords() async throws -> [ModelAssetRecord]
    func resolveAsset(
        packageId: String,
        fallbackURL: URL?,
        fallbackArchiveSize: Int64?
    ) async throws -> ModelAsset
    func installAsset(packageId: String, archiveURL: URL) async throws
    func removeInstalledAsset(packageId: String) async throws
}

nonisolated struct TranslationModelAssetSource: ModelAssetSource {
    let kind: ModelAssetKind = .translation

    private let packageManager: TranslationModelPackageManager
    private let presentationMapper: ModelAssetPresentationMapper

    init(
        packageManager: TranslationModelPackageManager,
        presentationMapper: ModelAssetPresentationMapper = ModelAssetPresentationMapper()
    ) {
        self.packageManager = packageManager
        self.presentationMapper = presentationMapper
    }

    func availableRecords() async throws -> [ModelAssetRecord] {
        try await packageManager.packages().map {
            ModelAssetRecord.available(asset: presentationMapper.translationAsset(from: $0))
        }
    }

    func installedRecords() async throws -> [ModelAssetRecord] {
        try await packageManager.installedPackages().map {
            ModelAssetRecord.installed(
                asset: presentationMapper.translationInstalledAsset(from: $0),
                installedAt: $0.installedAt
            )
        }
    }

    func resolveAsset(
        packageId: String,
        fallbackURL: URL?,
        fallbackArchiveSize: Int64?
    ) async throws -> ModelAsset {
        if let package = try await packageManager.package(packageId: packageId) {
            return presentationMapper.translationAsset(from: package)
        }

        guard let fallbackURL else {
            throw TranslationError.packageMissing(packageId: packageId)
        }

        return presentationMapper.fallbackAsset(
            kind: kind,
            packageId: packageId,
            fallbackURL: fallbackURL,
            fallbackArchiveSize: fallbackArchiveSize
        )
    }

    func installAsset(packageId: String, archiveURL: URL) async throws {
        _ = try await packageManager.install(packageId: packageId, archiveURL: archiveURL)
    }

    func removeInstalledAsset(packageId: String) async throws {
        try await packageManager.remove(packageId: packageId)
    }
}

nonisolated struct SpeechModelAssetSource: ModelAssetSource {
    let kind: ModelAssetKind = .speech

    private let packageManager: SpeechModelPackageManager
    private let presentationMapper: ModelAssetPresentationMapper

    init(
        packageManager: SpeechModelPackageManager,
        presentationMapper: ModelAssetPresentationMapper = ModelAssetPresentationMapper()
    ) {
        self.packageManager = packageManager
        self.presentationMapper = presentationMapper
    }

    func availableRecords() async throws -> [ModelAssetRecord] {
        try await packageManager.packages().map {
            ModelAssetRecord.available(asset: presentationMapper.speechAsset(from: $0))
        }
    }

    func installedRecords() async throws -> [ModelAssetRecord] {
        try await packageManager.installedPackages().map {
            ModelAssetRecord.installed(
                asset: presentationMapper.speechInstalledAsset(from: $0),
                installedAt: $0.installedAt
            )
        }
    }

    func resolveAsset(
        packageId: String,
        fallbackURL: URL?,
        fallbackArchiveSize: Int64?
    ) async throws -> ModelAsset {
        if let package = try await packageManager.package(packageId: packageId) {
            return presentationMapper.speechAsset(from: package)
        }

        guard let fallbackURL else {
            throw SpeechRecognitionError.packageMissing(packageId)
        }

        return presentationMapper.fallbackAsset(
            kind: kind,
            packageId: packageId,
            fallbackURL: fallbackURL,
            fallbackArchiveSize: fallbackArchiveSize
        )
    }

    func installAsset(packageId: String, archiveURL: URL) async throws {
        _ = try await packageManager.install(packageId: packageId, archiveURL: archiveURL)
    }

    func removeInstalledAsset(packageId: String) async throws {
        try await packageManager.remove(packageId: packageId)
    }
}
