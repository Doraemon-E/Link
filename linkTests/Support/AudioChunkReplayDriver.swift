//
//  AudioChunkReplayDriver.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import Foundation

enum AudioReplayMode: String, Codable, Sendable {
    case realtime
    case flood
}

struct AudioChunkReplayDriver: Sendable {
    let sampleRate: Int

    init(sampleRate: Int = 16_000) {
        self.sampleRate = sampleRate
    }

    func makeStream(
        samples: [Float],
        chunkDurationMilliseconds: Int,
        replayMode: AudioReplayMode
    ) -> AsyncStream<[Float]> {
        let normalizedChunkDuration = max(chunkDurationMilliseconds, 1)
        let samplesPerChunk = max(
            Int((Double(sampleRate) * Double(normalizedChunkDuration) / 1_000.0).rounded()),
            1
        )

        return AsyncStream { continuation in
            let task = Task {
                var startIndex = 0

                while startIndex < samples.count, !Task.isCancelled {
                    let endIndex = min(startIndex + samplesPerChunk, samples.count)
                    let emittedSampleCount = endIndex - startIndex
                    continuation.yield(Array(samples[startIndex ..< endIndex]))
                    startIndex = endIndex

                    if replayMode == .realtime {
                        let emittedDurationMilliseconds = Int(
                            (Double(emittedSampleCount) / Double(sampleRate) * 1_000.0)
                                .rounded()
                        )
                        let sleepMilliseconds = max(emittedDurationMilliseconds, normalizedChunkDuration)
                        try? await Task.sleep(
                            nanoseconds: UInt64(sleepMilliseconds) * 1_000_000
                        )
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
