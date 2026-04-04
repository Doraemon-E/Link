//
//  linkApp.swift
//  link
//
//  Created by Doracmon on 2026/4/3.
//

import SwiftUI
import SwiftData

@main
struct linkApp: App {
    private let translationModelInstaller: TranslationModelInstaller
    private let translationService: TranslationService

    init() {
        let catalogService = TranslationModelCatalogService()
        let installer = TranslationModelInstaller(catalogService: catalogService)
        self.translationModelInstaller = installer
        self.translationService = MarianTranslationService(installer: installer)

        Task.detached(priority: .utility) {
            await catalogService.warmUpCatalog()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                translationService: translationService,
                translationModelInstaller: translationModelInstaller
            )
        }
        .modelContainer(for: [ChatSession.self, ChatMessage.self])
    }
}
