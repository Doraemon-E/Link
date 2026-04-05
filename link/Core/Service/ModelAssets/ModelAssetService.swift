//
//  ModelAssetService.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

actor ModelAssetService: TranslationAssetReadinessProviding {
    private let translationPackageManager: TranslationModelPackageManager
    private let translationAssetSource: TranslationModelAssetSource
    private let speechAssetSource: SpeechModelAssetSource
    private let archiveService: ResumableAssetArchiveService
    private let snapshotStore: ModelAssetSnapshotStore

    init(
        translationPackageManager: TranslationModelPackageManager,
        speechPackageManager: SpeechModelPackageManager,
        archiveService: ResumableAssetArchiveService = ResumableAssetArchiveService(),
        snapshotStore: ModelAssetSnapshotStore = ModelAssetSnapshotStore(),
        presentationMapper: ModelAssetPresentationMapper = ModelAssetPresentationMapper()
    ) {
        self.translationPackageManager = translationPackageManager
        self.translationAssetSource = TranslationModelAssetSource(
            packageManager: translationPackageManager,
            presentationMapper: presentationMapper
        )
        self.speechAssetSource = SpeechModelAssetSource(
            packageManager: speechPackageManager,
            presentationMapper: presentationMapper
        )
        self.archiveService = archiveService
        self.snapshotStore = snapshotStore
    }

    func warmUp() async {
        await reloadInstalledRecords()
        await reloadPersistedTransfers()
        await reloadAvailableRecords()
    }

    func snapshotStream() async -> AsyncStream<ModelAssetSnapshot> {
        await snapshotStore.snapshotStream()
    }

    func currentSnapshot() async -> ModelAssetSnapshot {
        await snapshotStore.currentSnapshot()
    }

    func startTranslationAssets(packageIDs: [String]) async {
        for packageID in packageIDs {
            await startAsset(kind: .translation, packageId: packageID)
        }
    }

    func startSpeechAsset(packageId: String) async {
        await startAsset(kind: .speech, packageId: packageId)
    }

    func retry(assetID: String) async {
        guard let record = await snapshotStore.transientRecord(id: assetID) else {
            return
        }

        await startAsset(kind: record.kind, packageId: record.asset.packageId)
    }

    func resume(assetID: String) async {
        guard let record = await snapshotStore.transientRecord(id: assetID) else {
            return
        }

        await startAsset(kind: record.kind, packageId: record.asset.packageId)
    }

    func removeInstalledAsset(id assetID: String) async throws {
        guard let record = await snapshotStore.installedRecord(id: assetID) else {
            return
        }

        try await source(for: record.kind).removeInstalledAsset(packageId: record.asset.packageId)
        await reloadInstalledRecords()
        await reloadAvailableRecords()
    }

    func translationAssetRequirement(
        for route: TranslationRoute
    ) async throws -> TranslationAssetRequirement {
        try await translationPackageManager.assetRequirement(for: route)
    }

    func areTranslationAssetsReady(
        for route: TranslationRoute
    ) async throws -> Bool {
        try await translationPackageManager.areAssetsReady(for: route)
    }

    private func startAsset(kind: ModelAssetKind, packageId: String) async {
        let source = source(for: kind)

        guard let asset = try? await source.resolveAsset(
            packageId: packageId,
            fallbackURL: nil,
            fallbackArchiveSize: nil
        ) else {
            return
        }

        guard await snapshotStore.reserveRun(for: asset) else {
            return
        }

        let task = Task { [asset] in
            await self.runDownload(for: asset)
        }
        await snapshotStore.activateRun(task, for: asset.id)
    }

    private func runDownload(for asset: ModelAsset) async {
        let source = source(for: asset.kind)

        do {
            let archiveURL = try await archiveService.download(asset: asset) { status in
                await self.updateTransientRecord(for: asset, status: status, errorMessage: nil)
            }

            await updateTransientRecord(
                for: asset,
                status: ModelAssetTransferStatus(
                    state: .verifying,
                    downloadedBytes: asset.archiveSize,
                    totalBytes: asset.archiveSize
                ),
                errorMessage: nil
            )

            await updateTransientRecord(
                for: asset,
                status: ModelAssetTransferStatus(
                    state: .installing,
                    downloadedBytes: asset.archiveSize,
                    totalBytes: asset.archiveSize
                ),
                errorMessage: nil
            )

            try await source.installAsset(packageId: asset.packageId, archiveURL: archiveURL)

            try? await archiveService.removePersistedTransfer(for: asset)
            await snapshotStore.removeTransientRecord(id: asset.id)
            await snapshotStore.clearRun(for: asset.id)
            await reloadInstalledRecords()
            await reloadAvailableRecords()
        } catch {
            await snapshotStore.clearRun(for: asset.id)
            let previousState = await snapshotStore.transientRecord(id: asset.id)?.status.state

            if previousState == .verifying || previousState == .installing {
                try? await archiveService.removePersistedTransfer(for: asset)
            }

            let persistedStatus = try? await archiveService.persistedStatus(for: asset)
            let fallbackStatus = persistedStatus ?? ModelAssetTransferStatus(
                state: .failed,
                downloadedBytes: 0,
                totalBytes: asset.archiveSize
            )

            await snapshotStore.updateTransientRecord(
                .transient(
                    asset: asset,
                    status: ModelAssetTransferStatus(
                        state: .failed,
                        downloadedBytes: fallbackStatus.downloadedBytes,
                        totalBytes: fallbackStatus.totalBytes,
                        isResumable: fallbackStatus.downloadedBytes > 0
                    ),
                    errorMessage: normalizedErrorMessage(from: error)
                )
            )
        }
    }

    private func updateTransientRecord(
        for asset: ModelAsset,
        status: ModelAssetTransferStatus,
        errorMessage: String?
    ) async {
        await snapshotStore.updateTransientRecord(
            .transient(asset: asset, status: status, errorMessage: errorMessage)
        )
    }

    private func reloadInstalledRecords() async {
        var records: [ModelAssetRecord] = []

        if let translationRecords = try? await translationAssetSource.installedRecords() {
            records.append(contentsOf: translationRecords)
        }

        if let speechRecords = try? await speechAssetSource.installedRecords() {
            records.append(contentsOf: speechRecords)
        }

        await snapshotStore.replaceInstalledRecords(records)
    }

    private func reloadPersistedTransfers() async {
        var restoredRecords: [ModelAssetRecord] = []

        for kind in [ModelAssetKind.translation, .speech] {
            let persistedStates = (try? await archiveService.persistedStates(for: kind)) ?? []

            for state in persistedStates {
                let assetID = ModelAsset.makeID(kind: kind, packageId: state.packageId)
                guard !(await snapshotStore.isRunning(id: assetID)) else {
                    continue
                }

                guard let asset = try? await source(for: kind).resolveAsset(
                    packageId: state.packageId,
                    fallbackURL: state.archiveURL,
                    fallbackArchiveSize: state.archiveSize
                ) else {
                    continue
                }

                let status = ModelAssetTransferStatus(
                    state: .pausedResumable,
                    downloadedBytes: state.downloadedBytes,
                    totalBytes: max(state.archiveSize, asset.archiveSize),
                    isResumable: state.downloadedBytes > 0
                )

                restoredRecords.append(.transient(asset: asset, status: status))
            }
        }

        await snapshotStore.mergeRestoredTransientRecords(restoredRecords)
    }

    private func reloadAvailableRecords() async {
        var records: [ModelAssetRecord] = []

        if let translationRecords = try? await translationAssetSource.availableRecords() {
            records.append(contentsOf: translationRecords)
        }

        if let speechRecords = try? await speechAssetSource.availableRecords() {
            records.append(contentsOf: speechRecords)
        }

        await snapshotStore.replaceAvailableRecords(records)
    }

    private func source(for kind: ModelAssetKind) -> any ModelAssetSource {
        switch kind {
        case .translation:
            return translationAssetSource
        case .speech:
            return speechAssetSource
        }
    }

    private func normalizedErrorMessage(from error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }
}
