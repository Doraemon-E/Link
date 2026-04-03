//
//  ChatSession.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import SwiftData

@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session) var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var hasMessages: Bool {
        !messages.isEmpty
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.createdAt < rhs.createdAt
            }

            return lhs.sequence < rhs.sequence
        }
    }
}
