//
//  WhisperSpeechRecognitionService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import whisper

actor WhisperSpeechRecognitionService: SpeechRecognitionService, SpeechRecognitionStreamingService {
    private enum TranscriptionMode {
        case final
        case streaming
    }

    private struct LoadedState {
        let packageId: String
        let context: OpaquePointer
    }

    private struct StreamingSession {
        var gate: SpeechActivityGate
        var stabilizer = SpeechTranscriptStabilizer()
        var activeUtteranceSamples: [Float] = []
        var samplesSinceLastInference = 0
        var latestSnapshot: SpeechTranscriptionSnapshot?

        init(configuration: SpeechStreamingConfiguration) {
            self.gate = SpeechActivityGate(
                configuration: configuration.activityGate,
                sampleRate: configuration.sampleRate
            )
        }

        mutating func appendCapturedSamples(_ samples: [Float]) {
            guard !samples.isEmpty else {
                return
            }

            activeUtteranceSamples.append(contentsOf: samples)
            samplesSinceLastInference += samples.count
        }

        mutating func resetActiveUtterance() {
            activeUtteranceSamples.removeAll(keepingCapacity: false)
            samplesSinceLastInference = 0
        }
    }

    private let packageManager: SpeechModelPackageManager
    private let streamingConfiguration: SpeechStreamingConfiguration
    private var loadedState: LoadedState?

    init(
        packageManager: SpeechModelPackageManager,
        streamingConfiguration: SpeechStreamingConfiguration = .default
    ) {
        self.packageManager = packageManager
        self.streamingConfiguration = streamingConfiguration
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
        return try runTranscription(
            samples: samples,
            context: context,
            mode: .final
        )
    }

    nonisolated func streamTranscription(
        audioStream: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<SpeechTranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.started)

                    let installation = try await self.loadInstallation()
                    let context = try await self.loadContext(for: installation)
                    var session = StreamingSession(configuration: self.streamingConfiguration)

                    for await chunk in audioStream {
                        try Task.checkCancellation()
                        guard !chunk.isEmpty else {
                            continue
                        }

                        let snapshots = try await self.consumeStreamingChunk(
                            chunk,
                            context: context,
                            session: &session
                        )
                        for snapshot in snapshots {
                            session.latestSnapshot = snapshot
                            continuation.yield(.updated(snapshot))
                        }
                    }

                    if let finalSnapshot = try await self.finishStreamingSession(
                        context: context,
                        session: &session
                    ) {
                        session.latestSnapshot = finalSnapshot
                        continuation.yield(.updated(finalSnapshot))
                    }

                    continuation.yield(
                        .completed(session.latestSnapshot ?? session.stabilizer.currentSnapshot)
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func loadInstallation() async throws -> SpeechModelInstallation {
        if let installation = try await packageManager.installedDefaultPackage() {
            log("Using installed packageId=\(installation.package.packageId), modelPath=\(installation.modelURL.lastPathComponent)")
            return installation
        }

        if try await packageManager.defaultPackageMetadata() != nil {
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
        contextParams.use_gpu = streamingConfiguration.useGPU
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

    private func consumeStreamingChunk(
        _ chunk: [Float],
        context: OpaquePointer,
        session: inout StreamingSession
    ) async throws -> [SpeechTranscriptionSnapshot] {
        let gateUpdate = session.gate.consume(chunk)
        session.appendCapturedSamples(gateUpdate.appendedSamples)

        guard !session.activeUtteranceSamples.isEmpty || gateUpdate.isEndpoint else {
            return []
        }

        var emittedSnapshots: [SpeechTranscriptionSnapshot] = []

        if shouldRunStreamingInference(after: gateUpdate, session: session) {
            session.samplesSinceLastInference = 0
            if let snapshot = try await runBestEffortStreamingInference(
                context: context,
                gateUpdate: gateUpdate,
                session: &session
            ) {
                emittedSnapshots.append(snapshot)
            }
        }

        if gateUpdate.isEndpoint,
           let snapshot = try await finalizeActiveUtterance(
               context: context,
               session: &session
           ) {
            emittedSnapshots.append(snapshot)
        }

        return emittedSnapshots
    }

    private func finishStreamingSession(
        context: OpaquePointer,
        session: inout StreamingSession
    ) async throws -> SpeechTranscriptionSnapshot? {
        guard !session.activeUtteranceSamples.isEmpty else {
            return session.stabilizer.currentSnapshot.hasUnstableTranscript
                ? session.stabilizer.finalizeCurrentUtterance()
                : nil
        }

        return try await finalizeActiveUtterance(
            context: context,
            session: &session
        )
    }

    private func shouldRunStreamingInference(
        after gateUpdate: SpeechActivityGate.Update,
        session: StreamingSession
    ) -> Bool {
        guard !gateUpdate.isEndpoint else {
            return false
        }

        guard session.activeUtteranceSamples.count >= streamingConfiguration.minimumStreamingSampleCount else {
            return false
        }

        return session.samplesSinceLastInference >= streamingConfiguration.stepSampleCount
    }

    private func runBestEffortStreamingInference(
        context: OpaquePointer,
        gateUpdate: SpeechActivityGate.Update,
        session: inout StreamingSession
    ) async throws -> SpeechTranscriptionSnapshot? {
        let inferenceSamples = Array(
            session.activeUtteranceSamples.suffix(streamingConfiguration.streamingWindowSampleCount)
        )

        guard inferenceSamples.count >= streamingConfiguration.minimumStreamingSampleCount else {
            return nil
        }

        do {
            let result = try runTranscription(
                samples: inferenceSamples,
                context: context,
                mode: .streaming
            )
            let pauseStrength = pauseStrength(
                trailingSilenceDuration: gateUpdate.trailingSilenceDuration,
                transcript: result.text
            )
            return session.stabilizer.consume(
                candidate: result.text,
                detectedLanguage: SupportedLanguage.fromWhisperLanguageCode(result.detectedLanguage),
                isEndpoint: false,
                pauseStrength: pauseStrength
            )
        } catch let error as SpeechRecognitionError {
            if case .emptyTranscription = error {
                return nil
            }

            log("Ignoring streaming inference error: \(error.localizedDescription)")
            return nil
        } catch {
            log("Ignoring streaming inference error: \(error.localizedDescription)")
            return nil
        }
    }

    private func finalizeActiveUtterance(
        context: OpaquePointer,
        session: inout StreamingSession
    ) async throws -> SpeechTranscriptionSnapshot? {
        defer {
            session.resetActiveUtterance()
        }

        guard session.activeUtteranceSamples.count >= streamingConfiguration.minimumFinalizationSampleCount else {
            return session.stabilizer.finalizeCurrentUtterance()
        }

        do {
            let result = try runTranscription(
                samples: session.activeUtteranceSamples,
                context: context,
                mode: .final
            )
            return session.stabilizer.consume(
                candidate: result.text,
                detectedLanguage: SupportedLanguage.fromWhisperLanguageCode(result.detectedLanguage),
                isEndpoint: true,
                pauseStrength: .hard
            )
        } catch let error as SpeechRecognitionError {
            if case .emptyTranscription = error {
                return session.stabilizer.finalizeCurrentUtterance()
            }

            log("Falling back to accumulated live transcript after endpoint inference error: \(error.localizedDescription)")
            return session.stabilizer.finalizeCurrentUtterance()
        } catch {
            log("Falling back to accumulated live transcript after endpoint inference error: \(error.localizedDescription)")
            return session.stabilizer.finalizeCurrentUtterance()
        }
    }

    private func runTranscription(
        samples: [Float],
        context: OpaquePointer,
        mode: TranscriptionMode
    ) throws -> SpeechRecognitionResult {
        let params = makeWhisperParams(for: mode)

        log(
            "Whisper params[\(mode)]: threads=\(params.n_threads), detectLanguage=\(params.detect_language), " +
            "noTimestamps=\(params.no_timestamps), singleSegment=\(params.single_segment), " +
            "maxTokens=\(params.max_tokens), audioCtx=\(params.audio_ctx)"
        )

        return try samples.withUnsafeBufferPointer { buffer -> SpeechRecognitionResult in
            let status = whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            log("whisper_full finished with status=\(status), sampleCount=\(buffer.count), mode=\(mode)")
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

                let rawText = String(cString: segmentText)
                let text = sanitizeSegmentText(rawText)
                guard !text.isEmpty else {
                    continue
                }

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
    }

    private func makeWhisperParams(
        for mode: TranscriptionMode
    ) -> whisper_full_params {
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
        params.language = nil
        params.n_threads = contextThreadCount()
        params.no_speech_thold = streamingConfiguration.inference.noSpeechThreshold

        switch mode {
        case .final:
            params.single_segment = false
            params.no_context = false
            params.audio_ctx = 0
            params.max_tokens = 0
        case .streaming:
            params.single_segment = true
            params.no_context = true
            params.audio_ctx = streamingConfiguration.inference.audioContextSize
            params.max_tokens = streamingConfiguration.inference.maxTokenCount
        }

        return params
    }

    private func contextThreadCount() -> Int32 {
        Int32(
            max(
                1,
                min(
                    ProcessInfo.processInfo.activeProcessorCount,
                    Int(streamingConfiguration.threadLimit)
                )
            )
        )
    }

    private func sampleStatistics(for samples: [Float]) -> String {
        let durationSeconds = Double(samples.count) / Double(streamingConfiguration.sampleRate)
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

    private func sanitizeSegmentText(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }

        guard !Self.whisperNonSpeechPlaceholders.contains(normalized.uppercased()) else {
            return ""
        }

        return text
    }

    private func hasStrongPausePunctuation(in text: String) -> Bool {
        guard let lastCharacter = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }

        return Self.strongPausePunctuationCharacters.contains(lastCharacter)
    }

    private func pauseStrength(
        trailingSilenceDuration: TimeInterval,
        transcript: String
    ) -> SpeechPauseStrength {
        if trailingSilenceDuration >= 0.55 {
            return .hard
        }

        if trailingSilenceDuration >= 0.35 || hasStrongPausePunctuation(in: transcript) {
            return .soft
        }

        return .none
    }

    private static let whisperNonSpeechPlaceholders: Set<String> = [
        "[BLANK_AUDIO]",
        "[MUSIC]",
        "[NOISE]",
        "[LAUGHTER]",
        "[APPLAUSE]"
    ]

    private static let strongPausePunctuationCharacters: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":"
    ]

    private func log(_ message: String) {
        print("[WhisperSpeechRecognitionService] \(message)")
    }
}
