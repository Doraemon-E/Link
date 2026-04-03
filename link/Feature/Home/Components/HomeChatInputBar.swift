//
//  HomeChatInputBar.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatInputBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "message")
                .foregroundStyle(.secondary)

            TextField("请输入对话内容", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview {
    HomeChatInputBar(text: .constant(""))
}
