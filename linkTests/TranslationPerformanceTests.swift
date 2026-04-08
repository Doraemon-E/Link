//
//  TranslationPerformanceTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import Foundation
import XCTest
@testable import link

final class TranslationPerformanceTests: XCTestCase {
    func testTranslationPerformanceBenchmark() async throws {
        continueAfterFailure = true

        let runStartAt = Date()
        let runStartTick = DispatchTime.now().uptimeNanoseconds
        Self.log("Run started at \(Self.iso8601String(from: runStartAt))")

        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.count, 15, "Expected 15 corpus entries.")
        XCTAssertEqual(corpus.filter { $0.bucket == .short }.count, 5, "Expected 5 short entries.")
        XCTAssertEqual(corpus.filter { $0.bucket == .medium }.count, 5, "Expected 5 medium entries.")
        XCTAssertEqual(corpus.filter { $0.bucket == .long }.count, 5, "Expected 5 long entries.")
        XCTAssertEqual(
            corpus.filter { $0.scenarioTag == "daily_chat" }.count,
            15,
            "Expected every entry to use the daily_chat scenario."
        )
        XCTAssertTrue(
            corpus.allSatisfy { $0.charCount == $0.sourceText.count },
            "Expected charCount to match sourceText.count for every entry."
        )

        let serviceContext = try makeServiceContext()
        let routes = try await preflightRoutes(using: serviceContext.service)

        guard try await ensureInstalledModels(for: routes, packageManager: serviceContext.packageManager) else {
            return
        }

        let suites = makeSuites(from: corpus)
        var suiteResults: [TranslationBenchmarkSuiteResult] = []

        for suite in suites {
            for route in Self.benchmarkRoutes {
                let result = try await runSuite(
                    suite,
                    route: route,
                    service: serviceContext.service
                )
                suiteResults.append(result)
            }
        }

        let runEndAt = Date()
        let totalDurationSeconds = Self.secondsSince(runStartTick)
        let runResult = TranslationBenchmarkRunResult(
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
            XCTFail("Translation benchmark finished with failures. See log at \(logURL.path)")
        }
    }

    private func loadCorpus() throws -> [TranslationPerformanceCorpusEntry] {
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: try resolveCorpusURL())
        return try decoder.decode([TranslationPerformanceCorpusEntry].self, from: data)
    }

    private func makeServiceContext() throws -> TranslationServiceContext {
        let catalogURL = try resolveCatalogURL()
        let catalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: Bundle(for: TranslationPerformanceTests.self),
            bundledCatalogURLOverride: catalogURL
        )
        let packageManager = TranslationModelPackageManager(catalogRepository: catalogRepository)
        let service = MarianTranslationService(modelProvider: packageManager)
        return TranslationServiceContext(
            packageManager: packageManager,
            service: service
        )
    }

    private func preflightRoutes(
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
        for benchmarkRoutes: [TranslationRoute],
        packageManager: TranslationModelPackageManager
    ) async throws -> Bool {
        var missingSteps: [String] = []

        for benchmarkRoute in benchmarkRoutes {
            for step in benchmarkRoute.steps {
                let installation = try await packageManager.installedPackage(
                    for: step.source,
                    target: step.target
                )
                if installation == nil {
                    missingSteps.append("\(step.source.compactDisplayName)->\(step.target.compactDisplayName)")
                }
            }
        }

        let uniqueMissingSteps = Array(Set(missingSteps)).sorted()
        guard uniqueMissingSteps.isEmpty else {
            XCTFail("Missing installed translation models for routes: \(uniqueMissingSteps.joined(separator: ", "))")
            return false
        }

        return true
    }

    private func makeSuites(from corpus: [TranslationPerformanceCorpusEntry]) -> [TranslationBenchmarkSuite] {
        let shortEntries = corpus.filter { $0.bucket == .short }
        let mediumEntries = corpus.filter { $0.bucket == .medium }
        let longEntries = corpus.filter { $0.bucket == .long }
        var mixedEntries: [TranslationPerformanceCorpusEntry] = []

        for index in 0 ..< shortEntries.count {
            mixedEntries.append(shortEntries[index])
            mixedEntries.append(mediumEntries[index])
            mixedEntries.append(longEntries[index])
        }

        return [
            TranslationBenchmarkSuite(name: "all-short", entries: shortEntries, iterations: 20),
            TranslationBenchmarkSuite(name: "all-medium", entries: mediumEntries, iterations: 12),
            TranslationBenchmarkSuite(name: "all-long", entries: longEntries, iterations: 6),
            TranslationBenchmarkSuite(name: "mixed", entries: mixedEntries, iterations: 6)
        ]
    }

    private func runSuite(
        _ suite: TranslationBenchmarkSuite,
        route: TranslationInvocationRoute,
        service: MarianTranslationService
    ) async throws -> TranslationBenchmarkSuiteResult {
        let suiteStartAt = Date()
        let suiteStartTick = DispatchTime.now().uptimeNanoseconds
        let callCount = suite.entries.count * suite.iterations
        let memorySampler = ProcessMemorySampler()
        let rssStartBytes = ProcessMemorySampler.currentResidentSizeBytes()

        Self.log(
            "Suite started suite=\(suite.name) route=\(route.label) suiteStartAt=\(Self.iso8601String(from: suiteStartAt)) callCount=\(callCount) rssStartMB=\(Self.formatMegabytes(rssStartBytes))"
        )

        await memorySampler.start()

        var totalCallDurationNanoseconds: UInt64 = 0
        var slowestCallDurationNanoseconds: UInt64 = 0
        var failures: [TranslationBenchmarkFailure] = []

        for iteration in 1 ... suite.iterations {
            for entry in suite.entries {
                let callStartTick = DispatchTime.now().uptimeNanoseconds

                do {
                    let translatedText = try await service.translate(
                        text: entry.sourceText,
                        source: route.source,
                        target: route.target
                    )
                    let trimmedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedText.isEmpty {
                        let failure = TranslationBenchmarkFailure(
                            entryID: entry.id,
                            iteration: iteration,
                            errorDescription: "Translation returned an empty string."
                        )
                        failures.append(failure)
                        Self.logFailure(failure, suiteName: suite.name, route: route.label)
                    }
                } catch {
                    let failure = TranslationBenchmarkFailure(
                        entryID: entry.id,
                        iteration: iteration,
                        errorDescription: error.localizedDescription
                    )
                    failures.append(failure)
                    Self.logFailure(failure, suiteName: suite.name, route: route.label)
                }

                let callDurationNanoseconds = DispatchTime.now().uptimeNanoseconds - callStartTick
                totalCallDurationNanoseconds += callDurationNanoseconds
                slowestCallDurationNanoseconds = max(
                    slowestCallDurationNanoseconds,
                    callDurationNanoseconds
                )
            }
        }

        let samples = await memorySampler.stop()
        let suiteEndAt = Date()
        let suiteDurationSeconds = Self.secondsSince(suiteStartTick)
        let rssEndBytes = samples.last?.residentSizeBytes ?? ProcessMemorySampler.currentResidentSizeBytes()
        let rssPeakBytes = samples.map(\.residentSizeBytes).max() ?? rssEndBytes
        let averageCallDurationMs = callCount > 0
            ? (Double(totalCallDurationNanoseconds) / Double(callCount)) / 1_000_000
            : 0
        let slowestCallDurationMs = Double(slowestCallDurationNanoseconds) / 1_000_000

        let result = TranslationBenchmarkSuiteResult(
            suiteName: suite.name,
            routeLabel: route.label,
            routeSource: route.source.rawValue,
            routeTarget: route.target.rawValue,
            suiteStartAt: suiteStartAt,
            suiteEndAt: suiteEndAt,
            suiteDurationSeconds: suiteDurationSeconds,
            callCount: callCount,
            averageCallDurationMs: averageCallDurationMs,
            slowestCallDurationMs: slowestCallDurationMs,
            rssStartMB: Self.megabytes(from: rssStartBytes),
            rssEndMB: Self.megabytes(from: rssEndBytes),
            rssPeakMB: Self.megabytes(from: rssPeakBytes),
            failureCount: failures.count,
            failures: failures
        )

        Self.log(
            "Suite completed suite=\(suite.name) route=\(route.label) suiteEndAt=\(Self.iso8601String(from: suiteEndAt)) suiteDurationSeconds=\(Self.formatSeconds(result.suiteDurationSeconds)) averageCallDurationMs=\(Self.formatMilliseconds(result.averageCallDurationMs)) slowestCallDurationMs=\(Self.formatMilliseconds(result.slowestCallDurationMs)) rssEndMB=\(Self.formatMegabytes(rssEndBytes)) rssPeakMB=\(Self.formatMegabytes(rssPeakBytes)) failureCount=\(result.failureCount)"
        )

        return result
    }

    private func resolveCorpusURL() throws -> URL {
        let bundle = Bundle(for: TranslationPerformanceTests.self)
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
                domain: "TranslationPerformanceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing translation_performance_corpus.json fixture."]
            )
        }

        return fallbackURL
    }

    private func resolveCatalogURL() throws -> URL {
        let mainBundle = Bundle.main
        let testBundle = Bundle(for: TranslationPerformanceTests.self)

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
                domain: "TranslationPerformanceTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled translation-catalog.json."]
            )
        }

        return fallbackURL
    }

    private func writeRunLog(_ result: TranslationBenchmarkRunResult) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let fileName = "translation-benchmark-\(Self.fileTimestampString(from: result.runStartAt)).json"
        let outputDirectoryURL = try resolveBenchmarkLogDirectory()
        let outputURL = outputDirectoryURL
            .appendingPathComponent(fileName, isDirectory: false)

        try encoder.encode(result).write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func resolveBenchmarkLogDirectory() throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let benchmarkDirectory = baseDirectory
            .appendingPathComponent("Benchmarks", isDirectory: true)
            .appendingPathComponent("Translation", isDirectory: true)

        try fileManager.createDirectory(
            at: benchmarkDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return benchmarkDirectory
    }

    private static let benchmarkRoutes: [TranslationInvocationRoute] = [
        TranslationInvocationRoute(label: "zh-en", source: .chinese, target: .english),
        TranslationInvocationRoute(label: "zh-ja", source: .chinese, target: .japanese)
    ]

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func log(_ message: String) {
        print("[TranslationBenchmark] \(message)")
    }

    private static func logFailure(
        _ failure: TranslationBenchmarkFailure,
        suiteName: String,
        route: String
    ) {
        log(
            "Call failed suite=\(suiteName) route=\(route) entryID=\(failure.entryID) iteration=\(failure.iteration) error=\(failure.errorDescription)"
        )
    }

    private static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    private static func fileTimestampString(from date: Date) -> String {
        iso8601String(from: date)
            .replacingOccurrences(of: ":", with: "-")
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

    private static func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}

private struct TranslationServiceContext {
    let packageManager: TranslationModelPackageManager
    let service: MarianTranslationService
}

private struct TranslationBenchmarkSuite {
    let name: String
    let entries: [TranslationPerformanceCorpusEntry]
    let iterations: Int
}

private struct TranslationInvocationRoute {
    let label: String
    let source: SupportedLanguage
    let target: SupportedLanguage
}

struct TranslationExpectedResult: Codable, Sendable {
    let reference: String
    let mustPreserve: [String]
    let acceptanceNote: String
}

struct TranslationExpectedLanguages: Codable, Sendable {
    let en: TranslationExpectedResult
    let ja: TranslationExpectedResult
}

struct TranslationPerformanceCorpusEntry: Codable, Sendable {
    enum Bucket: String, Codable, Sendable {
        case short
        case medium
        case long
    }

    let id: String
    let bucket: Bucket
    let sourceText: String
    let charCount: Int
    let scenarioTag: String
    let expected: TranslationExpectedLanguages
}

struct TranslationBenchmarkSuiteResult: Codable, Sendable {
    let suiteName: String
    let routeLabel: String
    let routeSource: String
    let routeTarget: String
    let suiteStartAt: Date
    let suiteEndAt: Date
    let suiteDurationSeconds: Double
    let callCount: Int
    let averageCallDurationMs: Double
    let slowestCallDurationMs: Double
    let rssStartMB: Double
    let rssEndMB: Double
    let rssPeakMB: Double
    let failureCount: Int
    let failures: [TranslationBenchmarkFailure]
}

private struct TranslationBenchmarkRunResult: Codable, Sendable {
    let runStartAt: Date
    let runEndAt: Date
    let totalDurationSeconds: Double
    let suiteResults: [TranslationBenchmarkSuiteResult]
}

struct TranslationBenchmarkFailure: Codable, Sendable {
    let entryID: String
    let iteration: Int
    let errorDescription: String
}
