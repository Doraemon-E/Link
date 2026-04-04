//
//  AppLogger.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import OSLog

struct AppLogContext: Sendable {
    let traceID: String
    let metadata: [String: String]

    func merging(_ additionalMetadata: [String: String]) -> AppLogContext {
        var mergedMetadata = metadata

        for (key, value) in additionalMetadata where !value.isEmpty {
            mergedMetadata[key] = value
        }

        return AppLogContext(traceID: traceID, metadata: mergedMetadata)
    }
}

enum AppTrace {
    @TaskLocal
    static var current: AppLogContext?

    static func newTraceID() -> String {
        UUID().uuidString.lowercased()
    }

    static func withTrace<T>(
        traceID: String = newTraceID(),
        metadata: [String: String] = [:],
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(AppLogContext(traceID: traceID, metadata: metadata)) {
            try await operation()
        }
    }

    static func withMetadata<T>(
        _ metadata: [String: String],
        operation: () async throws -> T
    ) async rethrows -> T {
        let baseContext = current ?? AppLogContext(traceID: newTraceID(), metadata: [:])
        return try await $current.withValue(baseContext.merging(metadata)) {
            try await operation()
        }
    }
}

struct AppLogger: Sendable {
    private let logger: Logger

    init(category: String) {
        logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "link",
            category: category
        )
    }

    func debug(_ message: String, metadata: [String: String] = [:]) {
        log(level: .debug, message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(level: .info, message, metadata: metadata)
    }

    func notice(_ message: String, metadata: [String: String] = [:]) {
        log(level: .default, message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        log(level: .error, message, metadata: metadata)
    }

    private func log(level: OSLogType, _ message: String, metadata: [String: String]) {
        let mergedMetadata = mergedMetadata(with: metadata)
        let renderedMessage = Self.render(message: message, metadata: mergedMetadata)
        logger.log(level: level, "\(renderedMessage, privacy: .public)")
    }

    private func mergedMetadata(with metadata: [String: String]) -> [String: String] {
        var mergedMetadata = AppTrace.current?.metadata ?? [:]

        for (key, value) in metadata where !value.isEmpty {
            mergedMetadata[key] = value
        }

        if let traceID = AppTrace.current?.traceID {
            mergedMetadata["trace_id"] = traceID
        }

        return mergedMetadata
    }

    private static func render(message: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else {
            return message
        }

        let suffix = metadata
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return "\(message) | \(suffix)"
    }
}

extension AppLogger {
    static let viewModel = AppLogger(category: "view-model")
    static let translation = AppLogger(category: "translation")
    static let translationInstaller = AppLogger(category: "translation-installer")
    static let translationCatalog = AppLogger(category: "translation-catalog")
    static let translationTokenizer = AppLogger(category: "translation-tokenizer")
}

func appLogErrorDescription(_ error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if !message.isEmpty {
        return message
    }

    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

func appElapsedMilliseconds(since startDate: Date) -> String {
    String(Int(Date().timeIntervalSince(startDate) * 1000))
}
