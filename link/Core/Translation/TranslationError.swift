//
//  TranslationError.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum TranslationError: LocalizedError {
    case bundledModelMissing(String)
    case bundledModelNotFound(paths: [String])
    case installationFailed(String)
    case manifestMissing
    case manifestInvalid(String)
    case unsupportedLanguagePair(source: HomeLanguage, target: HomeLanguage)
    case incompatibleTokenizer(String)
    case runtimeInitialization(String)
    case inferenceFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .bundledModelMissing(let detail):
            return "Bundled model missing: \(detail)"
        case .bundledModelNotFound(let paths):
            return "Bundled model not found at fixed paths: \(paths.joined(separator: ", "))"
        case .installationFailed(let detail):
            return "Model installation failed: \(detail)"
        case .manifestMissing:
            return "Translation model manifest is missing."
        case .manifestInvalid(let detail):
            return "Translation model manifest is invalid: \(detail)"
        case .unsupportedLanguagePair(let source, let target):
            return "Unsupported translation direction: \(source.displayName) -> \(target.displayName)"
        case .incompatibleTokenizer(let detail):
            return "Tokenizer is incompatible with the current model: \(detail)"
        case .runtimeInitialization(let detail):
            return "Failed to initialize translation runtime: \(detail)"
        case .inferenceFailed(let detail):
            return "Translation inference failed: \(detail)"
        case .emptyOutput:
            return "Translation produced an empty result."
        }
    }

    var userFacingMessage: String {
        switch self {
        case .unsupportedLanguagePair(let source, let target):
            return "当前模型暂不支持\(source.displayName)到\(target.displayName)的翻译。"
        case .bundledModelMissing, .bundledModelNotFound:
            return "应用内未找到翻译模型资源，请确认模型文件已打包到 App 中。"
        case .installationFailed:
            return "翻译模型安装失败，请稍后重试。"
        case .manifestMissing, .manifestInvalid:
            return "翻译模型配置无效，请检查模型清单文件。"
        case .incompatibleTokenizer:
            return "当前模型分词器暂不兼容，请检查模型资源格式。"
        case .runtimeInitialization:
            return "翻译引擎初始化失败，请检查本地模型文件是否完整。"
        case .inferenceFailed:
            return "翻译失败了，请稍后再试。"
        case .emptyOutput:
            return "模型没有返回可用的译文。"
        }
    }
}
