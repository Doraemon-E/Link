//
//  HomeDownloadToolbarIcon.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomeDownloadToolbarIcon: View {
    let isDownloading: Bool
    let hasAttention: Bool
    let progress: Double?
    let resumableProgress: Double?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))

                Image(systemName: "arrow.down.circle.fill")
                    .font(HomeToolbarMetrics.downloadSymbolFont)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color.primary.opacity(isDownloading ? 0.86 : 0.8),
                        Color.primary.opacity(isDownloading ? 0.16 : 0.12)
                    )
            }
            .frame(
                width: HomeToolbarMetrics.downloadVisualFrame,
                height: HomeToolbarMetrics.downloadVisualFrame
            )
            .overlay {
                if isDownloading {
                    HomeDownloadProgressRing(progress: clampedProgress, isActive: true)
                } else if hasAttention {
                    HomeDownloadProgressRing(progress: clampedResumableProgress, isActive: false)
                }
            }
            .contentShape(Circle())
        }
        .frame(
            width: HomeToolbarMetrics.downloadHitFrame,
            height: HomeToolbarMetrics.downloadHitFrame
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isDownloading)
        .animation(.easeInOut(duration: 0.24), value: clampedProgress)
        .animation(.easeInOut(duration: 0.24), value: clampedResumableProgress)
    }

    private var clampedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var clampedResumableProgress: Double {
        min(max(resumableProgress ?? 0, 0), 1)
    }
}

private struct HomeDownloadProgressRing: View {
    let progress: Double
    var isActive: Bool = true

    private var arcColor: Color {
        isActive ? Color.accentColor : Color(red: 0.95, green: 0.46, blue: 0.34)
    }

    private var trackColor: Color {
        isActive
            ? Color.primary.opacity(0.08)
            : Color(red: 0.95, green: 0.46, blue: 0.34).opacity(0.25)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: HomeToolbarMetrics.downloadRingLineWidth)

            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        arcColor,
                        style: StrokeStyle(
                            lineWidth: HomeToolbarMetrics.downloadRingLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(0.5)
    }
}

#Preview("Download Toolbar Icon States") {
    HStack(spacing: 16) {
        HomeDownloadToolbarIcon(
            isDownloading: false,
            hasAttention: false,
            progress: nil,
            resumableProgress: nil
        )

        HomeDownloadToolbarIcon(
            isDownloading: false,
            hasAttention: true,
            progress: nil,
            resumableProgress: 0.6
        )

        HomeDownloadToolbarIcon(
            isDownloading: true,
            hasAttention: false,
            progress: 0.42,
            resumableProgress: nil
        )

        HomeDownloadToolbarIcon(
            isDownloading: true,
            hasAttention: false,
            progress: 1,
            resumableProgress: nil
        )
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
