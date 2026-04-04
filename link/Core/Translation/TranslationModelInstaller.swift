//
//  TranslationModelInstaller.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct TranslationModelInstallation {
    let manifest: TranslationModelManifest
    let modelDirectoryURL: URL
}

final class TranslationModelInstaller {
    private let bundledModelDirectoryName: String
    private let manifestFileName: String
    private let bundle: Bundle

    init(
        bundledModelDirectoryName: String = "opus-mt-zh-en-onnx",
        manifestFileName: String = "translation-manifest.json",
        bundle: Bundle = .main
    ) {
        self.bundledModelDirectoryName = bundledModelDirectoryName
        self.manifestFileName = manifestFileName
        self.bundle = bundle
    }

    func prepareModel() throws -> TranslationModelInstallation {
        let bundledManifestURL = try bundledManifestURL()
        let bundledManifest = try loadManifest(at: bundledManifestURL)
        let destinationDirectoryURL = try installedModelDirectoryURL()

        try ensureDirectoryExists(at: destinationDirectoryURL)
        try copyBundledModelIfNeeded(
            using: bundledManifest,
            bundledManifestURL: bundledManifestURL,
            to: destinationDirectoryURL
        )

        let manifestURL = destinationDirectoryURL.appendingPathComponent(manifestFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw TranslationError.manifestMissing
        }

        let manifest = try loadManifest(at: manifestURL)
        return TranslationModelInstallation(
            manifest: manifest,
            modelDirectoryURL: destinationDirectoryURL
        )
    }

    private func bundledManifestURL() throws -> URL {
        let candidateDirectories = bundledCandidateDirectories()
        var checkedPaths: [String] = []

        for directoryURL in candidateDirectories {
            let manifestURL = directoryURL.appendingPathComponent(manifestFileName, isDirectory: false)
            checkedPaths.append(manifestURL.path)

            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
        }

        throw TranslationError.bundledModelNotFound(paths: checkedPaths)
    }

    private func installedModelDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw TranslationError.installationFailed("Unable to locate Application Support directory.")
        }

        return applicationSupportURL
            .appendingPathComponent("TranslationModels", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func copyBundledModelIfNeeded(
        using manifest: TranslationModelManifest,
        bundledManifestURL: URL,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let manifestDirectoryURL = bundledManifestURL.deletingLastPathComponent()

        let bundledFiles = [manifestFileName] + manifest.requiredFileNames

        for fileName in bundledFiles {
            let sourceFileURL = try resolveBundledFileURL(
                named: fileName,
                preferredDirectory: manifestDirectoryURL
            )
            let destinationFileURL = destinationURL.appendingPathComponent(fileName, isDirectory: false)

            guard !fileManager.fileExists(atPath: destinationFileURL.path) else {
                continue
            }

            do {
                try fileManager.copyItem(at: sourceFileURL, to: destinationFileURL)
            } catch {
                throw TranslationError.installationFailed("Failed to copy \(fileName): \(error.localizedDescription)")
            }
        }
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

    private func resolveBundledFileURL(named fileName: String, preferredDirectory: URL) throws -> URL {
        let preferredURL = preferredDirectory.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        for directoryURL in bundledCandidateDirectories() {
            let candidateURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        throw TranslationError.bundledModelMissing(fileName)
    }

    private func bundledCandidateDirectories() -> [URL] {
        guard let resourceURL = bundle.resourceURL else {
            return []
        }

        return [
            resourceURL.appendingPathComponent("Resource", isDirectory: true)
                .appendingPathComponent(bundledModelDirectoryName, isDirectory: true),
            resourceURL.appendingPathComponent(bundledModelDirectoryName, isDirectory: true),
            resourceURL
        ]
    }
}
