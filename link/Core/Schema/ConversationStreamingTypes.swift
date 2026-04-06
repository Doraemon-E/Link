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
    var stableTranslation: String = ""
    var unstableTranslation: String = ""
    var displayTranslation: String = ""
    var detectedLanguage: SupportedLanguage?
    var transcriptRevision: Int = 0
    var translationRevision: Int = 0
    var isEndpoint: Bool = false

    var fullTranscript: String {
        let transcript = stableTranscript + provisionalTranscript + liveTranscript
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? transcript : normalized
    }

    var unstableTranscript: String {
        provisionalTranscript + liveTranscript
    }

    var effectiveTranslation: String {
        let preferredTranslation = displayTranslation.isEmpty ? stableTranslation : displayTranslation
        let normalized = preferredTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? preferredTranslation : normalized
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

    var hasUnstableTranslation: Bool {
        !unstableTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDisplayTranslationBeyondStable: Bool {
        let normalizedDisplayTranslation = displayTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayTranslation.isEmpty else {
            return false
        }

        let normalizedStableTranslation = stableTranslation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedStableTranslation.isEmpty else {
            return true
        }

        return normalizedDisplayTranslation != normalizedStableTranslation
    }
}

nonisolated enum LiveSpeechTranslationEvent: Sendable, Equatable {
    case state(LiveUtteranceState)
    case completed(LiveUtteranceState)
}

nonisolated enum ConversationStreamingCoordinatorError: LocalizedError, Equatable {
    case liveSpeechNotAvailable

    var errorDescription: String? {
        switch self {
        case .liveSpeechNotAvailable:
            return "Live speech translation is not available in the current build."
        }
    }
}
