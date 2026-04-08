//
//  StreamingBenchmarkRecorder.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import Darwin
import Foundation
@testable import link

struct ProcessCPUSample: Codable, Sendable {
    let timestamp: Date
    let cpuPercent: Double
}

actor ProcessCPUSampler {
    private let intervalNanoseconds: UInt64
    private var samples: [ProcessCPUSample] = []
    private var samplingTask: Task<Void, Never>?

    init(intervalNanoseconds: UInt64 = 100_000_000) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    func start() {
        guard samplingTask == nil else {
            return
        }

        recordCurrentSample()

        samplingTask = Task { [intervalNanoseconds] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else {
                    break
                }

                await self.recordCurrentSample()
            }
        }
    }

    func stop() async -> [ProcessCPUSample] {
        samplingTask?.cancel()
        samplingTask = nil
        recordCurrentSample()
        return samples.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated static func currentCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let taskResult = task_threads(mach_task_self_, &threads, &threadCount)
        guard taskResult == KERN_SUCCESS, let threads else {
            return 0
        }

        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            let address = vm_address_t(UInt(bitPattern: threads))
            vm_deallocate(mach_task_self_, address, size)
        }

        var totalCPUPercent = 0.0

        for index in 0 ..< Int(threadCount) {
            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { reboundPointer in
                    thread_info(
                        threads[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        reboundPointer,
                        &infoCount
                    )
                }
            }

            guard result == KERN_SUCCESS else {
                continue
            }

            if info.flags & TH_FLAGS_IDLE == 0 {
                totalCPUPercent += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }

        return totalCPUPercent
    }

    private func recordCurrentSample() {
        samples.append(
            ProcessCPUSample(
                timestamp: Date(),
                cpuPercent: Self.currentCPUPercent()
            )
        )
    }
}

struct StreamingBenchmarkRecordedMetrics: Codable, Sendable {
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
}

final class StreamingBenchmarkRecorder: @unchecked Sendable {
    private let caseStartAt = Date()
    private let caseStartTick = DispatchTime.now().uptimeNanoseconds

    private var firstTranscriptTick: UInt64?
    private var firstStableTranscriptTick: UInt64?
    private var finalTranscriptTick: UInt64?
    private var firstTranslationTick: UInt64?
    private var finalTranslationTick: UInt64?

    private var transcriptRevisionCount = 0
    private var translationRevisionCount = 0
    private var stablePromotionCount = 0
    private var endpointCount = 0

    private var lastTranscriptRevision: Int?
    private var lastTranslationRevision: Int?
    private var lastStableTranscript = ""
    private var wasEndpoint = false

    private var finalTranscript = ""
    private var finalTranslation: String?

    func recordTranscriptEvent(_ event: SpeechTranscriptEvent) {
        switch event {
        case .started:
            return
        case .updated(let snapshot), .completed(let snapshot):
            recordTranscriptSnapshot(
                stableTranscript: snapshot.stableTranscript,
                provisionalTranscript: snapshot.provisionalTranscript,
                liveTranscript: snapshot.liveTranscript,
                revision: snapshot.revision,
                isEndpoint: snapshot.isEndpoint
            )

            if case .completed = event {
                finalTranscriptTick = finalTranscriptTick ?? DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    func recordLiveSpeechEvent(_ event: LiveSpeechTranscriptionEvent) {
        switch event {
        case .state(let state), .completed(let state):
            recordTranscriptSnapshot(
                stableTranscript: state.stableTranscript,
                provisionalTranscript: state.provisionalTranscript,
                liveTranscript: state.liveTranscript,
                revision: state.transcriptRevision,
                isEndpoint: state.isEndpoint
            )

            if case .completed = event {
                finalTranscriptTick = finalTranscriptTick ?? DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    func recordTranslationEvent(_ event: ConversationStreamingEvent) {
        switch event {
        case .state(let state):
            if state.revision != lastTranslationRevision {
                translationRevisionCount += 1
                lastTranslationRevision = state.revision
            }

            let displayText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayText.isEmpty {
                firstTranslationTick = firstTranslationTick ?? DispatchTime.now().uptimeNanoseconds
                finalTranslation = state.displayText
            }
        case .completed(_, let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                firstTranslationTick = firstTranslationTick ?? DispatchTime.now().uptimeNanoseconds
                finalTranslation = text
            }
            finalTranslationTick = DispatchTime.now().uptimeNanoseconds
        }
    }

    func finish() -> StreamingBenchmarkRecordedMetrics {
        let caseEndAt = Date()
        let caseEndTick = DispatchTime.now().uptimeNanoseconds

        return StreamingBenchmarkRecordedMetrics(
            caseStartAt: caseStartAt,
            caseEndAt: caseEndAt,
            caseDurationSeconds: Self.seconds(between: caseStartTick, and: caseEndTick),
            firstTranscriptLatencyMs: Self.milliseconds(from: caseStartTick, to: firstTranscriptTick),
            firstStableTranscriptLatencyMs: Self.milliseconds(from: caseStartTick, to: firstStableTranscriptTick),
            finalTranscriptLatencyMs: Self.milliseconds(from: caseStartTick, to: finalTranscriptTick),
            firstTranslationLatencyMs: Self.milliseconds(from: caseStartTick, to: firstTranslationTick),
            finalTranslationLatencyMs: Self.milliseconds(from: caseStartTick, to: finalTranslationTick),
            transcriptRevisionCount: transcriptRevisionCount,
            translationRevisionCount: translationRevisionCount,
            stablePromotionCount: stablePromotionCount,
            endpointCount: endpointCount,
            finalTranscript: finalTranscript,
            finalTranslation: finalTranslation
        )
    }

    private func recordTranscriptSnapshot(
        stableTranscript: String,
        provisionalTranscript: String,
        liveTranscript: String,
        revision: Int,
        isEndpoint: Bool
    ) {
        let tick = DispatchTime.now().uptimeNanoseconds
        firstTranscriptTick = firstTranscriptTick ?? tick

        if revision != lastTranscriptRevision {
            transcriptRevisionCount += 1
            lastTranscriptRevision = revision
        }

        let normalizedStableTranscript = stableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedStableTranscript.isEmpty {
            firstStableTranscriptTick = firstStableTranscriptTick ?? tick
            if normalizedStableTranscript != lastStableTranscript {
                stablePromotionCount += 1
                lastStableTranscript = normalizedStableTranscript
            }
        }

        if isEndpoint && !wasEndpoint {
            endpointCount += 1
        }
        wasEndpoint = isEndpoint

        let transcript = stableTranscript + provisionalTranscript + liveTranscript
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        finalTranscript = normalizedTranscript.isEmpty ? transcript : normalizedTranscript
    }

    private static func milliseconds(from startTick: UInt64, to endTick: UInt64?) -> Double? {
        guard let endTick else {
            return nil
        }

        return Double(endTick - startTick) / 1_000_000
    }

    private static func seconds(between startTick: UInt64, and endTick: UInt64) -> Double {
        Double(endTick - startTick) / 1_000_000_000
    }
}
