//
//  TokenizerAdapter.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

protocol TokenizerAdapter {
    func encode(_ text: String, maxLength: Int, eosTokenID: Int) throws -> [Int64]
    func decode(_ tokenIDs: [Int64], eosTokenID: Int, padTokenID: Int) throws -> String
}

final class MarianSentencePieceTokenizerAdapter: TokenizerAdapter {
    private let vocabulary: [String: Int]
    private let reverseVocabulary: [Int: String]
    private let unkTokenID: Int
    private let maxPieceLength: Int

    init(modelDirectoryURL: URL, manifest: TranslationModelManifest) throws {
        guard manifest.tokenizer.kind == .marianSentencePieceVocabulary else {
            throw TranslationError.incompatibleTokenizer("Unsupported tokenizer kind.")
        }

        if let sourceSentencePieceFile = manifest.tokenizer.sourceSentencePieceFile {
            let sourceURL = modelDirectoryURL.appendingPathComponent(sourceSentencePieceFile, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw TranslationError.incompatibleTokenizer("Missing source sentencepiece file.")
            }
        }

        if let targetSentencePieceFile = manifest.tokenizer.targetSentencePieceFile {
            let targetURL = modelDirectoryURL.appendingPathComponent(targetSentencePieceFile, isDirectory: false)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                throw TranslationError.incompatibleTokenizer("Missing target sentencepiece file.")
            }
        }

        let vocabularyURL = modelDirectoryURL.appendingPathComponent(
            manifest.tokenizer.vocabularyFile,
            isDirectory: false
        )

        do {
            let data = try Data(contentsOf: vocabularyURL)
            let decodedVocabulary = try JSONDecoder().decode([String: Int].self, from: data)

            guard let unkTokenID = decodedVocabulary["<unk>"] else {
                throw TranslationError.incompatibleTokenizer("Vocabulary does not contain <unk>.")
            }

            self.vocabulary = decodedVocabulary
            self.reverseVocabulary = Dictionary(uniqueKeysWithValues: decodedVocabulary.map { ($1, $0) })
            self.unkTokenID = unkTokenID
            self.maxPieceLength = decodedVocabulary.keys.map(\.count).max() ?? 1
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.incompatibleTokenizer(error.localizedDescription)
        }
    }

    func encode(_ text: String, maxLength: Int, eosTokenID: Int) throws -> [Int64] {
        let normalized = normalize(text)

        guard !normalized.isEmpty else {
            return [Int64(eosTokenID)]
        }

        let preparedText = "▁" + normalized.replacingOccurrences(of: " ", with: "▁")
        let characters = Array(preparedText)
        let tokenBudget = max(maxLength - 1, 1)

        var tokenIDs: [Int64] = []
        var index = 0

        while index < characters.count && tokenIDs.count < tokenBudget {
            let remainingCount = characters.count - index
            let candidateLength = min(maxPieceLength, remainingCount)

            var matchedID: Int?
            var matchedLength = 0

            for length in stride(from: candidateLength, through: 1, by: -1) {
                let candidate = String(characters[index ..< index + length])
                if let tokenID = vocabulary[candidate] {
                    matchedID = tokenID
                    matchedLength = length
                    break
                }
            }

            if let matchedID {
                tokenIDs.append(Int64(matchedID))
                index += matchedLength
            } else {
                tokenIDs.append(Int64(unkTokenID))
                index += 1
            }
        }

        tokenIDs.append(Int64(eosTokenID))
        return tokenIDs
    }

    func decode(_ tokenIDs: [Int64], eosTokenID: Int, padTokenID: Int) throws -> String {
        let decodedPieces = tokenIDs.compactMap { rawTokenID -> String? in
            let tokenID = Int(rawTokenID)

            guard tokenID != eosTokenID, tokenID != padTokenID else {
                return nil
            }

            guard let token = reverseVocabulary[tokenID] else {
                return nil
            }

            switch token {
            case "<unk>":
                return nil
            case "</s>", "<pad>":
                return nil
            default:
                return token
            }
        }

        let sentence = decodedPieces
            .joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sentence
    }

    private func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
