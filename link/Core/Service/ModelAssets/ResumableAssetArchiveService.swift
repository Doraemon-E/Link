//
//  ResumableAssetArchiveService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated struct PersistedAssetTransferState: Codable, Equatable, Sendable {
    let packageId: String
    let archiveURL: URL
    let archiveSize: Int64
    let etag: String?
    let lastModified: String?
    let downloadedBytes: Int64
    let updatedAt: Date
}

nonisolated struct RemoteAssetArchiveMetadata: Equatable, Sendable {
    let contentLength: Int64
    let etag: String?
    let lastModified: String?
    let acceptsByteRanges: Bool
}

nonisolated enum ResumableAssetArchiveServiceError: LocalizedError {
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

actor ResumableAssetArchiveService {
    private let chunkSize: Int64
    private let retryDelays: [UInt64]
    private let progressPollIntervalNanoseconds: UInt64
    private let session: URLSession

    init(
        chunkSize: Int64 = 8 * 1_024 * 1_024,
        retryDelays: [UInt64] = [1, 2, 4, 8, 16],
        progressPollIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.chunkSize = chunkSize
        self.retryDelays = retryDelays
        self.progressPollIntervalNanoseconds = progressPollIntervalNanoseconds

        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true           // 允许使用蜂窝网络（4G/5G）
        configuration.allowsExpensiveNetworkAccess = true   // 允许"昂贵"网络（如个人热点）
        configuration.allowsConstrainedNetworkAccess = false // 禁止低数据模式下下载（省流/省电）
        configuration.waitsForConnectivity = true           // 无网络时等待，而非立即报错
        configuration.timeoutIntervalForRequest = 60        // 单次请求（含握手）超时 60 秒
        configuration.timeoutIntervalForResource = 60 * 60  // 整个资源下载最长允许 1 小时
        self.session = URLSession(configuration: configuration)
    }

    func download(
        asset: ModelAsset,
        progressHandler: @escaping @Sendable (ModelAssetTransferStatus) async -> Void
    ) async throws -> URL {
        try await download(
            asset: asset,
            allowAutomaticRestart: true,
            progressHandler: progressHandler
        )
    }

    func persistedStates(for kind: ModelAssetKind) throws -> [PersistedAssetTransferState] {
        let downloadsDirectoryURL = try ModelAssetStoragePaths.downloadsDirectoryURL(for: kind)
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
                return try decoder.decode(PersistedAssetTransferState.self, from: data)
            } catch {
                return nil
            }
        }
    }

    func persistedStatus(for asset: ModelAsset) throws -> ModelAssetTransferStatus? {
        guard let state = try loadPersistedState(for: asset) else {
            return nil
        }

        let partialArchiveURL = try ModelAssetStoragePaths.partialArchiveURL(for: asset)
        let actualBytes = try fileSize(at: partialArchiveURL) ?? state.downloadedBytes

        return ModelAssetTransferStatus(
            state: .pausedResumable,
            downloadedBytes: actualBytes,
            totalBytes: max(state.archiveSize, asset.archiveSize),
            isResumable: actualBytes > 0
        )
    }

    func removePersistedTransfer(for asset: ModelAsset) throws {
        let downloadDirectoryURL = try ModelAssetStoragePaths.transferDirectoryURL(for: asset)
        if FileManager.default.fileExists(atPath: downloadDirectoryURL.path) {
            try FileManager.default.removeItem(at: downloadDirectoryURL)
        }
    }

    private func download(
        asset: ModelAsset,
        allowAutomaticRestart: Bool,
        progressHandler: @escaping @Sendable (ModelAssetTransferStatus) async -> Void
    ) async throws -> URL {
        let metadata = try await fetchRemoteMetadata(for: asset)
        let downloadDirectoryURL = try ModelAssetStoragePaths.transferDirectoryURL(for: asset)
        let partialArchiveURL = try ModelAssetStoragePaths.partialArchiveURL(for: asset)
        let stateURL = try ModelAssetStoragePaths.persistedTransferStateURL(for: asset)

        try ensureDirectoryExists(at: downloadDirectoryURL)
        try ensureFileExists(at: partialArchiveURL)

        if let persistedState = try loadPersistedState(for: asset),
           !isPersistedStateValid(
                persistedState,
                asset: asset,
                metadata: metadata,
                partialArchiveURL: partialArchiveURL
           ) {
            try resetPersistedDownload(for: asset)
            try ensureDirectoryExists(at: downloadDirectoryURL)
            try ensureFileExists(at: partialArchiveURL)
        }

        let existingBytes = min(
            try fileSize(at: partialArchiveURL) ?? 0,
            max(metadata.contentLength, asset.archiveSize)
        )
        var downloadedBytes = existingBytes
        let progressReporter = DownloadProgressReporter(
            initialDownloadedBytes: downloadedBytes,
            totalBytes: metadata.contentLength,
            minimumEmissionInterval: Double(progressPollIntervalNanoseconds) / 1_000_000_000,
            progressHandler: progressHandler
        )

        if let state = try loadPersistedState(for: asset),
           state.downloadedBytes != downloadedBytes {
            /// 如果磁盘上的部分文件大小与记录的状态不符, 则以实际文件大小为准并更新状态记录
            try saveState(
                PersistedAssetTransferState(
                    packageId: asset.packageId,
                    archiveURL: asset.archiveURL,
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
            ModelAssetTransferStatus(
                state: .preparing,
                downloadedBytes: downloadedBytes,
                totalBytes: metadata.contentLength,
                isResumable: downloadedBytes > 0
            )
        )

        if downloadedBytes >= metadata.contentLength {
            return partialArchiveURL
        }

        while downloadedBytes < metadata.contentLength {
            /// 计算请求的块的结束位置
            let rangeEnd = min(downloadedBytes + chunkSize - 1, metadata.contentLength - 1)
            let chunkData = try await fetchChunk(
                asset: asset,
                metadata: metadata,
                start: downloadedBytes,
                end: rangeEnd,
                allowAutomaticRestart: allowAutomaticRestart,
                progressReporter: progressReporter
            )

            try append(chunkData, to: partialArchiveURL)
            downloadedBytes += Int64(chunkData.count)

            try saveState(
                PersistedAssetTransferState(
                    packageId: asset.packageId,
                    archiveURL: asset.archiveURL,
                    archiveSize: metadata.contentLength,
                    etag: metadata.etag,
                    lastModified: metadata.lastModified,
                    downloadedBytes: downloadedBytes,
                    updatedAt: .now
                ),
                to: stateURL
            )
        }

        return partialArchiveURL
    }

    private func fetchRemoteMetadata(for asset: ModelAsset) async throws -> RemoteAssetArchiveMetadata {
        var request = URLRequest(url: asset.archiveURL)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await session.data(for: request)
            if let metadata = try metadata(from: response, asset: asset) {
                return metadata
            }
        } catch {
            // Fall back to a byte-range GET for origins that reject HEAD.
        }

        var fallbackRequest = URLRequest(url: asset.archiveURL)
        fallbackRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: fallbackRequest)

        guard let metadata = try metadata(from: response, asset: asset) else {
            throw ResumableAssetArchiveServiceError.missingContentLength
        }

        return metadata
    }

    private func metadata(
        from response: URLResponse,
        asset: ModelAsset
    ) throws -> RemoteAssetArchiveMetadata? {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResumableAssetArchiveServiceError.invalidResponse("The server returned an invalid response.")
        }

        guard [200, 206].contains(httpResponse.statusCode) else {
            throw ResumableAssetArchiveServiceError.invalidResponse("The server returned HTTP \(httpResponse.statusCode).")
        }

        let contentLength = resolvedContentLength(from: httpResponse)
        guard contentLength > 0 else {
            return nil
        }

        if asset.archiveSize > 0, asset.archiveSize != contentLength {
            throw ResumableAssetArchiveServiceError.metadataMismatch(
                "The archive size changed unexpectedly. Please retry the download."
            )
        }

        let acceptRangesHeader = headerValue("Accept-Ranges", in: httpResponse)?.lowercased()

        return RemoteAssetArchiveMetadata(
            contentLength: contentLength,
            etag: normalizedHeaderValue("ETag", in: httpResponse),
            lastModified: normalizedHeaderValue("Last-Modified", in: httpResponse),
            acceptsByteRanges: acceptRangesHeader == "bytes"
        )
    }

    private func fetchChunk(
        asset: ModelAsset,
        metadata: RemoteAssetArchiveMetadata,
        start: Int64,
        end: Int64,
        allowAutomaticRestart: Bool,
        progressReporter: DownloadProgressReporter
    ) async throws -> Data {
        for (index, delaySeconds) in retryDelays.enumerated() {
            do {
                return try await fetchChunkOnce(
                    asset: asset,
                    metadata: metadata,
                    start: start,
                    end: end,
                    allowAutomaticRestart: allowAutomaticRestart,
                    progressHandler: { receivedBytes in
                        await progressReporter.report(totalDownloadedBytes: start + receivedBytes)
                    }
                )
            } catch {
                guard index < retryDelays.count - 1 else {
                    throw error
                }

                await progressReporter.resetToCommittedBaseline(totalDownloadedBytes: start)
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }

        throw ResumableAssetArchiveServiceError.downloadFailed("The download failed unexpectedly.")
    }

    private func fetchChunkOnce(
        asset: ModelAsset,
        metadata: RemoteAssetArchiveMetadata,
        start: Int64,
        end: Int64,
        allowAutomaticRestart: Bool,
        progressHandler: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        var request = URLRequest(url: asset.archiveURL)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        if let etag = metadata.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResumableAssetArchiveServiceError.invalidResponse("The server returned an invalid chunk response.")
        }

        switch httpResponse.statusCode {
        case 206:
            guard let contentRange = headerValue("Content-Range", in: httpResponse),
                  contentRange.contains("bytes \(start)-\(end)/") else {
                throw ResumableAssetArchiveServiceError.invalidResponse(
                    "The server returned an unexpected byte range."
                )
            }

            let expectedLength = end - start + 1
            let data = try await collectChunkData(
                from: bytes,
                expectedByteCount: expectedLength,
                progressHandler: progressHandler
            )
            guard Int64(data.count) == expectedLength else {
                throw ResumableAssetArchiveServiceError.invalidResponse(
                    "The server returned an incomplete byte range."
                )
            }
            return data
        case 200:
            let data = try await collectChunkData(
                from: bytes,
                expectedByteCount: metadata.contentLength,
                progressHandler: progressHandler
            )
            if start == 0 && Int64(data.count) == metadata.contentLength {
                return data
            }

            if allowAutomaticRestart {
                try resetPersistedDownload(for: asset)
                throw ResumableAssetArchiveServiceError.metadataMismatch(
                    "The remote archive changed while downloading. Please retry."
                )
            }

            throw ResumableAssetArchiveServiceError.invalidResponse(
                "The server returned an unexpected full archive response."
            )
        case 416 where allowAutomaticRestart:
            try resetPersistedDownload(for: asset)
            throw ResumableAssetArchiveServiceError.metadataMismatch(
                "The remote archive changed while downloading. Please retry."
            )
        case 200 where allowAutomaticRestart:
            try resetPersistedDownload(for: asset)
            throw ResumableAssetArchiveServiceError.metadataMismatch(
                "The remote archive changed while downloading. Please retry."
            )
        case 429, 500 ..< 600:
            throw ResumableAssetArchiveServiceError.downloadFailed("The server is temporarily unavailable.")
        default:
            throw ResumableAssetArchiveServiceError.invalidResponse(
                "The server returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    private func collectChunkData(
        from bytes: URLSession.AsyncBytes,
        expectedByteCount: Int64,
        progressHandler: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        var data = Data()
        if expectedByteCount > 0, expectedByteCount <= Int64(Int.max) {
            data.reserveCapacity(Int(expectedByteCount))
        }

        let reportThreshold: Int64 = 64 * 1_024 // 64 KB
        var receivedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0

        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            receivedBytes += 1

            if receivedBytes - lastReportedBytes >= reportThreshold {
                lastReportedBytes = receivedBytes
                await progressHandler(receivedBytes)
            }
        }

        if receivedBytes != lastReportedBytes {
            await progressHandler(receivedBytes)
        }

        return data
    }

    private func isPersistedStateValid(
        _ state: PersistedAssetTransferState,
        asset: ModelAsset,
        metadata: RemoteAssetArchiveMetadata,
        partialArchiveURL: URL
    ) -> Bool {
        guard state.packageId == asset.packageId,
              state.archiveURL == asset.archiveURL else {
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

    private func loadPersistedState(for asset: ModelAsset) throws -> PersistedAssetTransferState? {
        let stateURL = try ModelAssetStoragePaths.persistedTransferStateURL(for: asset)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedAssetTransferState.self, from: Data(contentsOf: stateURL))
    }

    private func saveState(_ state: PersistedAssetTransferState, to url: URL) throws {
        let encoder = JSONEncoder()
        /// 输出带缩进的可读 JSON, 键名按字母排序
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func resetPersistedDownload(for asset: ModelAsset) throws {
        let downloadDirectoryURL = try ModelAssetStoragePaths.transferDirectoryURL(for: asset)
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
            /// 将指针移动到文件末尾以追加数据
            try handle.seekToEnd()
            /// 将Data写入文件
            try handle.write(contentsOf: data)
        } catch {
            throw ResumableAssetArchiveServiceError.filesystemFailure(error.localizedDescription)
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


/// EMA 平滑算法实现, 用于根据下载数据的波动计算更稳定的下载速度估计
private nonisolated struct TransferSpeedTracker {
    private let smoothingFactor: Double
    private var lastSampleBytes: Int64
    private var lastSampleDate: Date
    private(set) var smoothedBytesPerSecond: Double?

    init(
        initialBytes: Int64,
        initialDate: Date = .now,
        previousSmoothedBytesPerSecond: Double? = nil,
        smoothingFactor: Double = 0.35
    ) {
        self.smoothingFactor = smoothingFactor
        self.lastSampleBytes = initialBytes
        self.lastSampleDate = initialDate
        self.smoothedBytesPerSecond = previousSmoothedBytesPerSecond
    }

    mutating func record(totalDownloadedBytes: Int64, at date: Date = .now) -> Double? {
        let byteDelta = totalDownloadedBytes - lastSampleBytes
        let timeDelta = max(date.timeIntervalSince(lastSampleDate), 0.001)

        guard byteDelta > 0 else {
            return smoothedBytesPerSecond
        }

        let instantaneousBytesPerSecond = Double(byteDelta) / timeDelta

        /// EMA 公式平滑速度
        if let smoothedBytesPerSecond {
            self.smoothedBytesPerSecond =
                (smoothedBytesPerSecond * (1 - smoothingFactor)) +
                (instantaneousBytesPerSecond * smoothingFactor)
        } else {
            self.smoothedBytesPerSecond = instantaneousBytesPerSecond
        }

        lastSampleBytes = totalDownloadedBytes
        lastSampleDate = date
        return self.smoothedBytesPerSecond
    }
}

private actor DownloadProgressReporter {
    private let totalBytes: Int64
    private let minimumEmissionInterval: TimeInterval
    private let progressHandler: @Sendable (ModelAssetTransferStatus) async -> Void
    private var speedTracker: TransferSpeedTracker
    private var lastEmittedAt: Date?

    init(
        initialDownloadedBytes: Int64,
        totalBytes: Int64,
        minimumEmissionInterval: TimeInterval,
        progressHandler: @escaping @Sendable (ModelAssetTransferStatus) async -> Void
    ) {
        self.totalBytes = totalBytes
        self.minimumEmissionInterval = minimumEmissionInterval
        self.progressHandler = progressHandler
        self.speedTracker = TransferSpeedTracker(
            initialBytes: initialDownloadedBytes
        )
    }

    func report(totalDownloadedBytes: Int64, force: Bool = false) async {
        let bytesPerSecond = speedTracker.record(totalDownloadedBytes: totalDownloadedBytes)
        let now = Date()

        if !force,
           let lastEmittedAt,
           now.timeIntervalSince(lastEmittedAt) < minimumEmissionInterval {
            return
        }

        await progressHandler(
            ModelAssetTransferStatus(
                state: .downloading,
                downloadedBytes: totalDownloadedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: bytesPerSecond ?? speedTracker.smoothedBytesPerSecond,
                isResumable: totalDownloadedBytes > 0 && totalDownloadedBytes < totalBytes
            )
        )
        lastEmittedAt = now
    }

    func resetToCommittedBaseline(totalDownloadedBytes: Int64) async {
        await report(totalDownloadedBytes: totalDownloadedBytes, force: true)
    }
}
