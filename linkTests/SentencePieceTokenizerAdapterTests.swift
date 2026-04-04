//
//  SentencePieceTokenizerAdapterTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class SentencePieceTokenizerAdapterTests: XCTestCase {
    func testMT5TokenizerInitializesWhenSentencePieceContainsDuplicatePieces() throws {
        let modelDirectoryURL = repositoryRootURL()
            .appendingPathComponent("link-model/models/mt5-small-en-ja-onnx", isDirectory: true)
        let sentencePieceURL = modelDirectoryURL.appendingPathComponent("spiece.model", isDirectory: false)

        guard FileManager.default.fileExists(atPath: sentencePieceURL.path) else {
            throw XCTSkip("Missing mt5 sentencepiece fixture at \(sentencePieceURL.path)")
        }

        let manifest = TranslationModelManifest(
            family: .mt5,
            tokenizer: .init(
                kind: .sentencePiece,
                vocabularyFile: nil,
                sourceSentencePieceFile: nil,
                targetSentencePieceFile: nil,
                sentencePieceFile: "spiece.model",
                extraIds: 100
            ),
            onnxFiles: .init(
                encoder: "encoder_model.onnx",
                decoder: "decoder_model.onnx",
                decoderWithPast: nil
            ),
            generation: .init(
                maxInputLength: 128,
                maxOutputLength: 128,
                bosTokenId: 0,
                eosTokenId: 1,
                padTokenId: 0,
                decoderStartTokenId: 0,
                suppressedTokenIds: []
            ),
            tensorNames: .init(
                encoderInputIDs: "input_ids",
                encoderAttentionMask: "attention_mask",
                encoderOutput: "last_hidden_state",
                decoderInputIDs: "input_ids",
                decoderEncoderAttentionMask: "encoder_attention_mask",
                decoderEncoderHiddenStates: "encoder_hidden_states",
                decoderOutputLogits: "logits"
            ),
            supportedLanguagePairs: [
                .init(source: "eng", target: "jpn")
            ]
        )

        let tokenizer = try SentencePieceTokenizerAdapter(
            modelDirectoryURL: modelDirectoryURL,
            manifest: manifest
        )
        let tokenIDs = try tokenizer.encode(
            "translate English to Japanese: Hello.",
            maxLength: 32,
            eosTokenID: manifest.generation.eosTokenId
        )

        XCTAssertFalse(tokenIDs.isEmpty)
    }

    func testMT5TokenizerDropsExtraIDTokensDuringDecode() throws {
        let modelDirectoryURL = repositoryRootURL()
            .appendingPathComponent("link-model/models/mt5-small-en-ja-onnx", isDirectory: true)
        let sentencePieceURL = modelDirectoryURL.appendingPathComponent("spiece.model", isDirectory: false)

        guard FileManager.default.fileExists(atPath: sentencePieceURL.path) else {
            throw XCTSkip("Missing mt5 sentencepiece fixture at \(sentencePieceURL.path)")
        }

        let manifest = TranslationModelManifest(
            family: .mt5,
            tokenizer: .init(
                kind: .sentencePiece,
                vocabularyFile: nil,
                sourceSentencePieceFile: nil,
                targetSentencePieceFile: nil,
                sentencePieceFile: "spiece.model",
                extraIds: 0
            ),
            onnxFiles: .init(
                encoder: "encoder_model.onnx",
                decoder: "decoder_model.onnx",
                decoderWithPast: nil
            ),
            generation: .init(
                maxInputLength: 128,
                maxOutputLength: 128,
                bosTokenId: 0,
                eosTokenId: 1,
                padTokenId: 0,
                decoderStartTokenId: 0,
                suppressedTokenIds: []
            ),
            tensorNames: .init(
                encoderInputIDs: "input_ids",
                encoderAttentionMask: "attention_mask",
                encoderOutput: "last_hidden_state",
                decoderInputIDs: "input_ids",
                decoderEncoderAttentionMask: "encoder_attention_mask",
                decoderEncoderHiddenStates: "encoder_hidden_states",
                decoderOutputLogits: "logits"
            ),
            supportedLanguagePairs: [
                .init(source: "eng", target: "jpn")
            ]
        )

        let tokenizer = try SentencePieceTokenizerAdapter(
            modelDirectoryURL: modelDirectoryURL,
            manifest: manifest
        )
        let decoded = try tokenizer.decode(
            [250099],
            eosTokenID: manifest.generation.eosTokenId,
            padTokenID: manifest.generation.padTokenId
        )

        XCTAssertEqual(decoded, "")
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
