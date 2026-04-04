//
//  ResumableArchiveDownloader.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

struct PersistedModelDownloadState: Codable, Equatable, Sendable {
    let packageId: String
    let archiveURL: URL
    let archiveSize: Int64
    let etag: String?
    let lastModified: String?
    let downloadedBytes: Int64
    let updatedAt: Date
}

struct RemoteArchiveMetadata: Equatable, Sendable {
    let contentLength: Int64
    let etag: String?
    let lastModified: String?
    let acceptsByteRanges: Bool
}

enum ResumableArchiveDownloaderError: LocalizedError {
    case invalidResponse(String)
    case missingContentLength
    case metadataMismatch(String)
    case downloadFailed(String)
    case filesystemFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return detail
        case .missingContentLength:
            return "The server did not provide a valid content length."
        case .metadataMismatch(let detail):
            return detail
        case .downloadFailed(let detail):
            return detail
        case .filesystemFailure(let detail):
            return detail
        }
    }
}

actor ResumableArchiveDownloader {
    private let chunkSize: Int64
    private let retryDelays: [UInt64]
    private let session: URLSession

    init(
        chunkSize: Int64 = 8 * 1_024 * 1_024,
        retryDelays: [UInt64] = [1, 2, 4, 8, 16]
    ) {
        self.chunkSize = chunkSize
        self.retryDelays = retryDelays

        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    func download(
        descriptor: ModelDownloadDescriptor,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws -> URL {
        try await download(
            descriptor: descriptor,
            allowAutomaticRestart: true,
            progressHandler: progressHandler
        )
    }

    func persistedStates(for kind: ModelAssetKind) throws -> [PersistedModelDownloadState] {
        let downloadsDirectoryURL = try ModelStoragePaths.downloadsDirectoryURL(for: kind)
        guard FileManager.default.fileExists(atPath: downloadsDirectoryURL.path) else {
            return []
        }

        let candidateDirectories = try FileManager.default.contentsOfDirectory(
            at: downloadsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return candidateDirectories.compactMap { directoryURL in
            let stateURL = directoryURL.appendingPathComponent("state.json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: stateURL.path) else {
                return nil
            }

            do {
                let data = try Data(contentsOf: stateURL)
                return try decoder.decode(PersistedModelDownloadState.self, from: data)
            } catch {
                return nil
            }
        }
    }

    func persistedProgress(for descriptor: ModelDownloadDescriptor) throws -> ModelDownloadProgress? {
        guard let state = try loadPersistedState(for: descriptor) else {
            return nil
        }

        let partialArchiveURL = try ModelStoragePaths.partialArchiveURL(for: descriptor)
        let actualBytes = try fileSize(at: partialArchiveURL) ?? state.downloadedBytes

        return ModelDownloadProgress(
            phase: .pausedResumable,
            downloadedBytes: actualBytes,
            totalBytes: max(state.archiveSize, descriptor.archiveSize),
            isResumable: actualBytes > 0
        )
    }

    func removePersistedDownload(for descriptor: ModelDownloadDescriptor) throws {
        let downloadDirectoryURL = try ModelStoragePaths.downloadDirectoryURL(for: descriptor)
        if FileManager.default.fileExists(atPath: downloadDirectoryURL.path) {
            try FileManager.default.removeItem(at: downloadDirectoryURL)
        }
    }

    private func download(
        descriptor: ModelDownloadDescriptor,
        allowAutomaticRestart: Bool,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws -> URL {
        let metadata = try await fetchRemoteMetadata(for: descriptor)
        let downloadDirectoryURL = try ModelStoragePaths.downloadDirectoryURL(for: descriptor)
        let partialArchiveURL = try ModelStoragePaths.partialArchiveURL(for: descriptor)
        let stateURL = try ModelStoragePaths.persistedStateURL(for: descriptor)

        try ensureDirectoryExists(at: downloadDirectoryURL)
        try ensureFileExists(at: partialArchiveURL)

        if let persistedState = try loadPersistedState(for: descriptor),
           !isPersistedStateValid(
                persistedState,
                descriptor: descriptor,
                metadata: metadata,
                partialArchiveURL: partialArchiveURL
           ) {
            try resetPersistedDownload(for: descriptor)
            try ensureDirectoryExists(at: downloadDirectoryURL)
            try ensureFileExists(at: partialArchiveURL)
        }

        let existingBytes = min(
            try fileSize(at: partialArchiveURL) ?? 0,
            max(metadata.contentLength, descriptor.archiveSize)
        )
        var downloadedBytes = existingBytes

        if let state = try loadPersistedState(for: descriptor),
           state.downloadedBytes != downloadedBytes {
            try saveState(
                PersistedModelDownloadState(
                    packageId: descriptor.packageId,
                    archiveURL: descriptor.archiveURL,
                    archiveSize: metadata.contentLength,
                    etag: metadata.etag,
                    lastModified: metadata.lastModified,
                    downloadedBytes: downloadedBytes,
                    updatedAt: .now
                ),
                to: stateURL
            )
        }

        await progressHandler(
            ModelDownloadProgress(
                phase: .preparing,
                downloadedBytes: downloadedBytes,
                totalBytes: metadata.contentLength,
                isResumable: downloadedBytes > 0
            )
        )

        if downloadedBytes >= metadata.contentLength {
            return partialArchiveURL
        }

        while downloadedBytes < metadata.contentLength {
            let rangeEnd = min(downloadedBytes + chunkSize - 1, metadata.contentLength - 1)
            let chunkData = try await fetchChunk(
                descriptor: descriptor,
                metadata: metadata,
                start: downloadedBytes,
                end: rangeEnd,
                allowAutomaticRestart: allowAutomaticRestart
            )

            try append(chunkData, to: partialArchiveURL)
            downloadedBytes += Int64(chunkData.count)

            try saveState(
                PersistedModelDownloadState(
                    packageId: descriptor.packageId,
                    archiveURL: descriptor.archiveURL,
                    archiveSize: metadata.contentLength,
                    etag: metadata.etag,
                    lastModified: metadata.lastModified,
                    downloadedBytes: downloadedBytes,
                    updatedAt: .now
                ),
                to: stateURL
            )

            await progressHandler(
                ModelDownloadProgress(
                    phase: .downloading,
                    downloadedBytes: downloadedBytes,
                    totalBytes: metadata.contentLength,
                    isResumable: downloadedBytes > 0 && downloadedBytes < metadata.contentLength
                )
            )
        }

        return partialArchiveURL
    }

    private func fetchRemoteMetadata(for descriptor: ModelDownloadDescriptor) async throws -> RemoteArchiveMetadata {
        var request = URLRequest(url: descriptor.archiveURL)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await session.data(for: request)
            if let metadata = try metadata(from: response, descriptor: descriptor) {
                return metadata
            }
        } catch {
            // Fall back to a byte-range GET for origins that reject HEAD.
        }

        var fallbackRequest = URLRequest(url: descriptor.archiveURL)
        fallbackRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: fallbackRequest)

        guard let metadata = try metadata(from: response, descriptor: descriptor) else {
            throw ResumableArchiveDownloaderError.missingContentLength
        }

        return metadata
    }

    private func metadata(
        from response: URLResponse,
        descriptor: ModelDownloadDescriptor
    ) throws -> RemoteArchiveMetadata? {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResumableArchiveDownloaderError.invalidResponse("The server returned an invalid response.")
        }

        guard [200, 206].contains(httpResponse.statusCode) else {
            throw ResumableArchiveDownloaderError.invalidResponse("The server returned HTTP \(httpResponse.statusCode).")
        }

        let contentLength = resolvedContentLength(from: httpResponse)
        guard contentLength > 0 else {
            return nil
        }

        if descriptor.archiveSize > 0, descriptor.archiveSize != contentLength {
            throw ResumableArchiveDownloaderError.metadataMismatch(
                "The archive size changed unexpectedly. Please retry the download."
            )
        }

        let acceptRangesHeader = headerValue("Accept-Ranges", in: httpResponse)?.lowercased()

        return RemoteArchiveMetadata(
            contentLength: contentLength,
            etag: normalizedHeaderValue("ETag", in: httpResponse),
            lastModified: normalizedHeaderValue("Last-Modified", in: httpResponse),
            acceptsByteRanges: acceptRangesHeader == "bytes"
        )
    }

    private func fetchChunk(
        descriptor: ModelDownloadDescriptor,
        metadata: RemoteArchiveMetadata,
        start: Int64,
        end: Int64,
        allowAutomaticRestart: Bool
    ) async throws -> Data {
        for (index, delaySeconds) in retryDelays.enumerated() {
            do {
                return try await fetchChunkOnce(
                    descriptor: descriptor,
                    metadata: metadata,
                    start: start,
                    end: end,
                    allowAutomaticRestart: allowAutomaticRestart
                )
            } catch {
                guard index < retryDelays.count - 1 else {
                    throw error
                }

                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }

        throw ResumableArchiveDownloaderError.downloadFailed("The download failed unexpectedly.")
    }

    private func fetchChunkOnce(
        descriptor: ModelDownloadDescriptor,
        metadata: RemoteArchiveMetadata,
        start: Int64,
        end: Int64,
        allowAutomaticRestart: Bool
    ) async throws -> Data {
        var request = URLRequest(url: descriptor.archiveURL)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        if let etag = metadata.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResumableArchiveDownloaderError.invalidResponse("The server returned an invalid chunk response.")
        }

        switch httpResponse.statusCode {
        case 206:
            guard let contentRange = headerValue("Content-Range", in: httpResponse),
                  contentRange.contains("bytes \(start)-\(end)/") else {
                throw ResumableArchiveDownloaderError.invalidResponse(
                    "The server returned an unexpected byte range."
                )
            }

            return data
        case 200 where start == 0 && Int64(data.count) == metadata.contentLength:
            return data
        case 416 where allowAutomaticRestart:
            try resetPersistedDownload(for: descriptor)
            throw ResumableArchiveDownloaderError.metadataMismatch(
                "The remote archive changed while downloading. Please retry."
            )
        case 200 where allowAutomaticRestart:
            try resetPersistedDownload(for: descriptor)
            throw ResumableArchiveDownloaderError.metadataMismatch(
                "The remote archive changed while downloading. Please retry."
            )
        case 429, 500 ..< 600:
            throw ResumableArchiveDownloaderError.downloadFailed("The server is temporarily unavailable.")
        default:
            throw ResumableArchiveDownloaderError.invalidResponse(
                "The server returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    private func isPersistedStateValid(
        _ state: PersistedModelDownloadState,
        descriptor: ModelDownloadDescriptor,
        metadata: RemoteArchiveMetadata,
        partialArchiveURL: URL
    ) -> Bool {
        guard state.packageId == descriptor.packageId,
              state.archiveURL == descriptor.archiveURL else {
            return false
        }

        guard state.archiveSize == metadata.contentLength else {
            return false
        }

        if let currentETag = metadata.etag, currentETag != state.etag {
            return false
        }

        if let currentLastModified = metadata.lastModified, currentLastModified != state.lastModified {
            return false
        }

        let actualBytes = (try? fileSize(at: partialArchiveURL)) ?? nil
        if let actualBytes, actualBytes < state.downloadedBytes {
            return false
        }

        return true
    }

    private func resolvedContentLength(from response: HTTPURLResponse) -> Int64 {
        if let contentRange = headerValue("Content-Range", in: response),
           let totalBytes = contentRange.split(separator: "/").last,
           let value = Int64(totalBytes) {
            return value
        }

        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }

        if let contentLengthHeader = headerValue("Content-Length", in: response),
           let value = Int64(contentLengthHeader) {
            return value
        }

        return 0
    }

    private func loadPersistedState(for descriptor: ModelDownloadDescriptor) throws -> PersistedModelDownloadState? {
        let stateURL = try ModelStoragePaths.persistedStateURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedModelDownloadState.self, from: Data(contentsOf: stateURL))
    }

    private func saveState(_ state: PersistedModelDownloadState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func resetPersistedDownload(for descriptor: ModelDownloadDescriptor) throws {
        let downloadDirectoryURL = try ModelStoragePaths.downloadDirectoryURL(for: descriptor)
        if FileManager.default.fileExists(atPath: downloadDirectoryURL.path) {
            try FileManager.default.removeItem(at: downloadDirectoryURL)
        }
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func ensureFileExists(at fileURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw ResumableArchiveDownloaderError.filesystemFailure(error.localizedDescription)
        }
    }

    private func fileSize(at url: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedHeaderValue(_ name: String, in response: HTTPURLResponse) -> String? {
        guard let value = headerValue(name, in: response), !value.isEmpty else {
            return nil
        }

        return value
    }
}
