//
//  LlamaTranslationRuntime.swift
//  link
//
//  Created by Codex on 2026/4/10.
//

import Foundation

final class LlamaTranslationRuntime {
    private nonisolated(unsafe) let runtime: AULlamaRuntime
    private let manifest: TranslationModelManifest

    nonisolated
    init(modelDirectoryURL: URL, manifest: TranslationModelManifest) throws {
        guard manifest.family == .ggufCausalLLM else {
            throw TranslationError.runtimeInitialization("Llama runtime only supports GGUF translation manifests.")
        }

        guard let gguf = manifest.gguf else {
            throw TranslationError.manifestInvalid("GGUF translation manifest is missing gguf.modelFile.")
        }

        let modelURL = modelDirectoryURL.appendingPathComponent(gguf.modelFile, isDirectory: false)
        self.manifest = manifest

        do {
            let kvCache = manifest.runtime?.kvCache
            self.runtime = try AULlamaRuntime(
                modelPath: modelURL.path,
                contextLength: manifest.runtime?.contextLength ?? 4096,
                flashAttentionMode: kvCache?.flashAttention.bridgeMode ?? .disabled,
                typeK: kvCache?.typeK.bridgeType ?? .auF16,
                typeV: kvCache?.typeV.bridgeType ?? .auF16
            )
        } catch {
            throw Self.mapError(
                error,
                fallback: "Unable to initialize llama runtime for \(modelURL.lastPathComponent)."
            )
        }
    }

    nonisolated
    func translate(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)
        let generatedText: String
        do {
            generatedText = try runtime.translatePrompt(
                prompt,
                maxTokens: max(1, manifest.generation.maxOutputLength),
                temperature: samplingConfiguration.temperature,
                topK: samplingConfiguration.topK,
                topP: samplingConfiguration.topP,
                repetitionPenalty: samplingConfiguration.repetitionPenalty
            )
        } catch {
            throw Self.mapError(error, fallback: "llama translation inference failed.")
        }
        let normalizedText = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedText.isEmpty else {
            throw TranslationError.emptyOutput
        }

        return normalizedText
    }

    nonisolated
    private var samplingConfiguration: LlamaSamplingConfiguration {
        LlamaSamplingConfiguration(
            temperature: manifest.generation.temperature ?? 0.7,
            topK: manifest.generation.topK ?? 20,
            topP: manifest.generation.topP ?? 0.6,
            repetitionPenalty: manifest.generation.repetitionPenalty ?? 1.05
        )
    }

    nonisolated
    private func buildPrompt(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> String {
        switch manifest.promptStyle {
        case nil, "hy_mt_translation_v1":
            return Self.buildHYMTTranslationPrompt(text: text, source: source, target: target)
        case let style?:
            return """
            Translate the following segment into \(target.englishName), without additional explanation.

            \(text)

            [prompt_style=\(style)]
            """
        }
    }

    nonisolated
    private static func buildHYMTTranslationPrompt(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> String {
        if source == .chinese || target == .chinese {
            return """
            将以下文本翻译为\(target.chinesePromptName)，注意只需要输出翻译后的结果，不要额外解释：

            \(text)
            """
        }

        return """
        Translate the following segment into \(target.englishName), without additional explanation.

        \(text)
        """
    }
    
    nonisolated
    private static func mapError(_ error: Error, fallback: String) -> TranslationError {
        let nsError = error as NSError
        let message = nsError.localizedDescription.isEmpty ? fallback : nsError.localizedDescription

        if nsError.domain == AULlamaRuntimeErrorDomain,
           nsError.code == 1 {
            return .runtimeInitialization(message)
        }

        return .inferenceFailed(message)
    }
}

private struct LlamaSamplingConfiguration: Sendable {
    let temperature: Double
    let topK: Int
    let topP: Double
    let repetitionPenalty: Double
}

private extension SupportedLanguage {
    nonisolated
    var englishName: String {
        switch self {
        case .chinese:
            return "Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .russian:
            return "Russian"
        case .spanish:
            return "Spanish"
        case .italian:
            return "Italian"
        }
    }

    nonisolated
    var chinesePromptName: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "英语"
        case .japanese:
            return "日语"
        case .korean:
            return "韩语"
        case .french:
            return "法语"
        case .german:
            return "德语"
        case .russian:
            return "俄语"
        case .spanish:
            return "西班牙语"
        case .italian:
            return "意大利语"
        }
    }
}

private extension TranslationModelManifest.Runtime.KVCache.FlashAttention {
    nonisolated
    var bridgeMode: AULlamaRuntimeFlashAttentionMode {
        switch self {
        case .auto:
            return .auto
        case .disabled:
            return .disabled
        }
    }
}

private extension TranslationModelManifest.Runtime.KVCache.TensorType {
    nonisolated
    var bridgeType: AULlamaRuntimeKVCacheType {
        switch self {
        case .f16:
            return .auF16
        case .q8_0:
            return .auQ80
        case .q4_k:
            return .auQ4K
        }
    }
}

private extension AULlamaRuntimeKVCacheType {
    nonisolated
    static var auF16: Self {
        guard let value = Self(rawValue: 0) else {
            preconditionFailure("Missing AULlamaRuntimeKVCacheType raw value 0")
        }
        return value
    }

    nonisolated
    static var auQ80: Self {
        guard let value = Self(rawValue: 1) else {
            preconditionFailure("Missing AULlamaRuntimeKVCacheType raw value 1")
        }
        return value
    }

    nonisolated
    static var auQ4K: Self {
        guard let value = Self(rawValue: 2) else {
            preconditionFailure("Missing AULlamaRuntimeKVCacheType raw value 2")
        }
        return value
    }
}
