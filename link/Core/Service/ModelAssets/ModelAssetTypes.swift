//
//  ModelAssetTypes.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum ModelAssetKind: String, Codable, Sendable {
    case translation
    case speech

    var displayName: String {
        switch self {
        case .translation:
            return "翻译模型"
        case .speech:
            return "语音识别模型"
        }
    }
}

nonisolated enum ModelAssetState: String, Codable, Sendable {
    case idle
    case preparing
    case downloading
    case verifying
    case installing
    case completed
    case failed
    case pausedResumable

    var displayName: String {
        switch self {
        case .idle:
            return "待下载"
        case .preparing:
            return "准备下载"
        case .downloading:
            return "下载中"
        case .verifying:
            return "校验中"
        case .installing:
            return "安装中"
        case .completed:
            return "已完成"
        case .failed:
            return "下载失败"
        case .pausedResumable:
            return "可继续下载"
        }
    }
}

nonisolated struct ModelAsset: Identifiable, Equatable, Sendable {
    let kind: ModelAssetKind
    let packageId: String
    let version: String
    let title: String
    let subtitle: String
    let archiveURL: URL
    let archiveSize: Int64
    let installedSize: Int64
    let sha256: String

    var id: String {
        Self.makeID(kind: kind, packageId: packageId)
    }

    static func makeID(kind: ModelAssetKind, packageId: String) -> String {
        "\(kind.rawValue):\(packageId)"
    }
}

nonisolated struct ModelAssetTransferStatus: Equatable, Sendable {
    let state: ModelAssetState
    let downloadedBytes: Int64
    let totalBytes: Int64
    let fractionCompleted: Double
    let bytesPerSecond: Double?
    let isResumable: Bool

    init(
        state: ModelAssetState,
        downloadedBytes: Int64,
        totalBytes: Int64,
        fractionCompleted: Double? = nil,
        bytesPerSecond: Double? = nil,
        isResumable: Bool = false
    ) {
        self.state = state
        self.downloadedBytes = max(0, downloadedBytes)
        self.totalBytes = max(0, totalBytes)

        if let fractionCompleted {
            self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        } else if totalBytes > 0 {
            self.fractionCompleted = min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        } else {
            self.fractionCompleted = 0
        }

        if let bytesPerSecond, bytesPerSecond > 0 {
            self.bytesPerSecond = bytesPerSecond
        } else {
            self.bytesPerSecond = nil
        }

        self.isResumable = isResumable
    }

    var estimatedRemainingTime: TimeInterval? {
        guard state == .downloading,
              let bytesPerSecond,
              bytesPerSecond > 0,
              totalBytes > downloadedBytes else {
            return nil
        }

        return Double(totalBytes - downloadedBytes) / bytesPerSecond
    }

    static let idle = ModelAssetTransferStatus(
        state: .idle,
        downloadedBytes: 0,
        totalBytes: 0,
        fractionCompleted: 0
    )
}

nonisolated struct ModelAssetRecord: Identifiable, Equatable, Sendable {
    let asset: ModelAsset
    let status: ModelAssetTransferStatus
    let errorMessage: String?
    let installedAt: Date?
    let isInstalled: Bool

    var id: String { asset.id }
    var kind: ModelAssetKind { asset.kind }
}

extension ModelAssetRecord {
    static func available(asset: ModelAsset) -> Self {
        .init(
            asset: asset,
            status: .idle,
            errorMessage: nil,
            installedAt: nil,
            isInstalled: false
        )
    }

    static func installed(asset: ModelAsset, installedAt: Date) -> Self {
        .init(
            asset: asset,
            status: ModelAssetTransferStatus(
                state: .completed,
                downloadedBytes: asset.archiveSize,
                totalBytes: asset.archiveSize
            ),
            errorMessage: nil,
            installedAt: installedAt,
            isInstalled: true
        )
    }

    static func transient(
        asset: ModelAsset,
        status: ModelAssetTransferStatus,
        errorMessage: String? = nil
    ) -> Self {
        .init(
            asset: asset,
            status: status,
            errorMessage: errorMessage,
            installedAt: nil,
            isInstalled: false
        )
    }
}

nonisolated struct ModelAssetSummary: Equatable, Sendable {
    let activeCount: Int
    let resumableCount: Int
    let failedCount: Int
    let installedCount: Int
    let availableCount: Int

    var hasActiveTasks: Bool {
        activeCount > 0
    }

    var hasAttention: Bool {
        failedCount > 0 || resumableCount > 0
    }

    static let empty = ModelAssetSummary(
        activeCount: 0,
        resumableCount: 0,
        failedCount: 0,
        installedCount: 0,
        availableCount: 0
    )
}

nonisolated struct ModelAssetSnapshot: Equatable, Sendable {
    let records: [ModelAssetRecord]
    let summary: ModelAssetSummary

    static let empty = ModelAssetSnapshot(records: [], summary: .empty)
}
