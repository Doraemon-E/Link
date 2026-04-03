//
//  HomeChatInputBar.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatInputBar: View {
    @Binding var text: String
    @Binding var isFocused: Bool

    let onFocusActivated: () -> Void
    let onSend: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "message")
                .foregroundStyle(.secondary)

            TextField("请输入对话内容", text: $text)
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .onSubmit {
                    handleSend()
                }

            Button(action: handleSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isSendEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isSendEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
//        .overlay(
//            RoundedRectangle(cornerRadius: 20, style: .continuous)
//                .stroke(Color(uiColor: .separator), lineWidth: 1)
//        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
        .onChange(of: isTextFieldFocused) { oldValue, newValue in
            if !oldValue && newValue {
                onFocusActivated()
            }

            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                isFocused = newValue
            }
        }
        .onChange(of: isFocused) { _, newValue in
            if isTextFieldFocused != newValue {
                isTextFieldFocused = newValue
            }
        }
    }

    private var isSendEnabled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleSend() {
        guard isSendEnabled else { return }
        onSend()
    }
}

#Preview {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        onFocusActivated: {},
        onSend: {}
    )
}
