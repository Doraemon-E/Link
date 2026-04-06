//
//  ConversationStreamingState.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum MessagePhase: Sendable, Equatable {
    case idle
    case transcribing
    case translating
    case typing
    case completed
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle, .completed:
            return nil
        case .transcribing:
            return "正在识别"
        case .translating:
            return nil
        case .typing:
            return nil
        case .failed:
            return "输出失败"
        }
    }

    var placeholderText: String? {
        switch self {
        case .idle, .completed:
            return nil
        case .transcribing:
            return "正在识别语音…"
        case .translating:
            return nil
        case .typing:
            return nil
        case .failed(let message):
            return message
        }
    }

    var isInProgress: Bool {
        switch self {
        case .transcribing, .translating, .typing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}

nonisolated struct TranslationStreamingState: Sendable, Equatable {
    let messageID: UUID
    var committedText: String
    var liveText: String?
    var phase: MessagePhase
    var revision: Int

    var displayText: String {
        if let liveText {
            let normalizedLiveText = liveText.trimmingCharacters(in: .newlines)
            if !normalizedLiveText.isEmpty {
                return liveText
            }
        }

        return committedText
    }
}

nonisolated struct ExchangeStreamingState: Sendable, Equatable, Identifiable {
    let messageID: UUID
    var sourceStableText: String
    var sourceProvisionalText: String
    var sourceLiveText: String
    var sourcePhase: MessagePhase
    var sourceRevision: Int
    var translatedCommittedText: String
    var translatedLiveText: String?
    var translationPhase: MessagePhase
    var translationRevision: Int

    var id: UUID {
        messageID
    }

    var sourceDisplayText: String {
        let transcript = sourceStableText + sourceProvisionalText + sourceLiveText
        let normalized = transcript.trimmingCharacters(in: .newlines)
        return normalized.isEmpty ? transcript : normalized
    }

    var translatedDisplayText: String {
        resolvedDisplayText(
            committedText: translatedCommittedText,
            liveText: translatedLiveText
        )
    }

    var hasSourceUnstableText: Bool {
        !sourceProvisionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !sourceLiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sourcePlaceholderText: String? {
        sourcePhase.placeholderText
    }

    var translatedPlaceholderText: String? {
        translationPhase.placeholderText
    }

    var translationStatusText: String? {
        translationPhase.statusText
    }

    var isTranslationActive: Bool {
        translationPhase.isInProgress
    }

    private func resolvedDisplayText(
        committedText: String,
        liveText: String?
    ) -> String {
        if let liveText {
            let normalizedLiveText = liveText.trimmingCharacters(in: .newlines)
            if !normalizedLiveText.isEmpty {
                return liveText
            }
        }

        return committedText
    }
}
