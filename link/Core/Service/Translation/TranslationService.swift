//
//  TranslationService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

nonisolated enum TranslationStreamEvent: Sendable, Equatable {
    case started
    case partial(text: String, revision: Int, isFinal: Bool)
    case completed(text: String)
}

nonisolated protocol TranslationStreamingService: Sendable {
    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

nonisolated protocol TranslationService: TranslationStreamingService {
    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool
    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute
    func translate(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String
}
