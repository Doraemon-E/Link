//
//  HomeConversationContentView.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomeConversationContentView: View {
    let viewState: HomeStore.ViewState
    let selectedLanguage: SupportedLanguage
    let messageListBottomAnchorID: String
    let messageListBottomSpacerHeight: CGFloat
    let immersiveVoiceTranslationState: HomeImmersiveVoiceTranslationState?
    let onOpenLanguagePicker: () -> Void
    let onDismissInputFocus: () -> Void
    let onTranslatedPlayback: (ChatMessage) -> Void
    let onRetrySpeechTranslation: (ChatMessage) -> Void
    let onSourcePlayback: (ChatMessage) -> Void
    let onSpeechTranscriptToggle: (ChatMessage) -> Void
    let onSourceLanguageSelection: (ChatMessage) -> Void
    let onTargetLanguageSelection: (ChatMessage) -> Void
    let onMessageListBottomProximityChanged: (Bool) -> Void

    var body: some View {
        Group {
            if let immersiveVoiceTranslationState {
                HomeImmersiveVoiceTranslationView(state: immersiveVoiceTranslationState)
            } else if viewState.shouldShowEmptyState {
                HomeEmptyStateView(
                    selectedLanguage: selectedLanguage,
                    onOpenLanguagePicker: onOpenLanguagePicker
                )
            } else {
                HomeMessageListView(
                    messageItems: viewState.messageItems,
                    bottomAnchorID: messageListBottomAnchorID,
                    bottomSpacerHeight: messageListBottomSpacerHeight,
                    onTranslatedPlayback: onTranslatedPlayback,
                    onRetrySpeechTranslation: onRetrySpeechTranslation,
                    onSourcePlayback: onSourcePlayback,
                    onSpeechTranscriptToggle: onSpeechTranscriptToggle,
                    onSourceLanguageSelection: onSourceLanguageSelection,
                    onTargetLanguageSelection: onTargetLanguageSelection,
                    onMessageListBottomProximityChanged: onMessageListBottomProximityChanged
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismissInputFocus)
        .animation(.easeInOut(duration: 0.22), value: immersiveVoiceTranslationState != nil)
    }
}

private struct HomeImmersiveVoiceTranslationView: View {
    private static let bottomAnchorID = "home-immersive-translation-bottom-anchor"

    let state: HomeImmersiveVoiceTranslationState

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 18) {
                            ForEach(state.committedSegments) { segment in
                                subtitleText(
                                    segment.text,
                                    foregroundOpacity: 0.74
                                )
                            }

                            if hasActiveText {
                                subtitleText(
                                    state.activeText,
                                    foregroundOpacity: 0.96
                                )
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, max(28, proxy.safeAreaInsets.bottom + 20))
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: proxy.size.height * 0.7)
                    .clipped()
                    .onAppear {
                        scrollToBottom(with: scrollProxy, animated: false)
                    }
                    .onChange(of: scrollKey) { _, _ in
                        scrollToBottom(with: scrollProxy, animated: true)
                    }
                }

                Spacer(minLength: proxy.size.height * 0.3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hasActiveText: Bool {
        !state.activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scrollKey: String {
        let committedIDs = state.committedSegments.map(\.id.uuidString).joined(separator: ",")
        return "\(committedIDs)|\(state.activeText)"
    }

    private func subtitleText(
        _ text: String,
        foregroundOpacity: Double
    ) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(foregroundOpacity))
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
    }

    private func scrollToBottom(
        with proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let action = {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                action()
            }
        } else {
            action()
        }
    }
}
