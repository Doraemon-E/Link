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
    private let dependencies: HomeDependencies
    private let modelContainer: ModelContainer

    init() {
        let catalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: .main
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: catalogRepository,
            bootstrapBundle: .main
        )
        let speechCatalogRepository = SpeechModelCatalogRepository()
        let speechPackageManager = SpeechModelPackageManager(catalogRepository: speechCatalogRepository)
        let assetService = ModelAssetService(
            translationPackageManager: translationPackageManager,
            speechPackageManager: speechPackageManager
        )
        self.dependencies = HomeDependencies(
            appSettings: AppSettings(),
            textLanguageRecognitionService: SystemTextLanguageRecognitionService(),
            translationService: LlamaTranslationService(modelProvider: translationPackageManager),
            speechRecognitionService: WhisperSpeechRecognitionService(packageManager: speechPackageManager),
            textToSpeechService: SystemTextToSpeechService(),
            audioFilePlaybackService: SystemAudioFilePlaybackService(),
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: translationPackageManager,
            translationModelInventoryProvider: translationPackageManager,
            modelAssetService: assetService,
            microphoneRecordingService: MicrophoneRecordingService()
        )
        self.modelContainer = Self.makeModelContainer()

        Task.detached(priority: .utility) {
            await catalogRepository.warmUpCatalog()
            do {
                try await translationPackageManager.warmUpBundledPackages()
            } catch {
                print("[linkApp] Failed to warm up bundled translation packages: \(error.localizedDescription)")
            }
            await speechCatalogRepository.warmUpCatalog()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(dependencies: dependencies)
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
