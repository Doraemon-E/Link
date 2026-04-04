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

        let installation = try await loadInstallation()
        let context = try loadContext(for: installation)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.translate = false
        params.detect_language = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = false
        params.language = nil
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4)))

        let result = try samples.withUnsafeBufferPointer { buffer -> SpeechRecognitionResult in
            let status = whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            guard status == 0 else {
                throw SpeechRecognitionError.transcriptionFailed("Whisper returned status \(status).")
            }

            let segmentCount = Int(whisper_full_n_segments(context))
            var textParts: [String] = []
            textParts.reserveCapacity(segmentCount)

            for index in 0..<segmentCount {
                guard let segmentText = whisper_full_get_segment_text(context, Int32(index)) else {
                    continue
                }

                textParts.append(String(cString: segmentText))
            }

            let transcribedText = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcribedText.isEmpty else {
                throw SpeechRecognitionError.emptyTranscription
            }

            let languageID = whisper_full_lang_id(context)
            let detectedLanguage: String?
            if languageID >= 0, let languageCString = whisper_lang_str(languageID) {
                detectedLanguage = String(cString: languageCString)
            } else {
                detectedLanguage = nil
            }

            return SpeechRecognitionResult(
                text: transcribedText,
                detectedLanguage: detectedLanguage
            )
        }

        return result
    }

    private func loadInstallation() async throws -> SpeechModelInstallation {
        if let installation = try await installer.installedDefaultPackage() {
            return installation
        }

        if try await installer.defaultPackageMetadata() != nil {
            throw SpeechRecognitionError.modelNotInstalled
        }

        throw SpeechRecognitionError.modelPackageUnavailable
    }

    private func loadContext(for installation: SpeechModelInstallation) throws -> OpaquePointer {
        if let loadedState, loadedState.packageId == installation.package.packageId {
            return loadedState.context
        }

        if let existingContext = loadedState?.context {
            whisper_free(existingContext)
            loadedState = nil
        }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true

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
}
