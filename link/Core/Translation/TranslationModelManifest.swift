//
//  TranslationModelManifest.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct TranslationModelManifest: Decodable {
    enum Family: String, Decodable {
        case marian
    }

    struct LanguagePair: Decodable {
        let source: String
        let target: String
    }

    struct Tokenizer: Decodable {
        enum Kind: String, Decodable {
            case marianSentencePieceVocabulary = "marian_sentencepiece_vocabulary"
        }

        let kind: Kind
        let vocabularyFile: String
        let sourceSentencePieceFile: String?
        let targetSentencePieceFile: String?
    }

    struct ONNXFiles: Decodable {
        let encoder: String
        let decoder: String
        let decoderWithPast: String?
    }

    struct Generation: Decodable {
        let maxInputLength: Int
        let maxOutputLength: Int
        let bosTokenId: Int
        let eosTokenId: Int
        let padTokenId: Int
        let decoderStartTokenId: Int
    }

    struct TensorNames: Decodable {
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

    func supports(source: HomeLanguage, target: HomeLanguage) -> Bool {
        supportedLanguagePairs.contains {
            $0.source == source.translationModelCode && $0.target == target.translationModelCode
        }
    }

    var requiredFileNames: [String] {
        var fileNames = [
            tokenizer.vocabularyFile,
            onnxFiles.encoder,
            onnxFiles.decoder
        ]

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
