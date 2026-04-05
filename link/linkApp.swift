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
        .modelContainer(for: [ChatSession.self, ChatMessage.self])
    }
}
