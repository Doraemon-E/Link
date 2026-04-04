//
//  TranslationService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

protocol TranslationService {
    func supports(source: HomeLanguage, target: HomeLanguage) async throws -> Bool
    func route(source: HomeLanguage, target: HomeLanguage) async throws -> TranslationRoute
    func translate(text: String, source: HomeLanguage, target: HomeLanguage) async throws -> String
}
