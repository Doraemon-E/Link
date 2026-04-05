//
//  TranslationGoldenCase.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import Foundation
@testable import link

struct TranslationGoldenCase: Codable, Identifiable {
    let id: String
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let input: String
    let expected: String
    let category: String
}

enum TranslationGoldenCaseStore {
    static func load(from bundle: Bundle = testBundle) throws -> [TranslationGoldenCase] {
        let fileURL = try casesURL(in: bundle)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([TranslationGoldenCase].self, from: data)
    }

    static func casesURL(in bundle: Bundle) throws -> URL {
        let candidateDirectories = bundledCandidateDirectories(in: bundle)

        for directoryURL in candidateDirectories {
            let fileURL = directoryURL.appendingPathComponent("translation-golden-cases.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }

        throw CocoaError(.fileNoSuchFile)
    }

    static func bundledCandidateDirectories(in bundle: Bundle) -> [URL] {
        guard let resourceURL = bundle.resourceURL else {
            return []
        }

        return [
            resourceURL.appendingPathComponent("Resource", isDirectory: true),
            resourceURL
        ]
    }
}

private final class TranslationGoldenCaseBundleMarker {}

let testBundle = Bundle(for: TranslationGoldenCaseBundleMarker.self)
