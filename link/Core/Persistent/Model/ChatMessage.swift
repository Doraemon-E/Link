//
//  ChatMessage.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import SwiftData

enum ChatMessageInputType: String, Codable {
    case text
    case speech
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var inputType: ChatMessageInputType
    var sourceText: String
    var translatedText: String
    var sourceLanguage: SupportedLanguage?
    var targetLanguage: SupportedLanguage?
    var audioURL: String?
    var createdAt: Date
    var sequence: Int
    var session: ChatSession?

    init(
        id: UUID = UUID(),
        inputType: ChatMessageInputType = .text,
        sourceText: String,
        translatedText: String = "",
        sourceLanguage: SupportedLanguage? = nil,
        targetLanguage: SupportedLanguage? = nil,
        audioURL: String? = nil,
        createdAt: Date = .now,
        sequence: Int,
        session: ChatSession? = nil
    ) {
        self.id = id
        self.inputType = inputType
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.audioURL = audioURL
        self.createdAt = createdAt
        self.sequence = sequence
        self.session = session
    }
}
