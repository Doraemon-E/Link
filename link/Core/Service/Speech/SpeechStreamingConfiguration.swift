//
//  SpeechStreamingConfiguration.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

nonisolated struct SpeechStreamingConfiguration: Sendable {
    nonisolated struct InferenceConfiguration: Sendable {
        let stepDuration: TimeInterval
        let streamingWindowDuration: TimeInterval
        let minimumStreamingDuration: TimeInterval
        let minimumFinalizationDuration: TimeInterval
        let maxTokenCount: Int32
        let audioContextSize: Int32
        let noSpeechThreshold: Float
    }

    let sampleRate: Int
    let threadLimit: Int32
    let useGPU: Bool
    let inference: InferenceConfiguration
    let activityGate: SpeechActivityGate.Configuration

    static let `default` = SpeechStreamingConfiguration(
        sampleRate: 16_000,
        threadLimit: 4,
        useGPU: true,
        inference: InferenceConfiguration(
            stepDuration: 0.9,
            streamingWindowDuration: 6.0,
            minimumStreamingDuration: 0.65,
            minimumFinalizationDuration: 0.40,
            maxTokenCount: 48,
            audioContextSize: 768,
            noSpeechThreshold: 0.9
        ),
        activityGate: .default
    )

    var stepSampleCount: Int {
        sampleCount(for: inference.stepDuration)
    }

    var streamingWindowSampleCount: Int {
        sampleCount(for: inference.streamingWindowDuration)
    }

    var minimumStreamingSampleCount: Int {
        sampleCount(for: inference.minimumStreamingDuration)
    }

    var minimumFinalizationSampleCount: Int {
        sampleCount(for: inference.minimumFinalizationDuration)
    }

    func sampleCount(for duration: TimeInterval) -> Int {
        Int((duration * Double(sampleRate)).rounded())
    }
}
