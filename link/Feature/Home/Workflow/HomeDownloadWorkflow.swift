//
//  HomeDownloadWorkflow.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
final class HomeDownloadWorkflow {
    private unowned let store: HomeStore
    private let dependencies: HomeDependencies
    private var downloadObservationTask: Task<Void, Never>?
    private var downloadMilestoneSignature = ""
    private var pendingSpeechResumePackageID: String?

    init(store: HomeStore, dependencies: HomeDependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    func startObservingDownloads() {
        guard downloadObservationTask == nil else {
            return
        }

        downloadObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.dependencies.modelAssetService.snapshotStream()

            for await snapshot in stream {
                self.store.assetRecords = snapshot.records
                self.store.assetSummary = snapshot.summary
                self.handleAssetMilestones(for: snapshot)
            }
        }
    }

    func resolveLanguageSelection(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async -> HomeLanguageSelectionResolution {
        do {
            let requirement = try await translationDownloadRequirement(
                source: source,
                target: target
            )

            if requirement.isReady {
                return .ready
            }

            return .requiresDownload(
                HomeLanguageDownloadPrompt(
                    sourceLanguage: source,
                    targetLanguage: target,
                    requirement: requirement
                )
            )
        } catch let error as TranslationError {
            return .failure(error.userFacingMessage)
        } catch {
            return .failure("暂时无法检查翻译模型，请稍后再试。")
        }
    }

    func commitLanguageSelection(
        source: SupportedLanguage,
        target: SupportedLanguage
    ) {
        store.sourceLanguage = source
        store.selectedLanguage = target
        store.downloadableLanguagePrompt = nil
        store.deferredDownloadPrompt = nil
        store.activeDownloadPrompt = nil
    }

    func commitLanguageSelectionRequiringDownload(
        source: SupportedLanguage,
        target: SupportedLanguage,
        prompt: HomeLanguageDownloadPrompt
    ) {
        store.sourceLanguage = source
        store.selectedLanguage = target
        store.downloadableLanguagePrompt = prompt
        store.deferredDownloadPrompt = prompt
        store.activeDownloadPrompt = nil
    }

    func presentDeferredDownloadPromptIfNeeded() {
        guard !store.isLanguageSheetPresented, let deferredDownloadPrompt = store.deferredDownloadPrompt else {
            return
        }

        store.activeDownloadPrompt = deferredDownloadPrompt
        store.deferredDownloadPrompt = nil
    }

    func openDownloadManager() {
        store.isDownloadManagerPresented = true
    }

    func presentDownloadPrompt() {
        guard let downloadableLanguagePrompt = store.downloadableLanguagePrompt else {
            openDownloadManager()
            return
        }

        store.activeDownloadPrompt = downloadableLanguagePrompt
    }

    func dismissDownloadPrompt() {
        store.activeDownloadPrompt = nil
    }

    func presentTranslationDownloadPrompt(_ prompt: HomeLanguageDownloadPrompt) {
        store.downloadableLanguagePrompt = prompt
        store.deferredDownloadPrompt = nil
        store.activeDownloadPrompt = prompt
    }

    func dismissSpeechDownloadPrompt() {
        store.activeSpeechDownloadPrompt = nil
        store.pendingVoiceStartAfterInstall = false
    }

    func refreshDownloadAvailabilityForCurrentSelection() async {
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

    func installTranslationModel(packageIds: [String]) async {
        guard !packageIds.isEmpty else { return }

        store.downloadErrorMessage = nil
        store.activeDownloadPrompt = nil
        store.isDownloadManagerPresented = true
        await dependencies.modelAssetService.startAssets(kind: .translation, packageIDs: packageIds)
        await refreshDownloadAvailabilityForCurrentSelection()
    }

    func installSpeechModelAndResumeIfNeeded(
        packageId: String,
        shouldResumeRecording: Bool
    ) async {
        store.speechErrorMessage = nil
        store.activeSpeechDownloadPrompt = nil
        store.isDownloadManagerPresented = true
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
            store.downloadErrorMessage = error.userFacingMessage
        } catch let error as SpeechRecognitionError {
            store.speechErrorMessage = error.userFacingMessage
        } catch {
            store.downloadErrorMessage = "删除模型失败，请稍后再试。"
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

        guard store.pendingVoiceStartAfterInstall,
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
}
