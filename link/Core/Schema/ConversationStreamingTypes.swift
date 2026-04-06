//
//  ConversationStreamingTypes.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum ConversationStreamingEvent: Sendable, Equatable {
    case state(TranslationStreamingState)
    case completed(messageID: UUID, text: String)
}

nonisolated struct LiveUtteranceState: Sendable, Equatable {
    var stableTranscript: String = ""
    var provisionalTranscript: String = ""
    var liveTranscript: String = ""
    var detectedLanguage: SupportedLanguage?
    var transcriptRevision: Int = 0
    var isEndpoint: Bool = false

    var fullTranscript: String {
        let transcript = stableTranscript + provisionalTranscript + liveTranscript
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? transcript : normalized
    }

    var unstableTranscript: String {
        provisionalTranscript + liveTranscript
    }

    var hasProvisionalTranscript: Bool {
        !provisionalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasLiveTranscript: Bool {
        !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasUnstableTranscript: Bool {
        hasProvisionalTranscript || hasLiveTranscript
    }
}

nonisolated enum LiveSpeechTranscriptionEvent: Sendable, Equatable {
    case state(LiveUtteranceState)
    case completed(LiveUtteranceState)
}

nonisolated enum ConversationStreamingCoordinatorError: LocalizedError, Equatable {
    case liveSpeechNotAvailable

    var errorDescription: String? {
        switch self {
        case .liveSpeechNotAvailable:
            return "Live speech transcription is not available in the current build."
        }
    }
}
