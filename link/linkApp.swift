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
        let installer = TranslationModelInstaller()
        self.translationModelInstaller = installer
        self.translationService = MarianTranslationService(installer: installer)

        Task.detached(priority: .utility) {
            _ = try? installer.prepareModel()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(translationService: translationService)
        }
        .modelContainer(for: [ChatSession.self, ChatMessage.self])
    }
}
