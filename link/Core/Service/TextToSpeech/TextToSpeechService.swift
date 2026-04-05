//
//  TextToSpeechService.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

nonisolated enum TextToSpeechPlaybackEvent: Sendable, Equatable {
    case started(messageID: UUID)
    case finished(messageID: UUID)
    case cancelled(messageID: UUID)
    case failed(messageID: UUID, message: String)
}

@MainActor
protocol TextToSpeechService: AnyObject {
    var playbackEventHandler: ((TextToSpeechPlaybackEvent) -> Void)? { get set }
    func speak(text: String, language: SupportedLanguage, messageID: UUID) async throws
    func stop()
}

nonisolated enum TextToSpeechError: LocalizedError {
    case emptyText
    case audioSessionUnavailable(String)
    case playbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot synthesize speech from empty text."
        case .audioSessionUnavailable(let detail):
            return "Unable to configure the audio session: \(detail)"
        case .playbackUnavailable(let detail):
            return "Unable to start text-to-speech playback: \(detail)"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .emptyText:
            return "这条消息还没有可播放的内容。"
        case .audioSessionUnavailable(let detail):
            return userFacingFailureMessage(
                prefix: "语音播放暂时不可用",
                detail: detail,
                fallback: "请稍后再试。"
            )
        case .playbackUnavailable(let detail):
            return userFacingFailureMessage(
                prefix: "无法开始语音播放",
                detail: detail,
                fallback: "请稍后再试。"
            )
        }
    }
}

private extension TextToSpeechError {
    func userFacingFailureMessage(
        prefix: String,
        detail: String,
        fallback: String
    ) -> String {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDetail.isEmpty else {
            return "\(prefix)，\(fallback)"
        }

        return "\(prefix)：\(normalizedDetail)"
    }
}
