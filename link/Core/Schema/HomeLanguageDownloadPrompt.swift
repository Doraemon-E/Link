//
//  HomeLanguageDownloadPrompt.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct HomeLanguageDownloadPrompt: Identifiable, Equatable, Sendable {
    let packageIds: [String]
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let archiveSize: Int64
    let installedSize: Int64

    init(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        requirement: TranslationAssetRequirement
    ) {
        self.packageIds = requirement.packageIds
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.archiveSize = requirement.archiveSize
        self.installedSize = requirement.installedSize
    }

    var id: String {
        "\(sourceLanguage.rawValue)-\(targetLanguage.rawValue)-\(packageIds.joined(separator: "|"))"
    }

    var title: String {
        "需要下载语言包"
    }

    var message: String {
        var parts: [String] = []

        if archiveSize > 0 {
            parts.append("\(sourceLanguage.displayName)到\(targetLanguage.displayName)需要先下载语言包，共\(archiveSize.formattedModelSize)")
        } else {
            parts.append("\(sourceLanguage.displayName)到\(targetLanguage.displayName)需要先下载语言包")
        }

        if installedSize > 0 {
            parts.append("安装后约占用\(installedSize.formattedModelSize)")
        }

        parts.append("下载支持中断后继续")
        return parts.joined(separator: "，") + "。"
    }
}

extension Int64 {
    var formattedModelSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
