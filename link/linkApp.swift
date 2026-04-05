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
    private let speechModelInstaller: SpeechModelInstaller
    private let speechRecognitionService: SpeechRecognitionService
    private let textToSpeechService: TextToSpeechService
    private let modelDownloadCenter: ModelDownloadCenter
    private let microphoneRecordingService: MicrophoneRecordingService

    init() {
        let catalogService = TranslationModelCatalogService()
        let installer = TranslationModelInstaller(catalogService: catalogService)
        let speechCatalogService = SpeechModelCatalogService()
        let speechInstaller = SpeechModelInstaller(catalogService: speechCatalogService)
        let downloadCenter = ModelDownloadCenter(
            translationInstaller: installer,
            speechInstaller: speechInstaller
        )
        self.appSettings = AppSettings()
        self.translationService = MarianTranslationService(modelAccess: installer)
        self.speechModelInstaller = speechInstaller
        self.speechRecognitionService = WhisperSpeechRecognitionService(installer: speechInstaller)
        self.textToSpeechService = SystemTextToSpeechService()
        self.modelDownloadCenter = downloadCenter
        self.microphoneRecordingService = MicrophoneRecordingService()

        Task.detached(priority: .utility) {
            await catalogService.warmUpCatalog()
            await speechCatalogService.warmUpCatalog()
            await downloadCenter.warmUp()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appSettings: appSettings,
                translationService: translationService,
                speechRecognitionService: speechRecognitionService,
                textToSpeechService: textToSpeechService,
                speechModelInstaller: speechModelInstaller,
                modelDownloadCenter: modelDownloadCenter,
                microphoneRecordingService: microphoneRecordingService
            )
        }
        .modelContainer(for: [ChatSession.self, ChatMessage.self])
    }
}
