//
//  HomeSessionHistorySheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

enum HomeSessionHistoryPreviewText {
    static let emptySessionFallback = "新会话"

    static func resolve(from messages: [ChatMessage]) -> String {
        for message in messages.reversed() {
            let sourceText = message.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceText.isEmpty {
                return sourceText
            }
        }

        return emptySessionFallback
    }
}

struct HomeSessionHistorySheet: View {
    private struct SessionDaySection: Identifiable {
        let day: Date
        let sessions: [ChatSession]

        var id: Date { day }
    }

    let sessions: [ChatSession]
    let deletableSessionIDs: Set<UUID>
    let currentSessionID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "暂无历史会话",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(sectionHeaderTitle(for: section.day)) {
                                ForEach(section.sessions, id: \.id) { session in
                                    sessionRow(for: session)
                                }
                            }
                        }
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

    private var sections: [SessionDaySection] {
        Dictionary(grouping: sessions) { normalizedDay(for: $0.updatedAt) }
            .map { day, groupedSessions in
                SessionDaySection(
                    day: day,
                    sessions: groupedSessions.sorted { lhs, rhs in
                        if lhs.updatedAt == rhs.updatedAt {
                            if lhs.createdAt == rhs.createdAt {
                                return lhs.id.uuidString > rhs.id.uuidString
                            }

                            return lhs.createdAt > rhs.createdAt
                        }

                        return lhs.updatedAt > rhs.updatedAt
                    }
                )
            }
            .sorted { $0.day > $1.day }
    }

    @ViewBuilder
    private func sessionRow(for session: ChatSession) -> some View {
        if deletableSessionIDs.contains(session.id) {
            sessionRowButton(for: session)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDelete(session.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除会话")
                }
        } else {
            sessionRowButton(for: session)
        }
    }

    private func sessionRowButton(for session: ChatSession) -> some View {
        Button {
            onSelect(session.id)
        } label: {
            sessionRowContent(for: session)
        }
        .buttonStyle(.plain)
    }

    private func sessionRowContent(for session: ChatSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionPreviewText(for: session))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(timeString(for: session.updatedAt))
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

    private func sessionPreviewText(for session: ChatSession) -> String {
        HomeSessionHistoryPreviewText.resolve(from: session.sortedMessages)
    }

    private func normalizedDay(for date: Date) -> Date {
        Calendar.autoupdatingCurrent.startOfDay(for: date)
    }

    private func sectionHeaderTitle(for day: Date) -> String {
        day.formatted(date: .long, time: .omitted)
    }

    private func timeString(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

#Preview {
    HomeSessionHistorySheet(
        sessions: [],
        deletableSessionIDs: [],
        currentSessionID: nil,
        onSelect: { _ in },
        onDelete: { _ in },
        isPresented: .constant(true)
    )
}
