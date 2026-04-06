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

nonisolated struct HomeImmersiveVoiceTranslationState: Sendable, Equatable, Identifiable {
    let messageID: UUID
    var translatedText: String
    var phase: HomeImmersiveVoiceTranslationPhase

    var id: UUID {
        messageID
    }
}
