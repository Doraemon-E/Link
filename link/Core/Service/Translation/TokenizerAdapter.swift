//
//  TokenizerAdapter.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated protocol TokenizerAdapter {
    func encode(_ text: String, maxLength: Int, eosTokenID: Int) throws -> [Int64]
    func decode(_ tokenIDs: [Int64], eosTokenID: Int, padTokenID: Int) throws -> String
    func debugTokenDescription(_ tokenID: Int64, eosTokenID: Int, padTokenID: Int) -> String
}

nonisolated final class SentencePieceTokenizerAdapter: TokenizerAdapter {
    private struct SentencePieceEntry {
        enum Kind: Int {
            case normal = 1
            case unknown = 2
            case control = 3
            case userDefined = 4
            case unused = 5
            case byte = 6
        }

        let piece: String
        let score: Float
        let kind: Kind
    }

    private struct SentencePieceModel {
        struct Piece {
            let tokenID: Int64
            let score: Float
        }

        let pieces: [String: Piece]
        let maxPieceLength: Int
        let addDummyPrefix: Bool
        let removeExtraWhitespaces: Bool
        let escapeWhitespaces: Bool

        func prepare(_ text: String) -> String {
            var normalized = text

            if removeExtraWhitespaces {
                normalized = normalized
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }

            guard !normalized.isEmpty else {
                return ""
            }

            if addDummyPrefix, !normalized.hasPrefix("▁") {
                normalized = "▁" + normalized
            }

            if escapeWhitespaces {
                normalized = normalized.replacingOccurrences(of: " ", with: "▁")
            }

            return normalized
        }
    }

    private struct ParsedSentencePieceSpec {
        let entries: [SentencePieceEntry]
        let addDummyPrefix: Bool
        let removeExtraWhitespaces: Bool
        let escapeWhitespaces: Bool
    }

    private enum SentencePieceParser {
        static func parseSpec(data: Data) throws -> ParsedSentencePieceSpec {
            var reader = ProtobufReader(data: data)
            var entries: [SentencePieceEntry] = []
            var addDummyPrefix = true
            var removeExtraWhitespaces = true
            var escapeWhitespaces = true

            while let field = try reader.nextField() {
                switch (field.number, field.wireType) {
                case (1, .lengthDelimited):
                    let pieceData = try reader.readLengthDelimited()
                    let entry = try parseSentencePiece(data: pieceData)
                    entries.append(entry)
                case (3, .lengthDelimited):
                    let normalizerData = try reader.readLengthDelimited()
                    let settings = try parseNormalizerSpec(data: normalizerData)
                    addDummyPrefix = settings.addDummyPrefix
                    removeExtraWhitespaces = settings.removeExtraWhitespaces
                    escapeWhitespaces = settings.escapeWhitespaces
                default:
                    try reader.skipField(wireType: field.wireType)
                }
            }

            return ParsedSentencePieceSpec(
                entries: entries,
                addDummyPrefix: addDummyPrefix,
                removeExtraWhitespaces: removeExtraWhitespaces,
                escapeWhitespaces: escapeWhitespaces
            )
        }

        static func parseModel(
            spec: ParsedSentencePieceSpec,
            tokenIDResolver: (String) -> Int?
        ) throws -> SentencePieceModel {
            var pieces: [String: SentencePieceModel.Piece] = [:]
            pieces.reserveCapacity(spec.entries.count)

            for entry in spec.entries where shouldEncode(entry.kind) {
                guard let tokenID = tokenIDResolver(entry.piece) else {
                    continue
                }

                pieces[entry.piece] = SentencePieceModel.Piece(
                    tokenID: Int64(tokenID),
                    score: entry.score
                )
            }

            let maxPieceLength = pieces.keys.map(\.count).max() ?? 1

            return SentencePieceModel(
                pieces: pieces,
                maxPieceLength: maxPieceLength,
                addDummyPrefix: spec.addDummyPrefix,
                removeExtraWhitespaces: spec.removeExtraWhitespaces,
                escapeWhitespaces: spec.escapeWhitespaces
            )
        }

        private static func shouldEncode(_ kind: SentencePieceEntry.Kind) -> Bool {
            switch kind {
            case .normal, .userDefined, .byte:
                return true
            case .unknown, .control, .unused:
                return false
            }
        }

        private static func parseSentencePiece(data: Data) throws -> SentencePieceEntry {
            var reader = ProtobufReader(data: data)
            var piece = ""
            var score: Float = 0
            var kind: SentencePieceEntry.Kind = .normal

            while let field = try reader.nextField() {
                switch (field.number, field.wireType) {
                case (1, .lengthDelimited):
                    piece = try reader.readString()
                case (2, .fixed32):
                    score = try reader.readFloat32()
                case (3, .varint):
                    let rawKind = try Int(reader.readVarint())
                    kind = SentencePieceEntry.Kind(rawValue: rawKind) ?? .normal
                default:
                    try reader.skipField(wireType: field.wireType)
                }
            }

            return SentencePieceEntry(piece: piece, score: score, kind: kind)
        }

        private static func parseNormalizerSpec(data: Data) throws -> (
            addDummyPrefix: Bool,
            removeExtraWhitespaces: Bool,
            escapeWhitespaces: Bool
        ) {
            var reader = ProtobufReader(data: data)
            var addDummyPrefix = true
            var removeExtraWhitespaces = true
            var escapeWhitespaces = true

            while let field = try reader.nextField() {
                switch (field.number, field.wireType) {
                case (3, .varint):
                    addDummyPrefix = try reader.readVarint() != 0
                case (4, .varint):
                    removeExtraWhitespaces = try reader.readVarint() != 0
                case (5, .varint):
                    escapeWhitespaces = try reader.readVarint() != 0
                default:
                    try reader.skipField(wireType: field.wireType)
                }
            }

            return (addDummyPrefix, removeExtraWhitespaces, escapeWhitespaces)
        }
    }

    private struct ProtobufReader {
        enum WireType: UInt64 {
            case varint = 0
            case fixed64 = 1
            case lengthDelimited = 2
            case fixed32 = 5
        }

        struct Field {
            let number: Int
            let wireType: WireType
        }

        private let data: Data
        private var index: Data.Index

        init(data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        var isAtEnd: Bool {
            index >= data.endIndex
        }

        mutating func nextField() throws -> Field? {
            guard !isAtEnd else {
                return nil
            }

            let key = try readVarint()
            guard let wireType = WireType(rawValue: key & 0x07) else {
                throw TranslationError.incompatibleTokenizer("Unsupported protobuf wire type.")
            }

            return Field(number: Int(key >> 3), wireType: wireType)
        }

        mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0

            while !isAtEnd {
                let byte = data[index]
                index = data.index(after: index)

                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return value
                }

                shift += 7
                if shift > 63 {
                    break
                }
            }

            throw TranslationError.incompatibleTokenizer("Invalid protobuf varint.")
        }

        mutating func readLengthDelimited() throws -> Data {
            let length = try Int(readVarint())
            guard length >= 0 else {
                throw TranslationError.incompatibleTokenizer("Invalid protobuf length.")
            }

            let endIndex = data.index(index, offsetBy: length, limitedBy: data.endIndex)
            guard let endIndex else {
                throw TranslationError.incompatibleTokenizer("Unexpected end of protobuf data.")
            }

            let slice = data[index ..< endIndex]
            index = endIndex
            return Data(slice)
        }

        mutating func readString() throws -> String {
            let bytes = try readLengthDelimited()
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw TranslationError.incompatibleTokenizer("Invalid UTF-8 in sentencepiece model.")
            }

            return string
        }

        mutating func readFloat32() throws -> Float {
            let byteCount = 4
            let endIndex = data.index(index, offsetBy: byteCount, limitedBy: data.endIndex)
            guard let endIndex else {
                throw TranslationError.incompatibleTokenizer("Unexpected end of protobuf float.")
            }

            let bytes = [UInt8](data[index ..< endIndex])
            let littleEndian =
                UInt32(bytes[0]) |
                (UInt32(bytes[1]) << 8) |
                (UInt32(bytes[2]) << 16) |
                (UInt32(bytes[3]) << 24)
            let value = Float(bitPattern: littleEndian)
            index = endIndex
            return value
        }

        mutating func skipField(wireType: WireType) throws {
            switch wireType {
            case .varint:
                _ = try readVarint()
            case .fixed64:
                try advance(by: 8)
            case .lengthDelimited:
                _ = try readLengthDelimited()
            case .fixed32:
                try advance(by: 4)
            }
        }

        private mutating func advance(by byteCount: Int) throws {
            let endIndex = data.index(index, offsetBy: byteCount, limitedBy: data.endIndex)
            guard let endIndex else {
                throw TranslationError.incompatibleTokenizer("Unexpected end of protobuf data.")
            }

            index = endIndex
        }
    }

    private let vocabulary: [String: Int]
    private let reverseVocabulary: [Int: String]
    private let unkTokenID: Int
    private let sourceModel: SentencePieceModel

    init(modelDirectoryURL: URL, manifest: TranslationModelManifest) throws {
        do {
            guard manifest.tokenizer.kind == .marianSentencePieceVocabulary else {
                throw TranslationError.incompatibleTokenizer("Unsupported tokenizer kind: \(manifest.tokenizer.kind.rawValue)")
            }

            guard let sourceSentencePieceFile = manifest.tokenizer.sourceSentencePieceFile else {
                throw TranslationError.incompatibleTokenizer("Missing source sentencepiece configuration.")
            }

            guard let vocabularyFile = manifest.tokenizer.vocabularyFile else {
                throw TranslationError.incompatibleTokenizer("Missing tokenizer vocabulary file.")
            }

            let sourceURL = modelDirectoryURL.appendingPathComponent(sourceSentencePieceFile, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw TranslationError.incompatibleTokenizer("Missing source sentencepiece file.")
            }

            if let targetSentencePieceFile = manifest.tokenizer.targetSentencePieceFile {
                let targetURL = modelDirectoryURL.appendingPathComponent(targetSentencePieceFile, isDirectory: false)
                guard FileManager.default.fileExists(atPath: targetURL.path) else {
                    throw TranslationError.incompatibleTokenizer("Missing target sentencepiece file.")
                }
            }

            let vocabularyURL = modelDirectoryURL.appendingPathComponent(vocabularyFile, isDirectory: false)
            let data = try Data(contentsOf: vocabularyURL)
            let decodedVocabulary = try JSONDecoder().decode([String: Int].self, from: data)

            guard let unkTokenID = decodedVocabulary["<unk>"] else {
                throw TranslationError.incompatibleTokenizer("Vocabulary does not contain <unk>.")
            }

            let spec = try SentencePieceParser.parseSpec(data: Data(contentsOf: sourceURL))
            self.vocabulary = decodedVocabulary
            self.reverseVocabulary = Self.makeReverseVocabularyPreservingFirstID(from: decodedVocabulary)
            self.unkTokenID = unkTokenID
            self.sourceModel = try SentencePieceParser.parseModel(
                spec: spec,
                tokenIDResolver: { decodedVocabulary[$0] }
            )
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.incompatibleTokenizer(error.localizedDescription)
        }
    }

    private static func makeReverseVocabularyPreservingFirstID(
        from vocabulary: [String: Int]
    ) -> [Int: String] {
        var reverseVocabulary: [Int: String] = [:]
        reverseVocabulary.reserveCapacity(vocabulary.count)

        for (piece, tokenID) in vocabulary.sorted(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }

            return lhs.value < rhs.value
        }) where reverseVocabulary[tokenID] == nil {
            reverseVocabulary[tokenID] = piece
        }

        return reverseVocabulary
    }


    func encode(_ text: String, maxLength: Int, eosTokenID: Int) throws -> [Int64] {
        let preparedText = sourceModel.prepare(text)

        guard !preparedText.isEmpty else {
            return [Int64(eosTokenID)]
        }

        let characters = Array(preparedText)
        let tokenBudget = max(maxLength - 1, 1)
        let tokenIDs = encodeWithUnigramViterbi(characters).prefix(tokenBudget)
        return Array(tokenIDs) + [Int64(eosTokenID)]
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

    func debugTokenDescription(_ tokenID: Int64, eosTokenID: Int, padTokenID: Int) -> String {
        let rawID = Int(tokenID)

        if rawID == eosTokenID {
            return "<eos>"
        }

        if rawID == padTokenID {
            return "<pad>"
        }

        guard let token = reverseVocabulary[rawID] else {
            return "<missing:\(rawID)>"
        }

        return token
    }

    private func encodeWithUnigramViterbi(_ characters: [Character]) -> [Int64] {
        let length = characters.count
        guard length > 0 else {
            return []
        }

        let unknownPenalty: Float = -100
        var bestScores = Array(repeating: -Float.infinity, count: length + 1)
        var bestPaths = Array<(previousIndex: Int, tokenID: Int64)?>(repeating: nil, count: length + 1)
        bestScores[0] = 0

        for index in 0 ..< length where bestScores[index].isFinite {
            var matched = false
            let candidateLength = min(sourceModel.maxPieceLength, length - index)

            for pieceLength in 1 ... candidateLength {
                let candidate = String(characters[index ..< index + pieceLength])
                guard let piece = sourceModel.pieces[candidate] else {
                    continue
                }

                matched = true
                let endIndex = index + pieceLength
                let score = bestScores[index] + piece.score
                if score > bestScores[endIndex] {
                    bestScores[endIndex] = score
                    bestPaths[endIndex] = (index, piece.tokenID)
                }
            }

            if !matched {
                let endIndex = index + 1
                let score = bestScores[index] + unknownPenalty
                if score > bestScores[endIndex] {
                    bestScores[endIndex] = score
                    bestPaths[endIndex] = (index, Int64(unkTokenID))
                }
            }
        }

        guard bestScores[length].isFinite else {
            return Array(repeating: Int64(unkTokenID), count: length)
        }

        var tokenIDs: [Int64] = []
        var currentIndex = length

        while currentIndex > 0, let path = bestPaths[currentIndex] {
            tokenIDs.append(path.tokenID)
            currentIndex = path.previousIndex
        }

        return tokenIDs.reversed()
    }
}
