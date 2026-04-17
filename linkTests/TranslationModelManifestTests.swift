//
//  TranslationModelManifestTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/10.
//

import Foundation
import XCTest
@testable import link

final class TranslationModelManifestTests: XCTestCase {
    func testGGUFManifestDecodesWithoutKVCacheConfiguration() throws {
        let payload = """
        {
          "family": "gguf_causal_llm",
          "gguf": {
            "modelFile": "model.gguf"
          },
          "runtime": {
            "contextLength": 4096
          },
          "generation": {
            "maxInputLength": 3072,
            "maxOutputLength": 512
          },
          "supportedLanguages": ["zho", "eng"],
          "promptStyle": "hy_mt_translation_v1"
        }
        """

        let manifest = try JSONDecoder().decode(
            TranslationModelManifest.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(manifest.family, .ggufCausalLLM)
        XCTAssertEqual(manifest.runtime?.contextLength, 4096)
        XCTAssertNil(manifest.runtime?.kvCache)
    }

    func testGGUFManifestDecodesWithKVCacheConfiguration() throws {
        let payload = """
        {
          "family": "gguf_causal_llm",
          "gguf": {
            "modelFile": "model.gguf"
          },
          "runtime": {
            "contextLength": 4096,
            "kvCache": {
              "flashAttention": "auto",
              "typeK": "f16",
              "typeV": "q8_0"
            }
          },
          "generation": {
            "maxInputLength": 3072,
            "maxOutputLength": 512
          },
          "supportedLanguages": ["zho", "eng"],
          "promptStyle": "hy_mt_translation_v1"
        }
        """

        let manifest = try JSONDecoder().decode(
            TranslationModelManifest.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(manifest.runtime?.kvCache?.flashAttention, .auto)
        XCTAssertEqual(manifest.runtime?.kvCache?.typeK, .f16)
        XCTAssertEqual(manifest.runtime?.kvCache?.typeV, .q8_0)
    }

    func testAULlamaRuntimeInitializesHYMTWithQuantizedVCacheWhenModelIsAvailable() throws {
        let modelURL = try hyMTModelURL()
        let runtime = try XCTUnwrap(
            try AULlamaRuntime(
                modelPath: modelURL.path,
                contextLength: 4096,
                flashAttentionMode: .auto,
                typeK: kvCacheType(rawValue: 0),
                typeV: kvCacheType(rawValue: 1)
            )
        )

        XCTAssertNotNil(runtime)
    }

    func testAULlamaRuntimeRejectsIncompatibleQ4KVCacheWhenModelIsAvailable() throws {
        let modelURL = try hyMTModelURL()

        XCTAssertThrowsError(
            try AULlamaRuntime(
                modelPath: modelURL.path,
                contextLength: 4096,
                flashAttentionMode: .auto,
                typeK: kvCacheType(rawValue: 0),
                typeV: kvCacheType(rawValue: 2)
            )
        ) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(
                message.contains("value_length") || message.contains("divisible by 256"),
                "Unexpected error message: \(message)"
            )
        }
    }

    private func hyMTModelURL(filePath: StaticString = #filePath) throws -> URL {
        let testFileURL = URL(fileURLWithPath: "\(filePath)")
        let workspaceRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelURL = workspaceRoot
            .appendingPathComponent("link-model", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("translation", isDirectory: true)
            .appendingPathComponent("quantized", isDirectory: true)
            .appendingPathComponent("hy-mt1.5-1.8b-gguf-q4km", isDirectory: true)
            .appendingPathComponent("model.gguf", isDirectory: false)

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("HY-MT GGUF model not found at \(modelURL.path)")
        }

        return modelURL
    }

    private func kvCacheType(rawValue: Int) -> AULlamaRuntimeKVCacheType {
        guard let value = AULlamaRuntimeKVCacheType(rawValue: rawValue) else {
            XCTFail("Unexpected AULlamaRuntimeKVCacheType raw value \(rawValue)")
            fatalError("Invalid AULlamaRuntimeKVCacheType raw value \(rawValue)")
        }
        return value
    }
}
