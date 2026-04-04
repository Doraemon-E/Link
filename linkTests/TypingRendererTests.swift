//
//  TypingRendererTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class TypingRendererTests: XCTestCase {
    func testChineseShortTextStreamsCharacterByCharacter() async throws {
        let outputs = try await collectOutputs(
            from: TypingRenderer.stream(
                text: "你好世界",
                language: .chinese,
                sleep: Self.immediateSleep
            )
        )

        XCTAssertEqual(outputs, ["你", "你好", "你好世", "你好世界"])
    }

    func testLongTextDurationIsCapped() {
        let longText = String(repeating: "streaming translation ", count: 24)
        let plan = TypingRenderer.plan(for: longText, language: .english)

        XCTAssertLessThanOrEqual(plan.totalDurationNanoseconds, TypingRenderer.maximumDurationNanoseconds)
    }

    func testCancellationStopsBeforeAllStepsAreRendered() async throws {
        let expectation = expectation(description: "Typing stream cancels early")

        let stream = TypingRenderer.stream(
            text: "cancel this long enough english sentence please",
            language: .english,
            sleep: { _ in
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        )

        let task = Task { () -> [String] in
            var outputs: [String] = []

            do {
                for try await output in stream {
                    outputs.append(output)

                    if outputs.count == 1 {
                        withUnsafeCurrentTask { currentTask in
                            currentTask?.cancel()
                        }
                    }
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            expectation.fulfill()
            return outputs
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        let outputs = await task.value
        XCTAssertEqual(outputs.count, 1)
    }

    private func collectOutputs(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> [String] {
        var outputs: [String] = []

        for try await output in stream {
            outputs.append(output)
        }

        return outputs
    }

    private static func immediateSleep(nanoseconds: UInt64) async throws {
        _ = nanoseconds
    }
}
