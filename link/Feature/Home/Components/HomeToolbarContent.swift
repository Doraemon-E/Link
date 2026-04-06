//
//  HomeToolbarContent.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

enum HomeToolbarMetrics {
    static let plainSymbolFont: Font = .body.weight(.semibold)
    static let plainSymbolFrame: CGFloat = 28
    static let newSessionSymbolFont: Font = .system(size: 16, weight: .semibold)
    static let downloadHitFrame: CGFloat = 32
    static let downloadVisualFrame: CGFloat = 28
    static let downloadSymbolFont: Font = .system(size: 15, weight: .semibold)
    static let downloadRingLineWidth: CGFloat = 1.75
}

struct HomeToolbarContent: ToolbarContent {
    let state: HomeStore.ToolbarState
    let onOpenSessionHistory: () -> Void
    let onOpenDownloadManager: () -> Void
    let onStartNewSession: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if state.showsSessionHistoryButton {
                toolbarIconButton(
                    accessibilityLabel: "历史会话",
                    action: onOpenSessionHistory
                ) {
                    Image(systemName: "line.3.horizontal")
                        .font(HomeToolbarMetrics.plainSymbolFont)
                        .frame(
                            width: HomeToolbarMetrics.plainSymbolFrame,
                            height: HomeToolbarMetrics.plainSymbolFrame
                        )
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if state.showsDownloadButton {
                toolbarIconButton(
                    accessibilityLabel: "下载管理",
                    isEnabled: state.isDownloadButtonEnabled,
                    action: onOpenDownloadManager
                ) {
                    HomeDownloadToolbarIcon(
                        isDownloading: state.isDownloading,
                        hasAttention: state.hasDownloadAttention,
                        progress: state.downloadProgress,
                        resumableProgress: state.resumableProgress
                    )
                }
            }

            if state.showsNewSessionButton {
                toolbarIconButton(
                    accessibilityLabel: "新增会话",
                    action: onStartNewSession
                ) {
                    Image(systemName: "plus.circle")
                        .font(HomeToolbarMetrics.newSessionSymbolFont)
                        .frame(
                            width: HomeToolbarMetrics.plainSymbolFrame,
                            height: HomeToolbarMetrics.plainSymbolFrame
                        )
                }
            }
        }
    }

    private func toolbarIconButton<Label: View>(
        accessibilityLabel: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
