//
//  HomeChatMessageBubble.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatMessageBubble: View {
    private struct MessageBlockContent {
        let text: String
        let isPlaceholder: Bool
    }

    let message: ChatMessage
    let streamingState: ExchangeStreamingState?
    let showsSpeechPlaybackButton: Bool
    let isSpeakingMessage: Bool
    let isSpeechPlaybackDisabled: Bool
    let onSpeechPlayback: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 52)

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 14) {
                    messageSection(
                        title: "原文",
                        content: sourceContent,
                        textColor: .secondary,
                        font: .subheadline
                    )

                    Divider()

                    messageSection(
                        title: "译文",
                        content: translatedContent,
                        textColor: .primary,
                        font: .body
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: 320, alignment: .trailing)

                footer
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceContent: MessageBlockContent {
        content(
            persistedText: message.sourceText,
            liveText: streamingState?.sourceDisplayText,
            placeholderText: streamingState?.sourcePlaceholderText
        )
    }

    private var translatedContent: MessageBlockContent {
        content(
            persistedText: message.translatedText,
            liveText: streamingState?.translatedDisplayText,
            placeholderText: streamingState?.translatedPlaceholderText
        )
    }

    private func content(
        persistedText: String,
        liveText: String?,
        placeholderText: String?
    ) -> MessageBlockContent {
        if let liveText {
            let normalizedLiveText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLiveText.isEmpty {
                return MessageBlockContent(text: liveText, isPlaceholder: false)
            }
        }

        if let placeholderText {
            let normalizedPlaceholder = placeholderText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedPlaceholder.isEmpty {
                return MessageBlockContent(text: placeholderText, isPlaceholder: true)
            }
        }

        let normalizedPersistedText = persistedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPersistedText.isEmpty {
            return MessageBlockContent(text: persistedText, isPlaceholder: false)
        }

        return MessageBlockContent(text: "…", isPlaceholder: true)
    }

    @ViewBuilder
    private func messageSection(
        title: String,
        content: MessageBlockContent,
        textColor: Color,
        font: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            Text(content.text)
                .font(font)
                .foregroundStyle(content.isPlaceholder ? Color.secondary : textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if showsSpeechPlaybackButton {
            Button(action: onSpeechPlayback) {
                Image(systemName: isSpeakingMessage ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(isSpeakingMessage ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSpeechPlaybackDisabled)
            .accessibilityLabel(isSpeakingMessage ? "停止语音播放" : "播放译文语音")
            .padding(.horizontal, 4)
        }
    }
}
