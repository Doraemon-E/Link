//
//  ModelAssetPresentationMapper.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated struct ModelAssetPresentationMapper: Sendable {
    func translationAsset(from package: TranslationModelPackage) -> ModelAsset {
        let supportedLanguageNames = package.supportedLanguages
            .compactMap(SupportedLanguage.fromTranslationModelCode)
            .map(\.displayName)

        return ModelAsset(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: "离线翻译模型",
            subtitle: supportedLanguageNames.isEmpty
                ? "HY-MT"
                : "HY-MT · " + supportedLanguageNames.joined(separator: " / "),
            archiveURL: package.archiveURL,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: package.sha256
        )
    }

    func translationInstalledAsset(from package: TranslationInstalledPackageSummary) -> ModelAsset {
        let subtitle = package.supportedLanguages.isEmpty
            ? "HY-MT"
            : "HY-MT · " + package.supportedLanguages.map(\.displayName).joined(separator: " / ")

        return ModelAsset(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: "离线翻译模型",
            subtitle: subtitle,
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
            title: "语音识别模型",
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
            title: "语音识别模型",
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
