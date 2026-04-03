//
//  HomeChatMessageBubble.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if isUserMessage {
                Spacer(minLength: 52)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(isUserMessage ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(bubbleColor)
                .clipShape(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: 280, alignment: isUserMessage ? .trailing : .leading)

            if !isUserMessage {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isUserMessage: Bool {
        message.sender == .user
    }

    private var bubbleColor: Color {
        if isUserMessage {
            return .accentColor
        }

        return Color(uiColor: .secondarySystemBackground)
    }
}
