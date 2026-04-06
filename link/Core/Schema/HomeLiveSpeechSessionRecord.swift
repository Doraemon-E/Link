//
//  HomeLiveSpeechSessionRecord.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

struct HomeLiveSpeechSessionRecord {
    let session: ChatSession
    let message: ChatMessage
    let fallbackSourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
}
