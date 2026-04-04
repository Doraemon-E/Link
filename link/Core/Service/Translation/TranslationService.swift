//
//  TranslationService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

enum TranslationStreamEvent: Sendable, Equatable {
    case started
    case partial(text: String, revision: Int, isFinal: Bool)
    case completed(text: String)
}

protocol TranslationStreamingService: Sendable {
    func streamTranslation(
        text: String,
        source: HomeLanguage,
        target: HomeLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

protocol TranslationService: TranslationStreamingService {
    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool
    func route(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRoute
    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String
}
