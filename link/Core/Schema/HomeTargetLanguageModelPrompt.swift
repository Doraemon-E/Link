//
//  HomeTargetLanguageModelPrompt.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

struct HomeTargetLanguageModelPrompt: Identifiable, Equatable, Sendable {
    let targetLanguage: SupportedLanguage

    var id: String {
        targetLanguage.rawValue
    }

    var title: String {
        "还没有\(targetLanguage.displayName)翻译模型"
    }

    var message: String {
        "当前还没有安装任何译成\(targetLanguage.displayName)的翻译模型。前往下载管理后，你可以选择合适的模型并完成下载。"
    }
}
