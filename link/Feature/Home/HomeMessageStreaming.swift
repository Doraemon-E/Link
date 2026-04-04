//
//  HomeMessageStreaming.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum MessagePhase: Sendable, Equatable {
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
            return "翻译中"
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
            return "翻译中…"
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

struct StreamingMessageState: Sendable, Equatable, Identifiable {
    let messageID: UUID
    var committedText: String
    var liveText: String?
    var phase: MessagePhase
    var revision: Int

    var id: UUID {
        messageID
    }

    var displayText: String {
        if let liveText {
            let normalizedLiveText = liveText.trimmingCharacters(in: .newlines)
            if !normalizedLiveText.isEmpty {
                return liveText
            }
        }

        return committedText
    }

    var statusText: String? {
        phase.statusText
    }

    var placeholderText: String? {
        phase.placeholderText
    }

    var isActive: Bool {
        phase.isInProgress
    }
}
