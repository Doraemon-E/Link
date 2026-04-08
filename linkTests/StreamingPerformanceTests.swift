//∫
//  StreamingPerformanceTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import AVFoundation
import Foundation
import XCTest
@testable import link

final class StreamingPerformanceTests: XCTestCase {
    func testStreamingPerformanceBenchmark() async throws {
        continueAfterFailure = true

        let runStartAt = Date()
        let runStartTick = DispatchTime.now().uptimeNanoseconds
        Self.log("Run started at \(Self.iso8601String(from: runStartAt))")

        let corpusEntries = try loadCorpusEntries()
        let manifestEntries = try loadManifestEntries()
        let suites = try makeSuites(
            corpusEntries: corpusEntries,
            manifestEntries: manifestEntries
        )

        XCTAssertEqual(corpusEntries.count, 15, "Expected 15 translation corpus entries.")
        XCTAssertEqual(suites.count, 3, "Expected 3 streaming benchmark suites.")

        try await preflightTTSVoice()
        let services = try await makeServiceContext()
        let routes = try await preflightTranslationRoutes(using: services.translationService)
        guard try await ensureInstalledModels(
            routes: routes,
            translationPackageManager: services.translationPackageManager,
            speechPackageManager: services.speechPackageManager
        ) else {
            return
        }

        var suiteResults: [StreamingBenchmarkSuiteResult] = []
        let replayDriver = AudioChunkReplayDriver()

        for suite in suites {
            for mode in Self.executionModes {
                for route in Self.benchmarkRoutes {
                    let result = try await runSuite(
                        suite,
                        mode: mode,
                        route: route,
                        services: services,
                        replayDriver: replayDriver
                    )
                    suiteResults.append(result)
                }
            }
        }

        let runEndAt = Date()
        let totalDurationSeconds = Self.secondsSince(runStartTick)
        let runResult = StreamingBenchmarkRunResult(
            runStartAt: runStartAt,
            runEndAt: runEndAt,
            totalDurationSeconds: totalDurationSeconds,
            suiteResults: suiteResults
        )

        let logURL = try writeRunLog(runResult)
        Self.log(
            "Run completed at \(Self.iso8601String(from: runEndAt)) totalDurationSeconds=\(Self.formatSeconds(totalDurationSeconds)) log=\(logURL.path)"
        )

        if suiteResults.contains(where: { $0.failureCount > 0 }) {
            XCTFail("Streaming benchmark finished with failures. See log at \(logURL.path)")
        }
    }

    private func loadCorpusEntries() throws -> [StreamingTranslationCorpusEntry] {
        let data = try Data(contentsOf: try resolveCorpusURL())
        return try JSONDecoder().decode([StreamingTranslationCorpusEntry].self, from: data)
    }

    private func loadManifestEntries() throws -> [StreamingAudioManifestEntry] {
        let data = try Data(contentsOf: try resolveManifestURL())
        return try JSONDecoder().decode([StreamingAudioManifestEntry].self, from: data)
    }

    private func makeSuites(
        corpusEntries: [StreamingTranslationCorpusEntry],
        manifestEntries: [StreamingAudioManifestEntry]
    ) throws -> [StreamingBenchmarkSuite] {
        let corpusByID = Dictionary(uniqueKeysWithValues: corpusEntries.map { ($0.id, $0) })

        let orderedSuites: [StreamingSuiteName] = [.short, .medium, .long]
        return try orderedSuites.map { suiteName in
            let suiteEntries = try manifestEntries
                .filter { $0.suite == suiteName }
                .map { manifestEntry -> StreamingBenchmarkCaseSpecification in
                    guard let corpusEntry = corpusByID[manifestEntry.corpusID] else {
                        throw NSError(
                            domain: "StreamingPerformanceTests",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Unknown corpus entry in streaming manifest: \(manifestEntry.corpusID)"]
                        )
                    }

                    return StreamingBenchmarkCaseSpecification(
                        manifestEntry: manifestEntry,
                        corpusEntry: corpusEntry
                    )
                }

            guard !suiteEntries.isEmpty else {
                throw NSError(
                    domain: "StreamingPerformanceTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Streaming suite \(suiteName.rawValue) has no manifest entries."]
                )
            }

            return StreamingBenchmarkSuite(
                name: suiteName,
                caseSpecifications: suiteEntries
            )
        }
    }

    private func makeServiceContext() async throws -> StreamingServiceContext {
        let translationCatalogURL = try resolveTranslationCatalogURL()
        let translationCatalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: Bundle(for: StreamingPerformanceTests.self),
            bundledCatalogURLOverride: translationCatalogURL
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: translationCatalogRepository
        )
        let translationService = MarianTranslationService(modelProvider: translationPackageManager)

        let speechBundleCandidates = [Bundle.main, Bundle(for: StreamingPerformanceTests.self)]
        var speechPackageManager: SpeechModelPackageManager?

        for bundle in speechBundleCandidates {
            let repository = SpeechModelCatalogRepository(
                remoteCatalogURL: nil,
                bundle: bundle
            )
            let manager = SpeechModelPackageManager(catalogRepository: repository)
            if try await manager.defaultPackageMetadata() != nil {
                speechPackageManager = manager
                break
            }
        }

        guard let speechPackageManager else {
            throw NSError(
                domain: "StreamingPerformanceTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled speech-catalog.json."]
            )
        }

        let speechService = WhisperSpeechRecognitionService(packageManager: speechPackageManager)
        let coordinator = LocalConversationStreamingCoordinator(
            translationService: translationService,
            speechStreamingService: speechService
        )

        return StreamingServiceContext(
            translationPackageManager: translationPackageManager,
            translationService: translationService,
            speechPackageManager: speechPackageManager,
            speechService: speechService,
            coordinator: coordinator
        )
    }

    private func preflightTTSVoice() async throws {
        let voice = await MainActor.run {
            AVSpeechSynthesisVoice(language: SupportedLanguage.chinese.ttsLocaleIdentifier)
        }

        guard voice != nil else {
            throw NSError(
                domain: "StreamingPerformanceTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Chinese system TTS voice is unavailable on this device."]
            )
        }
    }

    private func preflightTranslationRoutes(
        using service: MarianTranslationService
    ) async throws -> [TranslationRoute] {
        let zhEnRoute = try await service.route(source: .chinese, target: .english)
        XCTAssertEqual(
            zhEnRoute.steps,
            [TranslationRouteStep(source: .chinese, target: .english)],
            "Expected zh->en to be a single-hop route."
        )

        let zhJaRoute = try await service.route(source: .chinese, target: .japanese)
        XCTAssertEqual(
            zhJaRoute.steps,
            [
                TranslationRouteStep(source: .chinese, target: .english),
                TranslationRouteStep(source: .english, target: .japanese)
            ],
            "Expected zh->ja to route via english."
        )

        return [zhEnRoute, zhJaRoute]
    }

    private func ensureInstalledModels(
        routes: [TranslationRoute],
        translationPackageManager: TranslationModelPackageManager,
        speechPackageManager: SpeechModelPackageManager
    ) async throws -> Bool {
        var missingRouteModels: [String] = []

        for route in routes {
            for step in route.steps {
                let installation = try await translationPackageManager.installedPackage(
                    for: step.source,
                    target: step.target
                )
                if installation == nil {
                    missingRouteModels.append("\(step.source.compactDisplayName)->\(step.target.compactDisplayName)")
                }
            }
        }

        if try await speechPackageManager.installedDefaultPackage() == nil {
            XCTFail("Missing installed speech recognition model for streaming benchmark.")
            return false
        }

        let uniqueMissingRouteModels = Array(Set(missingRouteModels)).sorted()
        guard uniqueMissingRouteModels.isEmpty else {
            XCTFail(
                "Missing installed translation models for routes: \(uniqueMissingRouteModels.joined(separator: ", "))"
            )
            return false
        }

        return true
    }

    private func runSuite(
        _ suite: StreamingBenchmarkSuite,
        mode: StreamingExecutionMode,
        route: StreamingInvocationRoute,
        services: StreamingServiceContext,
        replayDriver: AudioChunkReplayDriver
    ) async throws -> StreamingBenchmarkSuiteResult {
        let eligibleCaseSpecifications = suite.caseSpecifications.filter {
            $0.manifestEntry.enabledModes.contains(mode)
        }
        let callCount = eligibleCaseSpecifications.reduce(0) { partialResult, caseSpecification in
            partialResult + caseSpecification.manifestEntry.loopCount
        }

        let suiteStartAt = Date()
        let suiteStartTick = DispatchTime.now().uptimeNanoseconds
        let memorySampler = ProcessMemorySampler()
        let cpuSampler = ProcessCPUSampler()
        let rssStartBytes = ProcessMemorySampler.currentResidentSizeBytes()

        Self.log(
            "Suite started suite=\(suite.name.label) mode=\(mode.rawValue) route=\(route.label) suiteStartAt=\(Self.iso8601String(from: suiteStartAt)) callCount=\(callCount) rssStartMB=\(Self.formatMegabytes(rssStartBytes))"
        )

        await memorySampler.start()
        await cpuSampler.start()

        var caseResults: [StreamingBenchmarkCaseResult] = []

        for caseSpecification in eligibleCaseSpecifications {
            for iteration in 1 ... caseSpecification.manifestEntry.loopCount {
                let result = await executeCase(
                    caseSpecification,
                    iteration: iteration,
                    mode: mode,
                    route: route,
                    services: services,
                    replayDriver: replayDriver
                )
                caseResults.append(result)

                if let failureReason = result.failureReason {
                    Self.log(
                        "Case failed suite=\(suite.name.label) mode=\(mode.rawValue) route=\(route.label) caseID=\(result.caseID) error=\(failureReason)"
                    )
                } else {
                    Self.logCaseResult(
                        result,
                        suiteName: suite.name.label,
                        mode: mode.rawValue,
                        route: route.label
                    )
                }
            }
        }

        let memorySamples = await memorySampler.stop()
        let cpuSamples = await cpuSampler.stop()

        let suiteEndAt = Date()
        let suiteDurationSeconds = Self.secondsSince(suiteStartTick)
        let rssEndBytes = memorySamples.last?.residentSizeBytes ?? ProcessMemorySampler.currentResidentSizeBytes()
        let rssPeakBytes = memorySamples.map(\.residentSizeBytes).max() ?? rssEndBytes
        let cpuAveragePercent = cpuSamples.isEmpty
            ? 0
            : cpuSamples.map(\.cpuPercent).reduce(0, +) / Double(cpuSamples.count)
        let cpuPeakPercent = cpuSamples.map(\.cpuPercent).max() ?? 0
        let failureCount = caseResults.filter { $0.failureReason != nil }.count
        let timeoutCount = caseResults.filter { $0.timedOut }.count

        let result = StreamingBenchmarkSuiteResult(
            suiteName: suite.name.label,
            mode: mode.rawValue,
            routeLabel: route.label,
            routeSource: route.source.rawValue,
            routeTarget: route.target.rawValue,
            suiteStartAt: suiteStartAt,
            suiteEndAt: suiteEndAt,
            suiteDurationSeconds: suiteDurationSeconds,
            callCount: callCount,
            rssStartMB: Self.megabytes(from: rssStartBytes),
            rssEndMB: Self.megabytes(from: rssEndBytes),
            rssPeakMB: Self.megabytes(from: rssPeakBytes),
            cpuAveragePercent: cpuAveragePercent,
            cpuPeakPercent: cpuPeakPercent,
            failureCount: failureCount,
            timeoutCount: timeoutCount,
            caseResults: caseResults
        )

        Self.log(
            "Suite completed suite=\(suite.name.label) mode=\(mode.rawValue) route=\(route.label) suiteEndAt=\(Self.iso8601String(from: suiteEndAt)) suiteDurationSeconds=\(Self.formatSeconds(suiteDurationSeconds)) rssEndMB=\(Self.formatMegabytes(rssEndBytes)) rssPeakMB=\(Self.formatMegabytes(rssPeakBytes)) cpuAveragePercent=\(Self.formatPercentage(cpuAveragePercent)) cpuPeakPercent=\(Self.formatPercentage(cpuPeakPercent)) failureCount=\(failureCount)"
        )

        return result
    }

    private func executeCase(
        _ caseSpecification: StreamingBenchmarkCaseSpecification,
        iteration: Int,
        mode: StreamingExecutionMode,
        route: StreamingInvocationRoute,
        services: StreamingServiceContext,
        replayDriver: AudioChunkReplayDriver
    ) async -> StreamingBenchmarkCaseResult {
        let caseID = "\(caseSpecification.manifestEntry.suite.rawValue)-\(caseSpecification.corpusEntry.id)-\(mode.rawValue)-\(route.label)-\(iteration)"
        var recorder: StreamingBenchmarkRecorder?
        var timedOut = false
        var failureReason: String?

        Self.log(
            "Case started caseID=\(caseID) mode=\(mode.rawValue) route=\(route.label) variant=\(caseSpecification.manifestEntry.variant.rawValue) chunkDurationMs=\(caseSpecification.manifestEntry.chunkDurationMs) replayMode=\(caseSpecification.manifestEntry.replayMode.rawValue)"
        )

        do {
            let samples = try await synthesizeSamples(
                text: caseSpecification.corpusEntry.sourceText,
                language: .chinese,
                speechRate: caseSpecification.manifestEntry.speechRate,
                variant: caseSpecification.manifestEntry.variant,
                pausePlan: caseSpecification.manifestEntry.pausePlan
            )

            let approximateAudioDurationSeconds = Double(samples.count) / 16_000.0
            let timeoutSeconds = max(30.0, approximateAudioDurationSeconds * 4.0 + 15.0)
            Self.log(
                "Case prepared caseID=\(caseID) sampleCount=\(samples.count) approxAudioSeconds=\(Self.formatSeconds(approximateAudioDurationSeconds)) timeoutSeconds=\(Self.formatSeconds(timeoutSeconds))"
            )
            let benchmarkRecorder = StreamingBenchmarkRecorder()
            recorder = benchmarkRecorder
            let speechService = services.speechService
            let coordinator = services.coordinator

            try await withTimeout(seconds: timeoutSeconds) {
                let audioStream = replayDriver.makeStream(
                    samples: samples,
                    chunkDurationMilliseconds: caseSpecification.manifestEntry.chunkDurationMs,
                    replayMode: caseSpecification.manifestEntry.replayMode
                )

                switch mode {
                case .recognitionOnly:
                    try await Self.runRecognitionOnly(
                        audioStream: audioStream,
                        speechService: speechService,
                        recorder: benchmarkRecorder
                    )
                case .fullChain:
                    try await Self.runFullChain(
                        caseID: caseID,
                        audioStream: audioStream,
                        targetRoute: route,
                        coordinator: coordinator,
                        recorder: benchmarkRecorder
                    )
                }
            }
        } catch is StreamingBenchmarkTimeoutError {
            timedOut = true
            failureReason = "Timed out while executing streaming benchmark case."
        } catch {
            failureReason = error.localizedDescription
        }

        let metrics = (recorder ?? StreamingBenchmarkRecorder()).finish()
        Self.log(
            "Case returning caseID=\(caseID) timedOut=\(timedOut) failure=\(failureReason ?? "none") finalTranscript=\(Self.quotedPreview(metrics.finalTranscript)) finalTranslation=\(Self.quotedPreview(metrics.finalTranslation))"
        )
        return StreamingBenchmarkCaseResult(
            caseID: caseID,
            corpusID: caseSpecification.corpusEntry.id,
            iteration: iteration,
            mode: mode.rawValue,
            routeLabel: route.label,
            variant: caseSpecification.manifestEntry.variant.rawValue,
            chunkDurationMs: caseSpecification.manifestEntry.chunkDurationMs,
            replayMode: caseSpecification.manifestEntry.replayMode.rawValue,
            caseStartAt: metrics.caseStartAt,
            caseEndAt: metrics.caseEndAt,
            caseDurationSeconds: metrics.caseDurationSeconds,
            firstTranscriptLatencyMs: metrics.firstTranscriptLatencyMs,
            firstStableTranscriptLatencyMs: metrics.firstStableTranscriptLatencyMs,
            finalTranscriptLatencyMs: metrics.finalTranscriptLatencyMs,
            firstTranslationLatencyMs: metrics.firstTranslationLatencyMs,
            finalTranslationLatencyMs: metrics.finalTranslationLatencyMs,
            transcriptRevisionCount: metrics.transcriptRevisionCount,
            translationRevisionCount: metrics.translationRevisionCount,
            stablePromotionCount: metrics.stablePromotionCount,
            endpointCount: metrics.endpointCount,
            finalTranscript: metrics.finalTranscript,
            finalTranslation: metrics.finalTranslation,
            timedOut: timedOut,
            failureReason: failureReason
        )
    }

    @MainActor
    private func synthesizeSamples(
        text: String,
        language: SupportedLanguage,
        speechRate: Double,
        variant: StreamingAudioVariant,
        pausePlan: [Int]
    ) async throws -> [Float] {
        let audioGenerator = StreamingTTSAudioGenerator()
        return try await audioGenerator.synthesizeSamples(
            text: text,
            language: language,
            speechRate: speechRate,
            variant: variant,
            pausePlan: pausePlan
        )
    }

    private static func runRecognitionOnly(
        audioStream: AsyncStream<[Float]>,
        speechService: any SpeechRecognitionStreamingService,
        recorder: StreamingBenchmarkRecorder
    ) async throws {
        let stream = speechService.streamTranscription(audioStream: audioStream)
        for try await event in stream {
            recorder.recordTranscriptEvent(event)
        }
    }

    private static func runFullChain(
        caseID: String,
        audioStream: AsyncStream<[Float]>,
        targetRoute: StreamingInvocationRoute,
        coordinator: LocalConversationStreamingCoordinator,
        recorder: StreamingBenchmarkRecorder
    ) async throws {
        log("Full-chain started caseID=\(caseID) targetRoute=\(targetRoute.label)")
        let transcriptionMessageID = UUID()
        let transcriptionStream = coordinator.startLiveSpeechTranscription(
            messageID: transcriptionMessageID,
            audioStream: audioStream,
            sourceLanguage: .chinese
        )

        var finalTranscript = ""

        for try await event in transcriptionStream {
            recorder.recordLiveSpeechEvent(event)

            switch event {
            case .state(let state), .completed(let state):
                let normalizedTranscript = state.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedTranscript.isEmpty {
                    finalTranscript = state.fullTranscript
                }
            }
        }

        let normalizedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        log(
            "Transcription stream finished caseID=\(caseID) transcriptLength=\(normalizedTranscript.count) transcript=\(quotedPreview(normalizedTranscript))"
        )
        guard !normalizedTranscript.isEmpty else {
            throw SpeechRecognitionError.emptyTranscription
        }

        log("Starting translation caseID=\(caseID) targetLanguage=\(targetRoute.target.rawValue)")
        let translationStream = coordinator.startSpeechTranslation(
            messageID: UUID(),
            text: finalTranscript,
            sourceLanguage: .chinese,
            targetLanguage: targetRoute.target
        )

        var finalTranslation: String?

        for try await event in translationStream {
            recorder.recordTranslationEvent(event)

            switch event {
            case .state(let state):
                let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !displayText.isEmpty {
                    finalTranslation = state.displayText
                }
            case .completed(_, let text):
                finalTranslation = text
            }
        }

        log(
            "Translation stream finished caseID=\(caseID) finalTranslation=\(quotedPreview(finalTranslation))"
        )
    }

    private func resolveCorpusURL() throws -> URL {
        let bundle = Bundle(for: StreamingPerformanceTests.self)
        if let bundledURL = bundle.url(
            forResource: "translation_performance_corpus",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) {
            return bundledURL
        }

        if let bundledURL = bundle.url(
            forResource: "translation_performance_corpus",
            withExtension: "json"
        ) {
            return bundledURL
        }

        let fallbackURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("translation_performance_corpus.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            throw NSError(
                domain: "StreamingPerformanceTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Missing translation_performance_corpus.json fixture."]
            )
        }

        return fallbackURL
    }

    private func resolveManifestURL() throws -> URL {
        let bundle = Bundle(for: StreamingPerformanceTests.self)
        if let bundledURL = bundle.url(
            forResource: "streaming_audio_manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) {
            return bundledURL
        }

        if let bundledURL = bundle.url(
            forResource: "streaming_audio_manifest",
            withExtension: "json"
        ) {
            return bundledURL
        }

        let fallbackURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("streaming_audio_manifest.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            throw NSError(
                domain: "StreamingPerformanceTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Missing streaming_audio_manifest.json fixture."]
            )
        }

        return fallbackURL
    }

    private func resolveTranslationCatalogURL() throws -> URL {
        let mainBundle = Bundle.main
        let testBundle = Bundle(for: StreamingPerformanceTests.self)
        let candidateBundles = [mainBundle, testBundle]
        let relativePaths = [
            "Resource/translation-catalog.json",
            "translation-catalog.json"
        ]

        for bundle in candidateBundles {
            for relativePath in relativePaths {
                if let resourceURL = bundle.resourceURL {
                    let candidateURL = resourceURL.appendingPathComponent(relativePath, isDirectory: false)
                    if FileManager.default.fileExists(atPath: candidateURL.path) {
                        return candidateURL
                    }
                }
            }
        }

        let fallbackURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("link", isDirectory: true)
            .appendingPathComponent("Resource", isDirectory: true)
            .appendingPathComponent("translation-catalog.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            throw NSError(
                domain: "StreamingPerformanceTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled translation-catalog.json."]
            )
        }

        return fallbackURL
    }

    private func writeRunLog(_ result: StreamingBenchmarkRunResult) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let fileName = "streaming-benchmark-\(Self.fileTimestampString(from: result.runStartAt)).json"
        let outputDirectoryURL = try resolveBenchmarkLogDirectory()
        let outputURL = outputDirectoryURL.appendingPathComponent(fileName, isDirectory: false)

        try encoder.encode(result).write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func resolveBenchmarkLogDirectory() throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let benchmarkDirectory = baseDirectory
            .appendingPathComponent("Benchmarks", isDirectory: true)
            .appendingPathComponent("Streaming", isDirectory: true)

        try fileManager.createDirectory(
            at: benchmarkDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return benchmarkDirectory
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StreamingBenchmarkTimeoutError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static let executionModes: [StreamingExecutionMode] = [
        .recognitionOnly,
        .fullChain
    ]

    private static let benchmarkRoutes: [StreamingInvocationRoute] = [
        StreamingInvocationRoute(label: "zh-en", source: .chinese, target: .english),
        StreamingInvocationRoute(label: "zh-ja", source: .chinese, target: .japanese)
    ]

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func log(_ message: String) {
        print("[StreamingBenchmark] \(message)")
    }

    private static func logCaseResult(
        _ result: StreamingBenchmarkCaseResult,
        suiteName: String,
        mode: String,
        route: String
    ) {
        log(
            "Case completed suite=\(suiteName) mode=\(mode) route=\(route) caseID=\(result.caseID) caseDurationSeconds=\(formatSeconds(result.caseDurationSeconds)) firstTranscriptLatencyMs=\(formatOptionalMilliseconds(result.firstTranscriptLatencyMs)) firstStableTranscriptLatencyMs=\(formatOptionalMilliseconds(result.firstStableTranscriptLatencyMs)) finalTranscriptLatencyMs=\(formatOptionalMilliseconds(result.finalTranscriptLatencyMs)) firstTranslationLatencyMs=\(formatOptionalMilliseconds(result.firstTranslationLatencyMs)) finalTranslationLatencyMs=\(formatOptionalMilliseconds(result.finalTranslationLatencyMs)) transcriptRevisionCount=\(result.transcriptRevisionCount) translationRevisionCount=\(result.translationRevisionCount) stablePromotionCount=\(result.stablePromotionCount) endpointCount=\(result.endpointCount) finalTranscript=\(quotedPreview(result.finalTranscript)) finalTranslation=\(quotedPreview(result.finalTranslation))"
        )
    }

    private static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    private static func fileTimestampString(from date: Date) -> String {
        iso8601String(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static func secondsSince(_ startTick: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startTick) / 1_000_000_000
    }

    private static func megabytes(from bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    private static func formatMegabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f", megabytes(from: bytes))
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }

    private static func formatPercentage(_ percentage: Double) -> String {
        String(format: "%.2f", percentage)
    }

    private static func formatOptionalMilliseconds(_ milliseconds: Double?) -> String {
        guard let milliseconds else {
            return "n/a"
        }

        return formatPercentage(milliseconds)
    }

    private static func quotedPreview(_ text: String?) -> String {
        guard let text else {
            return "\"\""
        }

        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "\"\""
        }

        let preview = normalized.count > 80 ? String(normalized.prefix(80)) + "..." : normalized
        return "\"\(preview)\""
    }
}

private struct StreamingServiceContext {
    let translationPackageManager: TranslationModelPackageManager
    let translationService: MarianTranslationService
    let speechPackageManager: SpeechModelPackageManager
    let speechService: WhisperSpeechRecognitionService
    let coordinator: LocalConversationStreamingCoordinator
}

private struct StreamingBenchmarkSuite {
    let name: StreamingSuiteName
    let caseSpecifications: [StreamingBenchmarkCaseSpecification]
}

private struct StreamingBenchmarkCaseSpecification {
    let manifestEntry: StreamingAudioManifestEntry
    let corpusEntry: StreamingTranslationCorpusEntry
}

private struct StreamingInvocationRoute {
    let label: String
    let source: SupportedLanguage
    let target: SupportedLanguage
}

private struct StreamingBenchmarkTimeoutError: Error {}

private enum StreamingExecutionMode: String, Codable, Sendable {
    case recognitionOnly = "recognition-only"
    case fullChain = "full-chain"
}

private enum StreamingSuiteName: String, Codable, Sendable {
    case short
    case medium
    case long
    case mixed

    var label: String {
        "suite-stream-\(rawValue)"
    }
}

private struct StreamingExpectedResult: Codable, Sendable {
    let reference: String
    let mustPreserve: [String]
    let acceptanceNote: String
}

private struct StreamingExpectedLanguages: Codable, Sendable {
    let en: StreamingExpectedResult
    let ja: StreamingExpectedResult
}

private struct StreamingTranslationCorpusEntry: Codable, Sendable {
    let id: String
    let bucket: String
    let sourceText: String
    let charCount: Int
    let scenarioTag: String
    let expected: StreamingExpectedLanguages
}

private struct StreamingAudioManifestEntry: Codable, Sendable {
    let corpusID: String
    let suite: StreamingSuiteName
    let enabledModes: [StreamingExecutionMode]
    let speechRate: Double
    let variant: StreamingAudioVariant
    let pausePlan: [Int]
    let chunkDurationMs: Int
    let replayMode: AudioReplayMode
    let loopCount: Int
}

struct StreamingBenchmarkCaseResult: Codable, Sendable {
    let caseID: String
    let corpusID: String
    let iteration: Int
    let mode: String
    let routeLabel: String
    let variant: String
    let chunkDurationMs: Int
    let replayMode: String
    let caseStartAt: Date
    let caseEndAt: Date
    let caseDurationSeconds: Double
    let firstTranscriptLatencyMs: Double?
    let firstStableTranscriptLatencyMs: Double?
    let finalTranscriptLatencyMs: Double?
    let firstTranslationLatencyMs: Double?
    let finalTranslationLatencyMs: Double?
    let transcriptRevisionCount: Int
    let translationRevisionCount: Int
    let stablePromotionCount: Int
    let endpointCount: Int
    let finalTranscript: String
    let finalTranslation: String?
    let timedOut: Bool
    let failureReason: String?
}

struct StreamingBenchmarkSuiteResult: Codable, Sendable {
    let suiteName: String
    let mode: String
    let routeLabel: String
    let routeSource: String
    let routeTarget: String
    let suiteStartAt: Date
    let suiteEndAt: Date
    let suiteDurationSeconds: Double
    let callCount: Int
    let rssStartMB: Double
    let rssEndMB: Double
    let rssPeakMB: Double
    let cpuAveragePercent: Double
    let cpuPeakPercent: Double
    let failureCount: Int
    let timeoutCount: Int
    let caseResults: [StreamingBenchmarkCaseResult]
}

private struct StreamingBenchmarkRunResult: Codable, Sendable {
    let runStartAt: Date
    let runEndAt: Date
    let totalDurationSeconds: Double
    let suiteResults: [StreamingBenchmarkSuiteResult]
}
