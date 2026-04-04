//
//  MicrophoneRecordingService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import AVFoundation
import Foundation

struct MicrophoneRecordingResult {
    let samples: [Float]
    let preservedRecordingURL: URL?
}

@MainActor
final class MicrophoneRecordingService {
    private let engine = AVAudioEngine()
    private var recordingFileURL: URL?
    private var recordingFile: AVAudioFile?

    var isRecording: Bool {
        recordingFileURL != nil
    }

    func startRecording() async throws {
        guard !isRecording else {
            throw SpeechRecognitionError.recordingInProgress
        }

        let hasPermission = await requestPermission()
        guard hasPermission else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechRecognitionError.microphoneUnavailable
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw SpeechRecognitionError.microphoneUnavailable
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: fileURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
        } catch {
            throw SpeechRecognitionError.audioProcessingFailed(error.localizedDescription)
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            try? outputFile.write(from: buffer)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: fileURL)
            throw SpeechRecognitionError.microphoneUnavailable
        }

        recordingFileURL = fileURL
        recordingFile = outputFile
    }

    func stopRecording() async throws -> MicrophoneRecordingResult {
        guard let recordingFileURL else {
            throw SpeechRecognitionError.recordingNotActive
        }

        finishRecordingSession()
        defer {
            try? FileManager.default.removeItem(at: recordingFileURL)
        }

        let preservedRecordingURL = try preserveRecording(at: recordingFileURL)
        let samples = try loadWhisperSamples(from: recordingFileURL)
        guard samples.count >= 1600 else {
            throw SpeechRecognitionError.recordingTooShort
        }

        return MicrophoneRecordingResult(
            samples: samples,
            preservedRecordingURL: preservedRecordingURL
        )
    }

    func cancelRecording() {
        guard let recordingFileURL else {
            return
        }

        finishRecordingSession()
        try? FileManager.default.removeItem(at: recordingFileURL)
    }

    private func finishRecordingSession() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        recordingFile = nil
        recordingFileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func preserveRecording(at url: URL) throws -> URL {
        let preservedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("last-speech-recording", isDirectory: false)
            .appendingPathExtension(url.pathExtension.isEmpty ? "caf" : url.pathExtension)

        if FileManager.default.fileExists(atPath: preservedURL.path) {
            try? FileManager.default.removeItem(at: preservedURL)
        }

        do {
            try FileManager.default.copyItem(at: url, to: preservedURL)
            print("[MicrophoneRecordingService] Preserved recording at \(preservedURL.path)")
            return preservedURL
        } catch {
            throw SpeechRecognitionError.audioProcessingFailed("Unable to preserve recorded audio: \(error.localizedDescription)")
        }
    }

    private func loadWhisperSamples(from url: URL) throws -> [Float] {
        do {
            let sourceFile = try AVAudioFile(forReading: url)
            let sourceFormat = sourceFile.processingFormat
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )

            guard let outputFormat else {
                throw SpeechRecognitionError.audioProcessingFailed("Unable to create target audio format.")
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                throw SpeechRecognitionError.audioProcessingFailed("Unable to create audio converter.")
            }

            let sourceFrameCount = AVAudioFrameCount(max(sourceFile.length, 1))
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: sourceFrameCount
            ) else {
                throw SpeechRecognitionError.audioProcessingFailed("Unable to allocate source audio buffer.")
            }

            try sourceFile.read(into: sourceBuffer)

            let estimatedFrameCount = AVAudioFrameCount(
                (Double(sourceBuffer.frameLength) * outputFormat.sampleRate / sourceFormat.sampleRate)
                    .rounded(.up)
            ) + 1024

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: max(estimatedFrameCount, 1024)
            ) else {
                throw SpeechRecognitionError.audioProcessingFailed("Unable to allocate output audio buffer.")
            }

            var didProvideInput = false
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if let conversionError {
                throw SpeechRecognitionError.audioProcessingFailed(conversionError.localizedDescription)
            }

            guard let channelData = outputBuffer.floatChannelData?.pointee else {
                throw SpeechRecognitionError.audioProcessingFailed("Unable to read converted audio samples.")
            }

            let frameLength = Int(outputBuffer.frameLength)
            guard frameLength > 0 else {
                throw SpeechRecognitionError.recordingTooShort
            }

            return Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        } catch let error as SpeechRecognitionError {
            throw error
        } catch {
            throw SpeechRecognitionError.audioProcessingFailed(error.localizedDescription)
        }
    }
}
