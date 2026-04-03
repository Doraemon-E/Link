//
//  HomeSessionHistorySheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeSessionHistorySheet: View {
    let sessions: [ChatSession]
    let currentSessionID: UUID?
    let onSelect: (UUID) -> Void
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "暂无历史会话",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List(sessions, id: \.id) { session in
                        Button {
                            onSelect(session.id)
                        } label: {
                            sessionRow(for: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("历史会话")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sessionRow(for session: ChatSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionTitle(for: session))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if session.id == currentSessionID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sessionTitle(for session: ChatSession) -> String {
        if let firstUserMessage = session.sortedMessages.first(where: { $0.sender == .user }) {
            let trimmedText = firstUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                return trimmedText
            }
        }

        if let firstMessage = session.sortedMessages.first {
            let trimmedText = firstMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                return trimmedText
            }
        }

        return "新会话"
    }
}

#Preview {
    HomeSessionHistorySheet(
        sessions: [],
        currentSessionID: nil,
        onSelect: { _ in },
        isPresented: .constant(true)
    )
}
