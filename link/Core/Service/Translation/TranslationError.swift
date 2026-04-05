//
//  TranslationError.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum TranslationError: LocalizedError {
    case installationFailed(String)
    case manifestMissing
    case manifestInvalid(String)
    case unsupportedLanguagePair(source: SupportedLanguage, target: SupportedLanguage)
    case modelPackageUnavailable(source: SupportedLanguage, target: SupportedLanguage)
    case modelNotInstalled(source: SupportedLanguage, target: SupportedLanguage)
    case packageMissing(packageId: String)
    case catalogMissing
    case catalogInvalid(String)
    case catalogUnavailable
    case downloadFailed(String)
    case integrityCheckFailed
    case extractionFailed(String)
    case incompatibleTokenizer(String)
    case runtimeInitialization(String)
    case inferenceFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .installationFailed(let detail):
            return "Model installation failed: \(detail)"
        case .manifestMissing:
            return "Translation model manifest is missing."
        case .manifestInvalid(let detail):
            return "Translation model manifest is invalid: \(detail)"
        case .unsupportedLanguagePair(let source, let target):
            return "Unsupported translation direction: \(source.displayName) -> \(target.displayName)"
        case .modelPackageUnavailable(let source, let target):
            return "No package is available for \(source.displayName) -> \(target.displayName)."
        case .modelNotInstalled(let source, let target):
            return "The package for \(source.displayName) -> \(target.displayName) is not installed."
        case .packageMissing(let packageId):
            return "Package metadata is missing for \(packageId)."
        case .catalogMissing:
            return "Translation model catalog is missing."
        case .catalogInvalid(let detail):
            return "Translation model catalog is invalid: \(detail)"
        case .catalogUnavailable:
            return "Translation model catalog is unavailable."
        case .downloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .integrityCheckFailed:
            return "Downloaded model archive failed the integrity check."
        case .extractionFailed(let detail):
            return "Failed to extract the downloaded model archive: \(detail)"
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
        case .modelPackageUnavailable(let source, let target):
            return "暂不支持下载\(source.displayName)到\(target.displayName)的翻译模型。"
        case .modelNotInstalled(let source, let target):
            return "\(source.displayName)到\(target.displayName)的模型还没有下载，请先点击右上角下载按钮或在语言选择里完成下载。"
        case .packageMissing:
            return "找不到对应的模型包配置，请刷新模型目录后再试。"
        case .catalogMissing, .catalogInvalid, .catalogUnavailable:
            return "模型目录暂时不可用，请稍后重试。"
        case .downloadFailed(let detail):
            return userFacingFailureMessage(
                prefix: "模型下载失败",
                detail: detail,
                fallback: "请检查网络后重试。"
            )
        case .integrityCheckFailed:
            return "下载的模型校验失败，请重新下载。"
        case .extractionFailed(let detail):
            return userFacingFailureMessage(
                prefix: "模型解压失败",
                detail: detail,
                fallback: "请重新下载或检查模型包结构。"
            )
        case .installationFailed(let detail):
            return userFacingFailureMessage(
                prefix: "翻译模型安装失败",
                detail: detail,
                fallback: "请稍后重试。"
            )
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

private extension TranslationError {
    func userFacingFailureMessage(
        prefix: String,
        detail: String,
        fallback: String
    ) -> String {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDetail.isEmpty else {
            return "\(prefix)，\(fallback)"
        }

        return "\(prefix)：\(normalizedDetail)"
    }
}
