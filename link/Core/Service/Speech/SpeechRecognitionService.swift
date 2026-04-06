//
//  SpeechRecognitionService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct SpeechRecognitionResult: Sendable {
    let text: String
    let detectedLanguage: String?
}

nonisolated enum SpeechPauseStrength: Int, Sendable, Comparable {
    case none
    case soft
    case hard

    static func < (lhs: SpeechPauseStrength, rhs: SpeechPauseStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct SpeechTranscriptionSnapshot: Sendable, Equatable {
    let stableTranscript: String
    let provisionalTranscript: String
    let liveTranscript: String
    let revision: Int
    let detectedLanguage: SupportedLanguage?
    let isEndpoint: Bool
    let pauseStrength: SpeechPauseStrength

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

    var hasPauseHint: Bool {
        pauseStrength != .none
    }
}

nonisolated enum SpeechTranscriptEvent: Sendable, Equatable {
    case started
    case updated(SpeechTranscriptionSnapshot)
    case completed(SpeechTranscriptionSnapshot)
}

nonisolated protocol SpeechRecognitionStreamingService: Sendable {
    func streamTranscription(
        audioStream: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<SpeechTranscriptEvent, Error>
}

nonisolated protocol SpeechRecognitionService: Sendable {
    func transcribe(
        samples: [Float],
        preferredLanguage: SupportedLanguage?
    ) async throws -> SpeechRecognitionResult
}

extension SpeechRecognitionService {
    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        try await transcribe(
            samples: samples,
            preferredLanguage: nil
        )
    }
}

nonisolated enum SpeechRecognitionError: LocalizedError {
    case microphonePermissionDenied
    case microphoneUnavailable
    case recordingInProgress
    case recordingNotActive
    case recordingTooShort
    case audioProcessingFailed(String)
    case modelPackageUnavailable
    case modelNotInstalled
    case packageMissing(String)
    case catalogMissing
    case catalogInvalid(String)
    case catalogUnavailable
    case downloadFailed(String)
    case integrityCheckFailed
    case extractionFailed(String)
    case installationFailed(String)
    case runtimeInitialization(String)
    case transcriptionFailed(String)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .microphoneUnavailable:
            return "Microphone is unavailable."
        case .recordingInProgress:
            return "A recording session is already in status."
        case .recordingNotActive:
            return "No active recording session."
        case .recordingTooShort:
            return "Recording is too short to transcribe."
        case .audioProcessingFailed(let detail):
            return "Audio processing failed: \(detail)"
        case .modelPackageUnavailable:
            return "Speech model package metadata is unavailable."
        case .modelNotInstalled:
            return "Speech model is not installed."
        case .packageMissing(let packageId):
            return "Speech package metadata is missing for \(packageId)."
        case .catalogMissing:
            return "Speech model catalog is missing."
        case .catalogInvalid(let detail):
            return "Speech model catalog is invalid: \(detail)"
        case .catalogUnavailable:
            return "Speech model catalog is unavailable."
        case .downloadFailed(let detail):
            return "Speech model download failed: \(detail)"
        case .integrityCheckFailed:
            return "Downloaded speech model archive failed the integrity check."
        case .extractionFailed(let detail):
            return "Failed to extract the speech model archive: \(detail)"
        case .installationFailed(let detail):
            return "Speech model installation failed: \(detail)"
        case .runtimeInitialization(let detail):
            return "Speech runtime initialization failed: \(detail)"
        case .transcriptionFailed(let detail):
            return "Speech transcription failed: \(detail)"
        case .emptyTranscription:
            return "Speech transcription produced an empty result."
        }
    }

    var userFacingMessage: String {
        switch self {
        case .microphonePermissionDenied:
            return "请先允许访问麦克风，再使用语音识别。"
        case .microphoneUnavailable:
            return "当前设备无法开启录音，请稍后重试。"
        case .recordingInProgress:
            return "正在录音中，请先结束当前录音。"
        case .recordingNotActive:
            return "当前没有正在进行的录音。"
        case .recordingTooShort:
            return "录音时间太短了，请再说完整一点。"
        case .audioProcessingFailed(let detail):
            return userFacingFailureMessage(
                prefix: "音频处理失败",
                detail: detail,
                fallback: "请稍后重试。"
            )
        case .modelPackageUnavailable:
            return "暂时无法获取语音识别模型，请稍后重试。"
        case .modelNotInstalled:
            return "语音识别模型还没有下载，请先完成下载。"
        case .packageMissing:
            return "语音识别模型配置缺失，请刷新后重试。"
        case .catalogMissing, .catalogInvalid, .catalogUnavailable:
            return "语音识别模型目录暂时不可用，请稍后重试。"
        case .downloadFailed(let detail):
            return userFacingFailureMessage(
                prefix: "语音模型下载失败",
                detail: detail,
                fallback: "请检查网络后重试。"
            )
        case .integrityCheckFailed:
            return "下载的语音模型校验失败，请重新下载。"
        case .extractionFailed(let detail):
            return userFacingFailureMessage(
                prefix: "语音模型解压失败",
                detail: detail,
                fallback: "请重新下载后再试。"
            )
        case .installationFailed(let detail):
            return userFacingFailureMessage(
                prefix: "语音模型安装失败",
                detail: detail,
                fallback: "请稍后重试。"
            )
        case .runtimeInitialization(let detail):
            return userFacingFailureMessage(
                prefix: "语音识别引擎初始化失败",
                detail: detail,
                fallback: "请检查模型文件是否完整。"
            )
        case .transcriptionFailed(let detail):
            return userFacingFailureMessage(
                prefix: "语音识别失败",
                detail: detail,
                fallback: "请稍后重试。"
            )
        case .emptyTranscription:
            return "没有识别到可用文字，请再试一次。"
        }
    }
}

private extension SpeechRecognitionError {
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
