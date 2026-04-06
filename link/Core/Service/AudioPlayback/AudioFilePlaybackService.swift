//
//  AudioFilePlaybackService.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated enum AudioFilePlaybackEvent: Sendable, Equatable {
    case started(playbackID: UUID)
    case finished(playbackID: UUID)
    case cancelled(playbackID: UUID)
    case failed(playbackID: UUID, message: String)
}

@MainActor
protocol AudioFilePlaybackService: AnyObject {
    var playbackEventHandler: ((AudioFilePlaybackEvent) -> Void)? { get set }
    func play(url: URL, playbackID: UUID) async throws
    func stop()
}

nonisolated enum AudioFilePlaybackError: LocalizedError {
    case fileNotFound
    case audioSessionUnavailable(String)
    case playbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "The audio file could not be found."
        case .audioSessionUnavailable(let detail):
            return "Unable to configure the audio session: \(detail)"
        case .playbackUnavailable(let detail):
            return "Unable to start audio playback: \(detail)"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .fileNotFound:
            return "这条语音的录音文件找不到了。"
        case .audioSessionUnavailable(let detail):
            return userFacingFailureMessage(
                prefix: "原始语音暂时无法播放",
                detail: detail,
                fallback: "请稍后再试。"
            )
        case .playbackUnavailable(let detail):
            return userFacingFailureMessage(
                prefix: "无法播放原始语音",
                detail: detail,
                fallback: "请稍后再试。"
            )
        }
    }
}

private extension AudioFilePlaybackError {
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
