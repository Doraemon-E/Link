//
//  SpeechModelDownloadPrompt.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct SpeechModelDownloadPrompt: Identifiable, Equatable, Sendable {
    let packageId: String
    let archiveSize: Int64
    let installedSize: Int64

    init(package: SpeechModelPackage) {
        self.packageId = package.packageId
        self.archiveSize = package.archiveSize
        self.installedSize = package.installedSize
    }

    var id: String {
        packageId
    }

    var title: String {
        "需要下载语音模型"
    }

    var message: String {
        var parts: [String] = []

        if archiveSize > 0 {
            parts.append("使用语音识别前需要先下载语音模型，共\(archiveSize.formattedModelSize)")
        } else {
            parts.append("使用语音识别前需要先下载语音模型")
        }

        if installedSize > 0 {
            parts.append("安装后约占用\(installedSize.formattedModelSize)")
        }

        parts.append("下载支持中断后继续")
        return parts.joined(separator: "，") + "。"
    }
}
