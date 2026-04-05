//
//  ModelAssetPresentationMapper.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated struct ModelAssetPresentationMapper: Sendable {
    func translationAsset(from package: TranslationModelPackage) -> ModelAsset {
        let sourceName = SupportedLanguage.fromTranslationModelCode(package.source)?.displayName ?? package.source
        let targetName = SupportedLanguage.fromTranslationModelCode(package.target)?.displayName ?? package.target

        return ModelAsset(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: "\(sourceName) -> \(targetName)",
            subtitle: "翻译模型",
            archiveURL: package.archiveURL,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: package.sha256
        )
    }

    func translationInstalledAsset(from package: TranslationInstalledPackageSummary) -> ModelAsset {
        let sourceName = package.sourceLanguage?.displayName ?? package.packageId
        let targetName = package.targetLanguage?.displayName ?? ""
        let title = package.targetLanguage == nil ? package.packageId : "\(sourceName) -> \(targetName)"

        return ModelAsset(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: title,
            subtitle: "翻译模型",
            archiveURL: placeholderArchiveURL(for: package.packageId),
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: ""
        )
    }

    func speechAsset(from package: SpeechModelPackage) -> ModelAsset {
        ModelAsset(
            kind: .speech,
            packageId: package.packageId,
            version: package.version,
            title: "语音识别",
            subtitle: "Whisper",
            archiveURL: package.archiveURL,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: package.sha256
        )
    }

    func speechInstalledAsset(from package: SpeechInstalledPackageSummary) -> ModelAsset {
        ModelAsset(
            kind: .speech,
            packageId: package.packageId,
            version: package.version,
            title: "语音识别",
            subtitle: "Whisper",
            archiveURL: placeholderArchiveURL(for: package.packageId),
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: ""
        )
    }

    func fallbackAsset(
        kind: ModelAssetKind,
        packageId: String,
        fallbackURL: URL,
        fallbackArchiveSize: Int64?
    ) -> ModelAsset {
        ModelAsset(
            kind: kind,
            packageId: packageId,
            version: "",
            title: packageId,
            subtitle: kind.displayName,
            archiveURL: fallbackURL,
            archiveSize: fallbackArchiveSize ?? 0,
            installedSize: 0,
            sha256: ""
        )
    }

    private func placeholderArchiveURL(for packageId: String) -> URL {
        URL(string: "https://example.invalid/\(packageId).zip")!
    }
}
