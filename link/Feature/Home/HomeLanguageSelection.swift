//
//  HomeLanguageSelection.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct HomeLanguageDownloadPrompt: Identifiable, Equatable, Sendable {
    let packageId: String
    let sourceLanguage: HomeLanguage
    let targetLanguage: HomeLanguage
    let archiveSize: Int64
    let installedSize: Int64

    var id: String { packageId }

    var title: String {
        "下载\(sourceLanguage.displayName)到\(targetLanguage.displayName)模型"
    }

    var message: String {
        var parts: [String] = []

        if archiveSize > 0 {
            parts.append("需要下载\(archiveSize.formattedModelSize)")
        } else {
            parts.append("需要下载对应的离线翻译模型")
        }

        if installedSize > 0 {
            parts.append("安装后约占用\(installedSize.formattedModelSize)")
        }

        parts.append("下载仅在 Wi-Fi 下进行")
        return parts.joined(separator: "，") + "。"
    }
}

enum HomeLanguageSelectionResolution: Equatable, Sendable {
    case ready
    case requiresDownload(HomeLanguageDownloadPrompt)
    case failure(String)
}

private extension Int64 {
    var formattedModelSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
