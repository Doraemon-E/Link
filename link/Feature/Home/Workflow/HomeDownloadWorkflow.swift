//
//  HomeDownloadWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
protocol HomeDownloadWorkflowStore: AnyObject {
    var sourceLanguage: SupportedLanguage { get }
    var selectedLanguage: SupportedLanguage { get }
    var isShowingLanguageSheet: Bool { get }
    var isDownloadManagerPresented: Bool { get set }
    var isDownloadManagerLoading: Bool { get set }
    var hasPreparedDownloadManager: Bool { get set }
    var downloadableLanguagePrompt: HomeLanguageDownloadPrompt? { get set }
    var deferredDownloadPrompt: HomeLanguageDownloadPrompt? { get set }
    var activeDownloadPrompt: HomeLanguageDownloadPrompt? { get set }
    var deferredTargetLanguageModelPrompt: HomeTargetLanguageModelPrompt? { get set }
    var activeTargetLanguageModelPrompt: HomeTargetLanguageModelPrompt? { get set }
    var activeSpeechDownloadPrompt: SpeechModelDownloadPrompt? { get set }
    var pendingVoiceStartAfterInstall: Bool { get set }
    var downloadErrorMessage: String? { get set }
    var speechErrorMessage: String? { get set }
    var assetRecords: [ModelAssetRecord] { get set }
    var assetSummary: ModelAssetSummary { get set }
    var speechResumeRequestToken: Int { get set }
}

@MainActor
final class HomeDownloadWorkflow {
    private static let minimumLoadingDuration: TimeInterval = 2.0

    private weak var store: (any HomeDownloadWorkflowStore)?
    private let dependencies: HomeDependencies
    private var downloadObservationTask: Task<Void, Never>?
    private var downloadMilestoneSignature = ""
    private var pendingSpeechResumePackageID: String?
    private var isPreparingDownloadManager = false
    private var targetLanguagePromptRefreshToken = 0

    init(store: any HomeDownloadWorkflowStore, dependencies: HomeDependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    func startObservingDownloads() {
        guard downloadObservationTask == nil else {
            return
        }

        downloadObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dependencies.modelAssetService.warmUp()
            let stream = await self.dependencies.modelAssetService.snapshotStream()

            for await snapshot in stream {
                guard let store = self.store else { break }
                store.assetRecords = snapshot.records
                store.assetSummary = snapshot.summary
                self.handleAssetMilestones(for: snapshot)
            }
        }
    }

    func presentDeferredDownloadPromptIfNeeded() {
        guard let store = self.store,
              !store.isShowingLanguageSheet,
              store.activeTargetLanguageModelPrompt == nil,
              store.activeDownloadPrompt == nil else {
            return
        }

        if let deferredTargetLanguageModelPrompt = store.deferredTargetLanguageModelPrompt {
            store.activeTargetLanguageModelPrompt = deferredTargetLanguageModelPrompt
            store.deferredTargetLanguageModelPrompt = nil
            store.deferredDownloadPrompt = nil
            return
        }

        guard let deferredDownloadPrompt = store.deferredDownloadPrompt else {
            return
        }

        store.activeDownloadPrompt = deferredDownloadPrompt
        store.deferredDownloadPrompt = nil
    }

    func openDownloadManager() {
        presentDownloadManager()
    }

    func prepareDownloadManagerIfNeeded() async {
        guard let store = self.store,
              !store.hasPreparedDownloadManager,
              !isPreparingDownloadManager else {
            return
        }

        isPreparingDownloadManager = true
        store.isDownloadManagerLoading = true
        let loadingStartedAt = Date()
        defer {
            isPreparingDownloadManager = false
            store.isDownloadManagerLoading = false
        }

        await dependencies.modelAssetService.warmUp()
        let snapshot = await dependencies.modelAssetService.currentSnapshot()
        await ensureMinimumLoadingDuration(since: loadingStartedAt)
        store.assetRecords = snapshot.records
        store.assetSummary = snapshot.summary
        store.hasPreparedDownloadManager = true
    }

    func presentDownloadPrompt() {
        guard let store = self.store else { return }
        guard let downloadableLanguagePrompt = store.downloadableLanguagePrompt else {
            openDownloadManager()
            return
        }

        store.activeDownloadPrompt = downloadableLanguagePrompt
    }

    func dismissDownloadPrompt() {
        store?.activeDownloadPrompt = nil
    }

    func dismissTargetLanguageModelPrompt() {
        store?.activeTargetLanguageModelPrompt = nil
    }

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt) {
        guard let store = self.store else { return }
        store.downloadableLanguagePrompt = prompt
        store.deferredDownloadPrompt = nil
        store.activeDownloadPrompt = prompt
    }

    func dismissSpeechDownloadPrompt() {
        store?.activeSpeechDownloadPrompt = nil
        store?.pendingVoiceStartAfterInstall = false
        pendingSpeechResumePackageID = nil
    }

    func openDownloadManagerForActiveTranslationPrompt() {
        guard let store = self.store else { return }
        store.activeDownloadPrompt = nil
        presentDownloadManager()
    }

    func openDownloadManagerForActiveTargetLanguagePrompt() {
        guard let store = self.store else { return }
        store.activeTargetLanguageModelPrompt = nil
        presentDownloadManager()
    }

    func openDownloadManagerForSpeechPrompt(
        packageId: String,
        shouldResumeRecording: Bool
    ) {
        guard let store = self.store else { return }
        store.activeSpeechDownloadPrompt = nil
        store.pendingVoiceStartAfterInstall = shouldResumeRecording
        pendingSpeechResumePackageID = shouldResumeRecording ? packageId : nil
        presentDownloadManager()
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
        guard let store = self.store else { return }
        let source = store.sourceLanguage
        let target = store.selectedLanguage
        let prompt = await downloadPromptIfNeeded(source: source, target: target)

        guard source == store.sourceLanguage, target == store.selectedLanguage else {
            return
        }

        store.downloadableLanguagePrompt = prompt

        if prompt == nil {
            store.deferredDownloadPrompt = nil
            store.activeDownloadPrompt = nil
        }
    }

    func refreshPromptsAfterGlobalTargetLanguageSelection() async {
        guard let store = self.store else { return }

        targetLanguagePromptRefreshToken += 1
        let refreshToken = targetLanguagePromptRefreshToken
        let source = store.sourceLanguage
        let target = store.selectedLanguage

        let targetLanguagePrompt = await targetLanguageModelPromptIfNeeded(targetLanguage: target)
        let translationPrompt = await downloadPromptIfNeeded(source: source, target: target)

        guard let store = self.store,
              refreshToken == targetLanguagePromptRefreshToken,
              source == store.sourceLanguage,
              target == store.selectedLanguage else {
            return
        }

        store.activeTargetLanguageModelPrompt = nil
        store.deferredTargetLanguageModelPrompt = targetLanguagePrompt
        store.activeDownloadPrompt = nil
        store.downloadableLanguagePrompt = translationPrompt
        store.deferredDownloadPrompt = translationPrompt

        if translationPrompt == nil {
            store.activeDownloadPrompt = nil
        }

        presentDeferredDownloadPromptIfNeeded()
    }

    func installTranslationModel(packageIds: [String]) async {
        guard !packageIds.isEmpty else { return }

        guard let store = self.store else { return }
        store.downloadErrorMessage = nil
        store.activeDownloadPrompt = nil
        presentDownloadManager()
        await dependencies.modelAssetService.startAssets(kind: .translation, packageIDs: packageIds)
        await refreshDownloadAvailabilityForCurrentSelection()
    }

    func installSpeechModelAndResumeIfNeeded(
        packageId: String,
        shouldResumeRecording: Bool
    ) async {
        guard let store = self.store else { return }
        store.speechErrorMessage = nil
        store.activeSpeechDownloadPrompt = nil
        presentDownloadManager()
        store.pendingVoiceStartAfterInstall = shouldResumeRecording
        pendingSpeechResumePackageID = packageId
        await dependencies.modelAssetService.startAssets(kind: .speech, packageIDs: [packageId])
    }

    func retryDownload(itemID: String) async {
        await dependencies.modelAssetService.retry(assetID: itemID)
    }

    func resumeDownload(itemID: String) async {
        await dependencies.modelAssetService.resume(assetID: itemID)
    }

    func startDownload(item: ModelAssetRecord) async {
        await dependencies.modelAssetService.startAssets(
            kind: item.kind,
            packageIDs: [item.asset.packageId]
        )
    }

    func deleteInstalledDownload(itemID: String) async {
        do {
            try await dependencies.modelAssetService.removeInstalledAsset(id: itemID)
            await refreshDownloadAvailabilityForCurrentSelection()
        } catch let error as TranslationError {
            store?.downloadErrorMessage = error.userFacingMessage
        } catch let error as SpeechRecognitionError {
            store?.speechErrorMessage = error.userFacingMessage
        } catch {
            store?.downloadErrorMessage = "删除模型失败，请稍后再试。"
        }
    }

    func translationDownloadPrompt(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> HomeLanguageDownloadPrompt? {
        let requirement = try await translationDownloadRequirement(
            source: source,
            target: target
        )
        guard !requirement.isReady else {
            return nil
        }

        return HomeLanguageDownloadPrompt(
            sourceLanguage: source,
            targetLanguage: target,
            requirement: requirement
        )
    }

    func downloadPromptIfNeeded(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> HomeLanguageDownloadPrompt? {
        do {
            return try await translationDownloadPrompt(source: source, target: target)
        } catch {
            return nil
        }
    }

    func isTranslationReady(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> Bool {
        do {
            let route = try await dependencies.translationService.route(source: source, target: target)
            return try await dependencies.translationAssetReadinessProvider.areTranslationAssetsReady(
                for: route
            )
        } catch {
            return false
        }
    }

    func targetLanguageModelPromptIfNeeded(
        targetLanguage: SupportedLanguage
    ) async -> HomeTargetLanguageModelPrompt? {
        do {
            let installedPackages = try await dependencies.translationModelInventoryProvider.installedPackages()
            if installedPackages.contains(where: { $0.targetLanguage == targetLanguage }) {
                return nil
            }

            let packages = try await dependencies.translationModelInventoryProvider.packages()
            let hasAvailableTargetLanguageModel = packages.contains {
                SupportedLanguage.fromTranslationModelCode($0.target) == targetLanguage
            }
            guard hasAvailableTargetLanguageModel else {
                return nil
            }

            return HomeTargetLanguageModelPrompt(targetLanguage: targetLanguage)
        } catch {
            return nil
        }
    }

    func speechDownloadPromptIfNeeded() async throws -> SpeechModelDownloadPrompt? {
        guard let package = try await dependencies.speechPackageManager.defaultPackageMetadata() else {
            throw SpeechRecognitionError.modelPackageUnavailable
        }

        if try await dependencies.speechPackageManager.isDefaultPackageInstalled() {
            return nil
        }

        return SpeechModelDownloadPrompt(package: package)
    }

    private func handleAssetMilestones(for snapshot: ModelAssetSnapshot) {
        let milestoneSignature = snapshot.records
            .map { "\($0.id):\($0.status.state.rawValue):\($0.isInstalled)" }
            .sorted()
            .joined(separator: "|")

        if milestoneSignature != downloadMilestoneSignature {
            downloadMilestoneSignature = milestoneSignature

            Task {
                await refreshDownloadAvailabilityForCurrentSelection()
            }
        }

        guard let store = self.store,
              store.pendingVoiceStartAfterInstall,
              let packageID = pendingSpeechResumePackageID else {
            return
        }

        let matchingItemID = ModelAsset.makeID(kind: .speech, packageId: packageID)

        if snapshot.records.contains(where: {
            $0.id == matchingItemID && $0.isInstalled
        }) {
            store.pendingVoiceStartAfterInstall = false
            pendingSpeechResumePackageID = nil
            store.speechResumeRequestToken += 1
        }

        if snapshot.records.contains(where: {
            $0.id == matchingItemID && $0.status.state == .failed
        }) {
            store.pendingVoiceStartAfterInstall = false
            pendingSpeechResumePackageID = nil
        }
    }

    private func translationDownloadRequirement(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> TranslationAssetRequirement {
        let route = try await dependencies.translationService.route(source: source, target: target)
        return try await dependencies.translationAssetReadinessProvider.translationAssetRequirement(
            for: route
        )
    }

    private func presentDownloadManager() {
        guard let store = self.store else { return }
        if !store.hasPreparedDownloadManager {
            store.isDownloadManagerLoading = true
        }

        store.isDownloadManagerPresented = true
    }

    private func ensureMinimumLoadingDuration(since startedAt: Date) async {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = Self.minimumLoadingDuration - elapsed

        guard remaining > 0 else {
            return
        }

        let nanoseconds = UInt64(remaining * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
