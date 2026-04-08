//
//  ProcessMemorySampler.swift
//  linkTests
//
//  Created by Codex on 2026/4/8.
//

import Foundation
import Darwin

actor ProcessMemorySampler {
    struct Sample: Codable, Sendable {
        let timestamp: Date
        let residentSizeBytes: UInt64
    }

    private let intervalNanoseconds: UInt64
    private var samples: [Sample] = []
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

    func stop() async -> [Sample] {
        samplingTask?.cancel()
        samplingTask = nil
        recordCurrentSample()
        return samples.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated static func currentResidentSizeBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.resident_size)
    }

    private func recordCurrentSample() {
        samples.append(
            Sample(
                timestamp: Date(),
                residentSizeBytes: Self.currentResidentSizeBytes()
            )
        )
    }
}
