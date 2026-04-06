//
//  HomePlaybackState.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

enum HomePlaybackKind: Equatable {
    case translatedTTS
    case sourceTTS
    case sourceRecording

    var isTextToSpeech: Bool {
        switch self {
        case .translatedTTS, .sourceTTS:
            return true
        case .sourceRecording:
            return false
        }
    }
}

struct HomePlaybackState: Equatable {
    let messageID: UUID
    let kind: HomePlaybackKind
}
