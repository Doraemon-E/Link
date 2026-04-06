//
//  HomeDownloadWorkflowTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import XCTest
@testable import link

@MainActor
final class HomeDownloadWorkflowTests: XCTestCase {
    func testGlobalTargetSelectionPrioritizesTargetLanguageAlertWhenNoInstalledTargetModelExists() async throws {
        let inventoryProvider = FakeTranslationModelInventoryProvider(
            packages: [
                makeTranslationPackage(source: .chinese, target: .english)
            ],
            installedPackages: []
        )
        let readinessProvider = FakeTranslationAssetReadinessProvider(
            requirement: TranslationAssetRequirement(
                missingPackages: [
                    makeTranslationPackage(source: .chinese, target: .english)
                ]
            )
        )
        let environment = try makeEnvironment(
            readinessProvider: readinessProvider,
            inventoryProvider: inventoryProvider
        )
        defer { environment.cleanup() }

        let store = FakeDownloadWorkflowStore(
            sourceLanguage: .chinese,
            selectedLanguage: .english,
            isShowingLanguageSheet: true
        )
        let workflow = HomeDownloadWorkflow(store: store, dependencies: environment.dependencies)

        await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()

        XCTAssertEqual(store.deferredTargetLanguageModelPrompt?.targetLanguage, .english)
        XCTAssertNotNil(store.deferredDownloadPrompt)
        XCTAssertNil(store.activeTargetLanguageModelPrompt)
        XCTAssertNil(store.activeDownloadPrompt)

        store.isShowingLanguageSheet = false
        workflow.presentDeferredDownloadPromptIfNeeded()

        XCTAssertEqual(store.activeTargetLanguageModelPrompt?.targetLanguage, .english)
        XCTAssertNil(store.activeDownloadPrompt)
        XCTAssertNil(store.deferredDownloadPrompt)
    }

    func testGlobalTargetSelectionSkipsTargetLanguageAlertWhenMatchingInstalledModelExists() async throws {
        let inventoryProvider = FakeTranslationModelInventoryProvider(
            packages: [
                makeTranslationPackage(source: .chinese, target: .english),
                makeTranslationPackage(source: .japanese, target: .english)
            ],
            installedPackages: [
                TranslationInstalledPackageSummary(
                    packageId: "installed-ja-en",
                    version: "1.0.0",
                    sourceLanguage: .japanese,
                    targetLanguage: .english,
                    archiveSize: 1_024,
                    installedSize: 2_048,
                    installedAt: .now
                )
            ]
        )
        let environment = try makeEnvironment(
            readinessProvider: FakeTranslationAssetReadinessProvider(requirement: .ready),
            inventoryProvider: inventoryProvider
        )
        defer { environment.cleanup() }

        let store = FakeDownloadWorkflowStore(
            sourceLanguage: .chinese,
            selectedLanguage: .english,
            isShowingLanguageSheet: true
        )
        let workflow = HomeDownloadWorkflow(store: store, dependencies: environment.dependencies)

        await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()

        XCTAssertNil(store.deferredTargetLanguageModelPrompt)
        XCTAssertNil(store.activeTargetLanguageModelPrompt)
        XCTAssertNil(store.deferredDownloadPrompt)
        XCTAssertNil(store.activeDownloadPrompt)
    }

    func testGlobalTargetSelectionFallsBackToRoutePromptWhenTargetLanguageAlreadyHasInstalledModel() async throws {
        let inventoryProvider = FakeTranslationModelInventoryProvider(
            packages: [
                makeTranslationPackage(source: .chinese, target: .english),
                makeTranslationPackage(source: .japanese, target: .english)
            ],
            installedPackages: [
                TranslationInstalledPackageSummary(
                    packageId: "installed-ja-en",
                    version: "1.0.0",
                    sourceLanguage: .japanese,
                    targetLanguage: .english,
                    archiveSize: 1_024,
                    installedSize: 2_048,
                    installedAt: .now
                )
            ]
        )
        let readinessProvider = FakeTranslationAssetReadinessProvider(
            requirement: TranslationAssetRequirement(
                missingPackages: [
                    makeTranslationPackage(source: .chinese, target: .english)
                ]
            )
        )
        let environment = try makeEnvironment(
            readinessProvider: readinessProvider,
            inventoryProvider: inventoryProvider
        )
        defer { environment.cleanup() }

        let store = FakeDownloadWorkflowStore(
            sourceLanguage: .chinese,
            selectedLanguage: .english,
            isShowingLanguageSheet: true
        )
        let workflow = HomeDownloadWorkflow(store: store, dependencies: environment.dependencies)

        await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()

        XCTAssertNil(store.deferredTargetLanguageModelPrompt)
        XCTAssertNotNil(store.deferredDownloadPrompt)

        store.isShowingLanguageSheet = false
        workflow.presentDeferredDownloadPromptIfNeeded()

        XCTAssertNil(store.activeTargetLanguageModelPrompt)
        XCTAssertNotNil(store.activeDownloadPrompt)
    }

    func testGlobalTargetSelectionIgnoresStaleAsyncPromptResults() async throws {
        let inventoryProvider = FakeTranslationModelInventoryProvider(
            packages: [
                makeTranslationPackage(source: .chinese, target: .english),
                makeTranslationPackage(source: .chinese, target: .french)
            ],
            installedPackages: [],
            installedPackageDelaysNanoseconds: [
                200_000_000,
                10_000_000
            ]
        )
        let environment = try makeEnvironment(
            readinessProvider: FakeTranslationAssetReadinessProvider(requirement: .ready),
            inventoryProvider: inventoryProvider
        )
        defer { environment.cleanup() }

        let store = FakeDownloadWorkflowStore(
            sourceLanguage: .chinese,
            selectedLanguage: .english,
            isShowingLanguageSheet: true
        )
        let workflow = HomeDownloadWorkflow(store: store, dependencies: environment.dependencies)

        let firstRefresh = Task { @MainActor in
            await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()
        }

        await Task.yield()
        store.selectedLanguage = .french

        let secondRefresh = Task { @MainActor in
            await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()
        }

        await secondRefresh.value
        await firstRefresh.value

        XCTAssertEqual(store.deferredTargetLanguageModelPrompt?.targetLanguage, .french)
        XCTAssertEqual(store.selectedLanguage, .french)
    }

    func testGlobalTargetSelectionDoesNotPromptWhenNoCatalogModelExistsForTargetLanguage() async throws {
        let inventoryProvider = FakeTranslationModelInventoryProvider(
            packages: [
                makeTranslationPackage(source: .english, target: .japanese)
            ],
            installedPackages: []
        )
        let environment = try makeEnvironment(
            readinessProvider: FakeTranslationAssetReadinessProvider(requirement: .ready),
            inventoryProvider: inventoryProvider
        )
        defer { environment.cleanup() }

        let store = FakeDownloadWorkflowStore(
            sourceLanguage: .chinese,
            selectedLanguage: .french,
            isShowingLanguageSheet: true
        )
        let workflow = HomeDownloadWorkflow(store: store, dependencies: environment.dependencies)

        await workflow.refreshPromptsAfterGlobalTargetLanguageSelection()

        XCTAssertNil(store.deferredTargetLanguageModelPrompt)
        XCTAssertNil(store.activeTargetLanguageModelPrompt)
    }

    private func makeEnvironment(
        readinessProvider: any TranslationAssetReadinessProviding,
        inventoryProvider: any TranslationModelInventoryProviding
    ) throws -> TestEnvironment {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let translationRootURL = rootURL.appendingPathComponent("translation", isDirectory: true)
        let speechRootURL = rootURL.appendingPathComponent("speech", isDirectory: true)
        try FileManager.default.createDirectory(at: translationRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: speechRootURL, withIntermediateDirectories: true)

        try FileManager.default.copyItem(
            at: resourceDirectoryURL.appendingPathComponent("translation-catalog.json", isDirectory: false),
            to: translationRootURL.appendingPathComponent("catalog.json", isDirectory: false)
        )
        try FileManager.default.copyItem(
            at: resourceDirectoryURL.appendingPathComponent("speech-catalog.json", isDirectory: false),
            to: speechRootURL.appendingPathComponent("catalog.json", isDirectory: false)
        )

        let translationCatalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            baseDirectoryURLOverride: translationRootURL
        )
        let translationPackageManager = TranslationModelPackageManager(
            catalogRepository: translationCatalogRepository,
            baseDirectoryURLOverride: translationRootURL
        )
        let speechCatalogRepository = SpeechModelCatalogRepository(
            remoteCatalogURL: nil,
            baseDirectoryURLOverride: speechRootURL
        )
        let speechPackageManager = SpeechModelPackageManager(
            catalogRepository: speechCatalogRepository,
            baseDirectoryURLOverride: speechRootURL
        )

        let suiteName = "HomeDownloadWorkflowTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        let dependencies = HomeDependencies(
            appSettings: AppSettings(userDefaults: userDefaults),
            textLanguageRecognitionService: FakeTextLanguageRecognitionService(),
            translationService: FakeTranslationService(),
            speechRecognitionService: FakeSpeechRecognitionService(),
            textToSpeechService: FakeTextToSpeechService(),
            audioFilePlaybackService: FakeAudioFilePlaybackService(),
            speechPackageManager: speechPackageManager,
            translationAssetReadinessProvider: readinessProvider,
            translationModelInventoryProvider: inventoryProvider,
            modelAssetService: ModelAssetService(
                translationPackageManager: translationPackageManager,
                speechPackageManager: speechPackageManager
            ),
            microphoneRecordingService: MicrophoneRecordingService()
        )

        return TestEnvironment(
            dependencies: dependencies,
            cleanup: {
                try? FileManager.default.removeItem(at: rootURL)
                userDefaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    private var resourceDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../link/Resource", isDirectory: true)
            .standardizedFileURL
    }

    private func makeTranslationPackage(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> TranslationModelPackage {
        TranslationModelPackage(
            packageId: "test-\(source.rawValue)-\(target.rawValue)",
            version: "1.0.0",
            source: source.translationModelCode,
            target: target.translationModelCode,
            family: .marian,
            archiveURL: URL(string: "https://example.com/\(source.rawValue)-\(target.rawValue).zip")!,
            sha256: "hash",
            archiveSize: 1_024,
            installedSize: 2_048,
            manifestRelativePath: "translation-manifest.json",
            minAppVersion: "1.0.0"
        )
    }
}

private struct TestEnvironment {
    let dependencies: HomeDependencies
    let cleanup: () -> Void
}

@MainActor
private final class FakeDownloadWorkflowStore: HomeDownloadWorkflowStore {
    var sourceLanguage: SupportedLanguage
    var selectedLanguage: SupportedLanguage
    var isShowingLanguageSheet: Bool
    var isDownloadManagerPresented = false
    var isDownloadManagerLoading = false
    var hasPreparedDownloadManager = false
    var downloadableLanguagePrompt: HomeLanguageDownloadPrompt?
    var deferredDownloadPrompt: HomeLanguageDownloadPrompt?
    var activeDownloadPrompt: HomeLanguageDownloadPrompt?
    var deferredTargetLanguageModelPrompt: HomeTargetLanguageModelPrompt?
    var activeTargetLanguageModelPrompt: HomeTargetLanguageModelPrompt?
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt?
    var pendingVoiceStartAfterInstall = false
    var downloadErrorMessage: String?
    var speechErrorMessage: String?
    var assetRecords: [ModelAssetRecord] = []
    var assetSummary: ModelAssetSummary = .empty
    var speechResumeRequestToken = 0

    init(
        sourceLanguage: SupportedLanguage,
        selectedLanguage: SupportedLanguage,
        isShowingLanguageSheet: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.selectedLanguage = selectedLanguage
        self.isShowingLanguageSheet = isShowingLanguageSheet
    }
}

private final class FakeTranslationService: TranslationService, @unchecked Sendable {
    func supports(source: SupportedLanguage, target: SupportedLanguage) async throws -> Bool {
        true
    }

    func route(source: SupportedLanguage, target: SupportedLanguage) async throws -> TranslationRoute {
        TranslationRoute(
            source: source,
            target: target,
            steps: source == target ? [] : [TranslationRouteStep(source: source, target: target)]
        )
    }

    func translate(text: String, source: SupportedLanguage, target: SupportedLanguage) async throws -> String {
        text
    }

    func streamTranslation(
        text: String,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.completed(text: text))
            continuation.finish()
        }
    }
}

private final class FakeTranslationAssetReadinessProvider: TranslationAssetReadinessProviding, @unchecked Sendable {
    let requirement: TranslationAssetRequirement

    init(requirement: TranslationAssetRequirement) {
        self.requirement = requirement
    }

    func translationAssetRequirement(
        for route: TranslationRoute
    ) async throws -> TranslationAssetRequirement {
        guard !route.steps.isEmpty else {
            return .ready
        }

        return requirement
    }

    func areTranslationAssetsReady(
        for route: TranslationRoute
    ) async throws -> Bool {
        let requirement = try await translationAssetRequirement(for: route)
        return requirement.isReady
    }
}

private final class FakeTranslationModelInventoryProvider: TranslationModelInventoryProviding, @unchecked Sendable {
    private let availablePackages: [TranslationModelPackage]
    private let installedPackageSummaries: [TranslationInstalledPackageSummary]
    private let installedPackageDelaySequence: DelaySequence?

    init(
        packages: [TranslationModelPackage],
        installedPackages: [TranslationInstalledPackageSummary],
        installedPackageDelaysNanoseconds: [UInt64] = []
    ) {
        self.availablePackages = packages
        self.installedPackageSummaries = installedPackages
        if installedPackageDelaysNanoseconds.isEmpty {
            self.installedPackageDelaySequence = nil
        } else {
            self.installedPackageDelaySequence = DelaySequence(delaysNanoseconds: installedPackageDelaysNanoseconds)
        }
    }

    func packages() async throws -> [TranslationModelPackage] {
        availablePackages
    }

    func installedPackages() async throws -> [TranslationInstalledPackageSummary] {
        if let installedPackageDelaySequence {
            let delay = await installedPackageDelaySequence.nextDelay()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        return installedPackageSummaries
    }
}

private actor DelaySequence {
    private var remainingDelaysNanoseconds: [UInt64]

    init(delaysNanoseconds: [UInt64]) {
        self.remainingDelaysNanoseconds = delaysNanoseconds
    }

    func nextDelay() -> UInt64 {
        guard !remainingDelaysNanoseconds.isEmpty else {
            return 0
        }

        return remainingDelaysNanoseconds.removeFirst()
    }
}

private struct FakeTextLanguageRecognitionService: TextLanguageRecognitionService {
    func recognizeLanguage(for text: String) async throws -> TextLanguageRecognitionResult {
        TextLanguageRecognitionResult(
            language: .english,
            confidence: 1,
            hypotheses: [.english: 1]
        )
    }
}

private struct FakeSpeechRecognitionService: SpeechRecognitionService {
    func transcribe(
        samples: [Float],
        preferredLanguage: SupportedLanguage?
    ) async throws -> SpeechRecognitionResult {
        SpeechRecognitionResult(text: "", detectedLanguage: nil)
    }
}

@MainActor
private final class FakeTextToSpeechService: TextToSpeechService {
    var playbackEventHandler: ((TextToSpeechPlaybackEvent) -> Void)?

    func speak(text: String, language: SupportedLanguage, playbackID: UUID) async throws {}

    func stop() {}
}

@MainActor
private final class FakeAudioFilePlaybackService: AudioFilePlaybackService {
    var playbackEventHandler: ((AudioFilePlaybackEvent) -> Void)?

    func play(url: URL, playbackID: UUID) async throws {}

    func stop() {}
}
