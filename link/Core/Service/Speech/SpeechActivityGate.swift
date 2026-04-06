//
//  SpeechActivityGate.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated struct SpeechActivityGate: Sendable {
    nonisolated struct Configuration: Sendable {
        let activationDuration: TimeInterval
        let preRollDuration: TimeInterval
        let endpointSilenceDuration: TimeInterval
        let rmsThreshold: Float
        let peakThreshold: Float

        static let `default` = Configuration(
            activationDuration: 0.12,
            preRollDuration: 0.28,
            endpointSilenceDuration: 0.72,
            rmsThreshold: 0.010,
            peakThreshold: 0.050
        )
    }

    nonisolated struct ChunkStatistics: Sendable {
        let peak: Float
        let rms: Float

        var containsSpeech: Bool
    }

    nonisolated struct Update: Sendable {
        let appendedSamples: [Float]
        let statistics: ChunkStatistics
        let didStartSpeech: Bool
        let isSpeechActive: Bool
        let isEndpoint: Bool
        let trailingSilenceDuration: TimeInterval
    }

    private let configuration: Configuration
    private let sampleRate: Int
    private var isSpeechActive = false
    private var pendingSpeechChunks: [[Float]] = []
    private var pendingSpeechSampleCount = 0
    private var preRollChunks: [[Float]] = []
    private var preRollSampleCount = 0
    private var silenceSampleCount = 0

    init(
        configuration: Configuration,
        sampleRate: Int
    ) {
        self.configuration = configuration
        self.sampleRate = sampleRate
    }

    mutating func consume(_ samples: [Float]) -> Update {
        let statistics = chunkStatistics(for: samples)

        if isSpeechActive {
            return consumeActiveChunk(samples, statistics: statistics)
        }

        return consumeIdleChunk(samples, statistics: statistics)
    }

    private mutating func consumeIdleChunk(
        _ samples: [Float],
        statistics: ChunkStatistics
    ) -> Update {
        guard statistics.containsSpeech else {
            flushPendingSpeechIntoPreRoll()
            bufferPreRoll(samples)
            return Update(
                appendedSamples: [],
                statistics: statistics,
                didStartSpeech: false,
                isSpeechActive: false,
                isEndpoint: false,
                trailingSilenceDuration: 0
            )
        }

        pendingSpeechChunks.append(samples)
        pendingSpeechSampleCount += samples.count
        guard pendingSpeechSampleCount >= activationSampleCount else {
            return Update(
                appendedSamples: [],
                statistics: statistics,
                didStartSpeech: false,
                isSpeechActive: false,
                isEndpoint: false,
                trailingSilenceDuration: 0
            )
        }

        isSpeechActive = true
        silenceSampleCount = 0

        var appendedSamples = drainPreRoll()
        appendedSamples += drainPendingSpeech()
        return Update(
            appendedSamples: appendedSamples,
            statistics: statistics,
            didStartSpeech: true,
            isSpeechActive: true,
            isEndpoint: false,
            trailingSilenceDuration: 0
        )
    }

    private mutating func consumeActiveChunk(
        _ samples: [Float],
        statistics: ChunkStatistics
    ) -> Update {
        if statistics.containsSpeech {
            silenceSampleCount = 0
        } else {
            silenceSampleCount += samples.count
        }

        let trailingSilenceDuration = statistics.containsSpeech
            ? 0
            : TimeInterval(silenceSampleCount) / TimeInterval(sampleRate)
        let isEndpoint = !statistics.containsSpeech && silenceSampleCount >= endpointSampleCount
        if isEndpoint {
            isSpeechActive = false
            silenceSampleCount = 0
            bufferPreRoll(samples)
        }

        return Update(
            appendedSamples: samples,
            statistics: statistics,
            didStartSpeech: false,
            isSpeechActive: isSpeechActive,
            isEndpoint: isEndpoint,
            trailingSilenceDuration: trailingSilenceDuration
        )
    }

    private mutating func bufferPreRoll(_ samples: [Float]) {
        guard !samples.isEmpty else {
            return
        }

        preRollChunks.append(samples)
        preRollSampleCount += samples.count
        trimPreRollIfNeeded()
    }

    private mutating func trimPreRollIfNeeded() {
        let maximumPreRollSampleCount = preRollSampleCountLimit
        guard preRollSampleCount > maximumPreRollSampleCount else {
            return
        }

        while preRollSampleCount > maximumPreRollSampleCount, !preRollChunks.isEmpty {
            preRollSampleCount -= preRollChunks.removeFirst().count
        }
    }

    private mutating func flushPendingSpeechIntoPreRoll() {
        guard !pendingSpeechChunks.isEmpty else {
            return
        }

        for chunk in pendingSpeechChunks {
            bufferPreRoll(chunk)
        }
        pendingSpeechChunks.removeAll(keepingCapacity: false)
        pendingSpeechSampleCount = 0
    }

    private mutating func drainPendingSpeech() -> [Float] {
        let chunks = pendingSpeechChunks
        pendingSpeechChunks.removeAll(keepingCapacity: false)
        pendingSpeechSampleCount = 0
        return chunks.flatMap { $0 }
    }

    private mutating func drainPreRoll() -> [Float] {
        let chunks = preRollChunks
        preRollChunks.removeAll(keepingCapacity: false)
        preRollSampleCount = 0
        return chunks.flatMap { $0 }
    }

    private func chunkStatistics(for samples: [Float]) -> ChunkStatistics {
        guard !samples.isEmpty else {
            return ChunkStatistics(peak: 0, rms: 0, containsSpeech: false)
        }

        var peak = Float.zero
        var energy = Double.zero

        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            let value = Double(sample)
            energy += value * value
        }

        let rms = Float(sqrt(energy / Double(max(samples.count, 1))))
        return ChunkStatistics(
            peak: peak,
            rms: rms,
            containsSpeech: rms >= configuration.rmsThreshold || peak >= configuration.peakThreshold
        )
    }

    private var activationSampleCount: Int {
        Int((configuration.activationDuration * Double(sampleRate)).rounded())
    }

    private var endpointSampleCount: Int {
        Int((configuration.endpointSilenceDuration * Double(sampleRate)).rounded())
    }

    private var preRollSampleCountLimit: Int {
        Int((configuration.preRollDuration * Double(sampleRate)).rounded())
    }
}
