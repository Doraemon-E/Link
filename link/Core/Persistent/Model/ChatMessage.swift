//
//  ChatMessage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import SwiftData

enum ChatMessageSender: String, Codable {
    case user
    case assistant
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var sender: ChatMessageSender
    var text: String
    var createdAt: Date
    var sequence: Int
    var session: ChatSession?

    init(
        id: UUID = UUID(),
        sender: ChatMessageSender,
        text: String,
        createdAt: Date = .now,
        sequence: Int,
        session: ChatSession? = nil
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.sequence = sequence
        self.session = session
    }
}
