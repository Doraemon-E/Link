//
//  ModelAssetsView.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct ModelAssetsView: View {
    @State private var pendingDeleteItem: ModelAssetRecord?

    let isLoading: Bool
    let processingRecords: [ModelAssetRecord]
    let resumableRecords: [ModelAssetRecord]
    let failedRecords: [ModelAssetRecord]
    let installedRecords: [ModelAssetRecord]
    let availableRecords: [ModelAssetRecord]
    let onDownload: (ModelAssetRecord) -> Void
    let onResume: (String) -> Void
    let onRetry: (String) -> Void
    let onDelete: (String) -> Void

    private var allItemsAreEmpty: Bool {
        processingRecords.isEmpty &&
        resumableRecords.isEmpty &&
        failedRecords.isEmpty &&
        installedRecords.isEmpty &&
        availableRecords.isEmpty
    }

    var body: some View {
        Group {
            if isLoading && allItemsAreEmpty {
                loadingState
            } else if allItemsAreEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if !processingRecords.isEmpty {
                            section(title: "正在处理", items: processingRecords)
                        }

                        if !resumableRecords.isEmpty {
                            section(title: "可继续下载", items: resumableRecords)
                        }

                        if !failedRecords.isEmpty {
                            section(title: "下载失败", items: failedRecords)
                        }

                        if !availableRecords.isEmpty {
                            section(title: "可下载", items: availableRecords)
                        }

                        if !installedRecords.isEmpty {
                            section(title: "已安装", items: installedRecords)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "删除已安装模型？",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteItem = nil
                    }
                }
            ),
            presenting: pendingDeleteItem
        ) { item in
            Button("删除", role: .destructive) {
                onDelete(item.id)
                pendingDeleteItem = nil
            }

            Button("取消", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: { item in
            Text("删除“\(item.asset.title)”后，如需再次使用，需要重新下载并安装。")
        }
    }

    @ViewBuilder
    private func section(title: String, items: [ModelAssetRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            ForEach(items) { item in
                ModelAssetRow(
                    item: item,
                    onDownload: { onDownload(item) },
                    onResume: { onResume(item.id) },
                    onRetry: { onRetry(item.id) },
                    onDelete: { pendingDeleteItem = item }
                )
            }
        }
    }

    private var loadingState: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("还没有下载任务")
                .font(.headline)

            Text("新的翻译模型或语音识别模型开始下载后，会在这里显示进度和已安装状态。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelAssetRow: View {
    let item: ModelAssetRecord
    let onDownload: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var showsProgressBar: Bool {
        !item.isInstalled && item.status.state != .failed && item.status.state != .idle
    }

    private var trimmedTitle: String {
        item.asset.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSubtitle: String {
        item.asset.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKindDisplayName: String {
        item.kind.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displaySubtitle: String? {
        guard !trimmedSubtitle.isEmpty,
              trimmedSubtitle != trimmedKindDisplayName,
              trimmedSubtitle != trimmedTitle else {
            return nil
        }

        return trimmedSubtitle
    }

    private var showsKindBadge: Bool {
        !trimmedKindDisplayName.isEmpty && trimmedKindDisplayName != trimmedTitle
    }

    private var shouldShowTransferDetails: Bool {
        item.status.totalBytes > 0 && item.status.state != .idle
    }

    private var shouldShowTransferMetrics: Bool {
        shouldShowTransferDetails && item.status.state == .downloading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trimmedTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)

                    if let displaySubtitle {
                        Text(displaySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if showsKindBadge {
                    kindBadge
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.status.state.displayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(statusColor)

                    if shouldShowTransferDetails {
                        Text("\(item.status.downloadedBytes.formattedModelSize) / \(item.status.totalBytes.formattedModelSize)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if shouldShowTransferMetrics {
                    HStack(spacing: 12) {
                        metricLabel(item.status.fractionCompleted.formattedPercent)

                        if let bytesPerSecond = item.status.bytesPerSecond {
                            metricLabel(bytesPerSecond.formattedTransferSpeed)
                        }

                        if let remaining = item.status.estimatedRemainingTime?.formattedRemainingTime {
                            metricLabel("约剩\(remaining)")
                        }
                    }
                }
            }

            if showsProgressBar {
                ProgressView(value: item.status.fractionCompleted)
                    .tint(statusColor)
            }

            if let errorMessage = item.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                switch item.status.state {
                case .idle:
                    Button("下载", action: onDownload)
                        .buttonStyle(.borderedProminent)
                case .pausedResumable:
                    Button("继续下载", action: onResume)
                        .buttonStyle(.borderedProminent)
                case .failed:
                    Button("重试", action: onRetry)
                        .buttonStyle(.borderedProminent)
                default:
                    EmptyView()
                }

                if item.isInstalled {
                    Button("删除", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var kindBadge: some View {
        Text(trimmedKindDisplayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
            )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private func metricLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch item.status.state {
        case .failed:
            return .red
        case .pausedResumable:
            return .orange
        case .completed:
            return .green
        default:
            return .accentColor
        }
    }
}

private extension Double {
    var formattedPercent: String {
        "\(Int((self * 100).rounded()))%"
    }

    var formattedTransferSpeed: String {
        "\(Int64(self.rounded()).formattedModelSize)/s"
    }
}

private extension TimeInterval {
    var formattedRemainingTime: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: self) ?? "稍后"
    }
}
