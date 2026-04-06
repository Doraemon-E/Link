//
//  TranslationModelManifest.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct TranslationModelManifest: Codable, Sendable {
    nonisolated enum Family: String, Codable, Sendable {
        case marian
    }

    nonisolated struct LanguagePair: Codable, Sendable {
        let source: String
        let target: String
    }

    nonisolated struct Tokenizer: Codable, Sendable {
        nonisolated enum Kind: String, Codable, Sendable {
            case marianSentencePieceVocabulary = "marian_sentencepiece_vocabulary"
        }

        let kind: Kind
        let vocabularyFile: String?
        let sourceSentencePieceFile: String?
        let targetSentencePieceFile: String?
    }

    nonisolated struct ONNXFiles: Codable, Sendable {
        let encoder: String
        let decoder: String
        let decoderWithPast: String?
    }

    nonisolated struct Generation: Codable, Sendable {
        let maxInputLength: Int
        let maxOutputLength: Int
        let bosTokenId: Int
        let eosTokenId: Int
        let padTokenId: Int // 统一使用 padTokenId 来表示填充标记的 ID，保持张量的形状一致
        let decoderStartTokenId: Int // 用于指定解码器的起始标记 ID，作为启动信号
        let suppressedTokenIds: [Int]? // 禁止某个特殊符号在翻译结果中出现，例如 unkTokenId 
    }

    // 映射不同来源的ONNX模型的张量名，保持一致性
    nonisolated struct TensorNames: Codable, Sendable {
        let encoderInputIDs: String
        let encoderAttentionMask: String
        let encoderOutput: String
        let decoderInputIDs: String
        let decoderEncoderAttentionMask: String
        let decoderEncoderHiddenStates: String
        let decoderOutputLogits: String
    }

    let family: Family
    let tokenizer: Tokenizer
    let onnxFiles: ONNXFiles
    let generation: Generation
    let tensorNames: TensorNames
    let supportedLanguagePairs: [LanguagePair]

    func supports(source: SupportedLanguage, target: SupportedLanguage) -> Bool {
        supportedLanguagePairs.contains {
            $0.source == source.translationModelCode && $0.target == target.translationModelCode
        }
    }

    var requiredFileNames: [String] {
        var fileNames = [
            onnxFiles.encoder,
            onnxFiles.decoder
        ]

        if let vocabularyFile = tokenizer.vocabularyFile {
            fileNames.append(vocabularyFile)
        }

        if let sourceSentencePieceFile = tokenizer.sourceSentencePieceFile {
            fileNames.append(sourceSentencePieceFile)
        }

        if let targetSentencePieceFile = tokenizer.targetSentencePieceFile {
            fileNames.append(targetSentencePieceFile)
        }

        if let decoderWithPast = onnxFiles.decoderWithPast {
            fileNames.append(decoderWithPast)
        }

        return fileNames
    }
}
