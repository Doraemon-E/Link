//
//  HomeLanguageSelection.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct HomeLanguageDownloadPrompt: Identifiable, Equatable, Sendable {
    let packageIds: [String]
    let sourceLanguage: HomeLanguage
    let targetLanguage: HomeLanguage
    let archiveSize: Int64
    let installedSize: Int64

    init(route: TranslationRoute) {
        let missingSteps = route.missingSteps
        self.packageIds = missingSteps.map(\.packageId)
        self.sourceLanguage = route.source
        self.targetLanguage = route.target
        self.archiveSize = missingSteps.reduce(0) { $0 + $1.archiveSize }
        self.installedSize = missingSteps.reduce(0) { $0 + $1.installedSize }
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

enum HomeLanguageSelectionResolution: Equatable, Sendable {
    case ready
    case requiresDownload(HomeLanguageDownloadPrompt)
    case failure(String)
}

extension Int64 {
    var formattedModelSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
