//
//  StreamingTTSAudioGenerator.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import AVFoundation
import Foundation
@testable import link

enum StreamingAudioVariant: String, Codable, Sendable {
    case clean
    case pause
}

enum StreamingTTSAudioGeneratorError: LocalizedError {
    case voiceUnavailable(String)
    case synthesisFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable(let detail):
            return "Unable to locate a compatible TTS voice: \(detail)"
        case .synthesisFailed(let detail):
            return "Streaming TTS synthesis failed: \(detail)"
        case .emptyAudio:
            return "Streaming TTS synthesis produced empty audio."
        }
    }
}

@MainActor
final class StreamingTTSAudioGenerator {
    private final class OutputFileState {
        private(set) var outputFile: AVAudioFile?
        private(set) var outputFormat: AVAudioFormat?
        let outputURL: URL

        init(outputURL: URL) {
            self.outputURL = outputURL
        }

        func write(buffer: AVAudioPCMBuffer) throws {
            if outputFile == nil {
                outputFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
                outputFormat = buffer.format
            }

            try outputFile?.write(from: buffer)
        }

        func writeSilence(milliseconds: Int) throws {
            guard milliseconds > 0,
                  let outputFile,
                  let outputFormat else {
                return
            }

            let frameCount = AVAudioFrameCount(
                max(
                    Int((Double(outputFormat.sampleRate) * Double(milliseconds) / 1_000.0).rounded()),
                    1
                )
            )

            guard let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCount
            ) else {
                throw StreamingTTSAudioGeneratorError.synthesisFailed("Unable to allocate silence buffer.")
            }

            silenceBuffer.frameLength = frameCount
            for audioBuffer in UnsafeMutableAudioBufferListPointer(silenceBuffer.mutableAudioBufferList) {
                guard let data = audioBuffer.mData else {
                    continue
                }

                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }

            try outputFile.write(from: silenceBuffer)
        }
    }

    func synthesizeSamples(
        text: String,
        language: SupportedLanguage,
        speechRate: Double,
        variant: StreamingAudioVariant,
        pausePlan: [Int]
    ) async throws -> [Float] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw StreamingTTSAudioGeneratorError.emptyAudio
        }

        let utteranceSegments = segments(
            from: normalizedText,
            variant: variant
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-tts-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("caf")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try await synthesizeAudioFile(
                utteranceSegments: utteranceSegments,
                pausePlan: pausePlan,
                language: language,
                speechRate: speechRate,
                outputURL: temporaryURL
            )

            let recorder = MicrophoneRecordingService()
            let samples = try recorder.loadWhisperSamples(from: temporaryURL)
            if samples.isEmpty {
                throw StreamingTTSAudioGeneratorError.emptyAudio
            }

            return samples
        } catch {
            throw error
        }
    }

    private func synthesizeAudioFile(
        utteranceSegments: [String],
        pausePlan: [Int],
        language: SupportedLanguage,
        speechRate: Double,
        outputURL: URL
    ) async throws {
        guard let voice = AVSpeechSynthesisVoice(language: language.ttsLocaleIdentifier) else {
            throw StreamingTTSAudioGeneratorError.voiceUnavailable(language.ttsLocaleIdentifier)
        }

        let synthesizer = AVSpeechSynthesizer()
        let outputState = OutputFileState(outputURL: outputURL)

        for (index, segment) in utteranceSegments.enumerated() {
            let utterance = AVSpeechUtterance(string: segment)
            utterance.voice = voice
            utterance.rate = Float(speechRate)

            try await write(
                utterance: utterance,
                using: synthesizer,
                outputState: outputState
            )

            let isLastSegment = index == utteranceSegments.count - 1
            if !isLastSegment {
                let pauseMilliseconds = pauseDuration(
                    for: index,
                    pausePlan: pausePlan
                )
                try outputState.writeSilence(milliseconds: pauseMilliseconds)
            }
        }

        guard outputState.outputFile != nil else {
            throw StreamingTTSAudioGeneratorError.emptyAudio
        }
    }

    private func write(
        utterance: AVSpeechUtterance,
        using synthesizer: AVSpeechSynthesizer,
        outputState: OutputFileState
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            synthesizer.write(utterance) { buffer in
                Task { @MainActor in
                    guard !didResume else {
                        return
                    }

                    guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                        return
                    }

                    let audioBuffers = UnsafeMutableAudioBufferListPointer(
                        pcmBuffer.mutableAudioBufferList
                    )
                    let hasNonEmptyAudioData = audioBuffers.contains { audioBuffer in
                        audioBuffer.mDataByteSize > 0
                    }

                    guard hasNonEmptyAudioData else {
                        didResume = true
                        continuation.resume()
                        return
                    }

                    if pcmBuffer.frameLength == 0 {
                        didResume = true
                        continuation.resume()
                        return
                    }

                    do {
                        try outputState.write(buffer: pcmBuffer)
                    } catch {
                        didResume = true
                        synthesizer.stopSpeaking(at: .immediate)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func segments(
        from text: String,
        variant: StreamingAudioVariant
    ) -> [String] {
        guard variant == .pause else {
            return [text]
        }

        var segments: [String] = []
        var current = ""
        let breakCharacters = CharacterSet(charactersIn: "，。！？；：,.!?;:")

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)

            if breakCharacters.contains(scalar) {
                let normalizedSegment = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSegment.isEmpty {
                    segments.append(normalizedSegment)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        let normalizedRemainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedRemainder.isEmpty {
            segments.append(normalizedRemainder)
        }

        return segments.isEmpty ? [text] : segments
    }

    private func pauseDuration(
        for segmentIndex: Int,
        pausePlan: [Int]
    ) -> Int {
        guard !pausePlan.isEmpty else {
            return 600
        }

        if segmentIndex < pausePlan.count {
            return pausePlan[segmentIndex]
        }

        return pausePlan.last ?? 600
    }
}
