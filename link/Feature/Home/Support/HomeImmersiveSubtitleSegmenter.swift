//
//  HomeImmersiveSubtitleSegmenter.swift
//  link
//
//  Created by Codex on 2026/4/7.
//

import Foundation

nonisolated struct HomeImmersiveSubtitleSegmentationResult: Sendable, Equatable {
    let committedSegments: [String]
    let activeText: String
}

nonisolated enum HomeImmersiveSubtitleSegmenter {
    private static let sentenceEndingCharacters: Set<Character> = [
        "。",
        "！",
        "？",
        ".",
        "!",
        "?"
    ]

    private static let trailingSentenceClosers: Set<Character> = [
        "\"",
        "'",
        ")",
        "]",
        "}",
        "”",
        "’",
        "）",
        "】",
        "」",
        "』"
    ]

    static func segment(
        text: String,
        flushActiveText: Bool
    ) -> HomeImmersiveSubtitleSegmentationResult {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return HomeImmersiveSubtitleSegmentationResult(
                committedSegments: [],
                activeText: ""
            )
        }

        let characters = Array(normalizedText)
        var committedSegments: [String] = []
        var currentCharacters: [Character] = []
        currentCharacters.reserveCapacity(characters.count)
        var hasPendingSentenceEnding = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if hasPendingSentenceEnding,
               !character.isWhitespaceOrNewline,
               !trailingSentenceClosers.contains(character) {
                commitCurrentCharacters(into: &committedSegments, currentCharacters: &currentCharacters)
                hasPendingSentenceEnding = false
            }

            currentCharacters.append(character)

            if sentenceEndingCharacters.contains(character) {
                hasPendingSentenceEnding = true
            }

            index += 1
        }

        if hasPendingSentenceEnding {
            commitCurrentCharacters(into: &committedSegments, currentCharacters: &currentCharacters)
        }

        let activeText = String(currentCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard flushActiveText, !activeText.isEmpty else {
            return HomeImmersiveSubtitleSegmentationResult(
                committedSegments: committedSegments,
                activeText: activeText
            )
        }

        committedSegments.append(activeText)
        return HomeImmersiveSubtitleSegmentationResult(
            committedSegments: committedSegments,
            activeText: ""
        )
    }

    private static func commitCurrentCharacters(
        into committedSegments: inout [String],
        currentCharacters: inout [Character]
    ) {
        let segment = String(currentCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else {
            currentCharacters.removeAll(keepingCapacity: true)
            return
        }

        committedSegments.append(segment)
        currentCharacters.removeAll(keepingCapacity: true)
    }
}

private nonisolated extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
