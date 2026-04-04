//
//  WhisperSpeechRecognitionService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import whisper

actor WhisperSpeechRecognitionService: SpeechRecognitionService {
    private struct LoadedState {
        let packageId: String
        let context: OpaquePointer
    }

    private let installer: SpeechModelInstaller
    private var loadedState: LoadedState?

    init(installer: SpeechModelInstaller) {
        self.installer = installer
    }

    deinit {
        if let context = loadedState?.context {
            whisper_free(context)
        }
    }

    func transcribe(samples: [Float]) async throws -> SpeechRecognitionResult {
        guard !samples.isEmpty else {
            throw SpeechRecognitionError.recordingTooShort
        }

        log("Starting transcription. \(sampleStatistics(for: samples))")
        let installation = try await loadInstallation()
        let context = try loadContext(for: installation)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.translate = false
        // `detect_language = true` makes whisper_full return immediately after language detection,
        // so leave it off and let a nil language trigger auto-detection during transcription.
        params.detect_language = false
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = false
        params.language = nil
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4)))
        params.no_speech_thold = 1.0

        log(
            "Whisper params: threads=\(params.n_threads), detectLanguage=\(params.detect_language), " +
            "noTimestamps=\(params.no_timestamps), suppressBlank=\(params.suppress_blank), " +
            "noSpeechThold=\(params.no_speech_thold)"
        )

        let result = try samples.withUnsafeBufferPointer { buffer -> SpeechRecognitionResult in
            let status = whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            log("whisper_full finished with status=\(status), sampleCount=\(buffer.count)")
            guard status == 0 else {
                throw SpeechRecognitionError.transcriptionFailed("Whisper returned status \(status).")
            }

            let segmentCount = Int(whisper_full_n_segments(context))
            log("Whisper produced segmentCount=\(segmentCount)")
            var textParts: [String] = []
            textParts.reserveCapacity(segmentCount)

            for index in 0..<segmentCount {
                guard let segmentText = whisper_full_get_segment_text(context, Int32(index)) else {
                    log("Segment[\(index)] is nil")
                    continue
                }

                let text = String(cString: segmentText)
                log("Segment[\(index)]=\(summarize(text))")
                textParts.append(text)
            }

            let transcribedText = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcribedText.isEmpty else {
                log("Transcription result is empty after joining \(segmentCount) segments.")
                throw SpeechRecognitionError.emptyTranscription
            }

            let languageID = whisper_full_lang_id(context)
            let detectedLanguage: String?
            if languageID >= 0, let languageCString = whisper_lang_str(languageID) {
                detectedLanguage = String(cString: languageCString)
            } else {
                detectedLanguage = nil
            }

            log("Detected language=\(detectedLanguage ?? "nil"), text=\(summarize(transcribedText))")

            return SpeechRecognitionResult(
                text: transcribedText,
                detectedLanguage: detectedLanguage
            )
        }

        return result
    }

    private func loadInstallation() async throws -> SpeechModelInstallation {
        if let installation = try await installer.installedDefaultPackage() {
            log("Using installed packageId=\(installation.package.packageId), modelPath=\(installation.modelURL.lastPathComponent)")
            return installation
        }

        if try await installer.defaultPackageMetadata() != nil {
            throw SpeechRecognitionError.modelNotInstalled
        }

        throw SpeechRecognitionError.modelPackageUnavailable
    }

    private func loadContext(for installation: SpeechModelInstallation) throws -> OpaquePointer {
        if let loadedState, loadedState.packageId == installation.package.packageId {
            log("Reusing loaded Whisper context for packageId=\(installation.package.packageId)")
            return loadedState.context
        }

        if let existingContext = loadedState?.context {
            whisper_free(existingContext)
            loadedState = nil
        }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        log("Loading Whisper context for packageId=\(installation.package.packageId), modelURL=\(installation.modelURL.path)")

        guard let context = installation.modelURL.path.withCString({
            whisper_init_from_file_with_params($0, contextParams)
        }) else {
            throw SpeechRecognitionError.runtimeInitialization("Unable to load Whisper model at \(installation.modelURL.lastPathComponent).")
        }

        loadedState = LoadedState(
            packageId: installation.package.packageId,
            context: context
        )

        return context
    }

    private func sampleStatistics(for samples: [Float]) -> String {
        let durationSeconds = Double(samples.count) / 16_000
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let energy = samples.reduce(Double.zero) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        let rms = sqrt(energy / Double(max(samples.count, 1)))

        return String(
            format: "sampleCount=%d, duration=%.2fs, peak=%.5f, rms=%.5f",
            samples.count,
            durationSeconds,
            peak,
            rms
        )
    }

    private func summarize(_ text: String, maxLength: Int = 160) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > maxLength else {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<endIndex]) + "..."
    }

    private func log(_ message: String) {
        print("[WhisperSpeechRecognitionService] \(message)")
    }
}
