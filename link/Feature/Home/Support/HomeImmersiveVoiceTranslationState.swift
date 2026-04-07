//
//  HomeImmersiveVoiceTranslationState.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated enum HomeSpeechCaptureOrigin: Sendable, Equatable {
    case compactMic
    case immersiveWave
}

nonisolated enum HomeImmersiveVoiceTranslationPhase: Sendable, Equatable {
    case listening
    case translating
    case finalizing
}

nonisolated struct HomeImmersiveVoiceTranslationSegment: Sendable, Equatable, Identifiable {
    let id: UUID
    var text: String

    init(
        id: UUID = UUID(),
        text: String
    ) {
        self.id = id
        self.text = text
    }
}

nonisolated struct HomeImmersiveVoiceTranslationState: Sendable, Equatable, Identifiable {
    let messageID: UUID
    var committedSegments: [HomeImmersiveVoiceTranslationSegment]
    var activeText: String
    var phase: HomeImmersiveVoiceTranslationPhase

    var id: UUID {
        messageID
    }
}
