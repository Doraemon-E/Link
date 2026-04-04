//
//  HomeChatMessageBubble.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatMessageBubble: View {
    let message: ChatMessage
    let streamingState: StreamingMessageState?

    var body: some View {
        HStack {
            if isUserMessage {
                Spacer(minLength: 52)
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
                Text(displayText)
                    .font(.body)
                    .foregroundStyle(isUserMessage ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(bubbleColor)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .frame(maxWidth: 280, alignment: isUserMessage ? .trailing : .leading)

                if let statusText, !isUserMessage {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if !isUserMessage {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isUserMessage: Bool {
        message.sender == .user
    }

    private var displayText: String {
        if let streamingState {
            let liveText = streamingState.displayText
            let normalizedLiveText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLiveText.isEmpty {
                return liveText
            }

            if let placeholderText = streamingState.placeholderText {
                return placeholderText
            }
        }

        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "…"
        }

        return message.text
    }

    private var statusText: String? {
        guard let streamingState, streamingState.isActive else {
            return nil
        }

        guard !streamingState.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return streamingState.statusText
    }

    private var bubbleColor: Color {
        if isUserMessage {
            return .accentColor
        }

        return Color(uiColor: .secondarySystemBackground)
    }
}
