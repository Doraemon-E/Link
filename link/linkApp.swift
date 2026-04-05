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
    private let appSettings: AppSettings
    private let translationService: TranslationService
    private let speechPackageManager: SpeechModelPackageManager
    private let speechRecognitionService: SpeechRecognitionService
    private let textToSpeechService: TextToSpeechService
    private let modelAssetService: ModelAssetService
    private let microphoneRecordingService: MicrophoneRecordingService
    private let modelContainer: ModelContainer

    init() {
        let catalogRepository = TranslationModelCatalogRepository()
        let translationPackageManager = TranslationModelPackageManager(catalogRepository: catalogRepository)
        let speechCatalogRepository = SpeechModelCatalogRepository()
        let speechPackageManager = SpeechModelPackageManager(catalogRepository: speechCatalogRepository)
        let assetService = ModelAssetService(
            translationPackageManager: translationPackageManager,
            speechPackageManager: speechPackageManager
        )
        self.appSettings = AppSettings()
        self.translationService = MarianTranslationService(modelProvider: translationPackageManager)
        self.speechPackageManager = speechPackageManager
        self.speechRecognitionService = WhisperSpeechRecognitionService(packageManager: speechPackageManager)
        self.textToSpeechService = SystemTextToSpeechService()
        self.modelAssetService = assetService
        self.microphoneRecordingService = MicrophoneRecordingService()
        self.modelContainer = Self.makeModelContainer()

        Task.detached(priority: .utility) {
            await catalogRepository.warmUpCatalog()
            await speechCatalogRepository.warmUpCatalog()
            await assetService.warmUp()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appSettings: appSettings,
                translationService: translationService,
                speechRecognitionService: speechRecognitionService,
                textToSpeechService: textToSpeechService,
                speechPackageManager: speechPackageManager,
                modelAssetService: modelAssetService,
                microphoneRecordingService: microphoneRecordingService
            )
        }
        .modelContainer(modelContainer)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            ChatSession.self,
            ChatMessage.self
        ])
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        do {
            try fileManager.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
            let storeURL = applicationSupportURL.appendingPathComponent("link-chat-v3.sqlite")
            let configuration = ModelConfiguration(
                schema: schema,
                url: storeURL
            )
            return try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }
}
