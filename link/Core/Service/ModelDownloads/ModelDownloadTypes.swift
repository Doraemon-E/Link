//
//  ModelDownloadTypes.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum ModelAssetKind: String, Codable, Sendable {
    case translation
    case speech

    var displayName: String {
        switch self {
        case .translation:
            return "翻译模型"
        case .speech:
            return "语音模型"
        }
    }
}

enum ModelDownloadPhase: String, Codable, Sendable {
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

struct ModelDownloadDescriptor: Identifiable, Equatable, Sendable {
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
        Self.itemID(kind: kind, packageId: packageId)
    }

    static func itemID(kind: ModelAssetKind, packageId: String) -> String {
        "\(kind.rawValue):\(packageId)"
    }
}

struct ModelDownloadProgress: Equatable, Sendable {
    let phase: ModelDownloadPhase
    let downloadedBytes: Int64
    let totalBytes: Int64
    let fractionCompleted: Double
    let isResumable: Bool

    init(
        phase: ModelDownloadPhase,
        downloadedBytes: Int64,
        totalBytes: Int64,
        fractionCompleted: Double? = nil,
        isResumable: Bool = false
    ) {
        self.phase = phase
        self.downloadedBytes = max(0, downloadedBytes)
        self.totalBytes = max(0, totalBytes)

        if let fractionCompleted {
            self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        } else if totalBytes > 0 {
            self.fractionCompleted = min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
        } else {
            self.fractionCompleted = 0
        }

        self.isResumable = isResumable
    }

    static let idle = ModelDownloadProgress(
        phase: .idle,
        downloadedBytes: 0,
        totalBytes: 0,
        fractionCompleted: 0
    )
}

struct ModelDownloadItem: Identifiable, Equatable, Sendable {
    let descriptor: ModelDownloadDescriptor
    let progress: ModelDownloadProgress
    let errorMessage: String?
    let installedAt: Date?
    let isInstalled: Bool

    var id: String { descriptor.id }
    var kind: ModelAssetKind { descriptor.kind }
}

struct ModelDownloadManagerSummary: Equatable, Sendable {
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

    static let empty = ModelDownloadManagerSummary(
        activeCount: 0,
        resumableCount: 0,
        failedCount: 0,
        installedCount: 0,
        availableCount: 0
    )
}

struct ModelDownloadsSnapshot: Equatable, Sendable {
    let items: [ModelDownloadItem]
    let summary: ModelDownloadManagerSummary

    static let empty = ModelDownloadsSnapshot(items: [], summary: .empty)
}

struct TranslationInstalledPackageSummary: Equatable, Sendable {
    let packageId: String
    let version: String
    let sourceLanguage: HomeLanguage?
    let targetLanguage: HomeLanguage?
    let archiveSize: Int64
    let installedSize: Int64
    let installedAt: Date
}

struct SpeechInstalledPackageSummary: Equatable, Sendable {
    let packageId: String
    let version: String
    let archiveSize: Int64
    let installedSize: Int64
    let installedAt: Date
}
