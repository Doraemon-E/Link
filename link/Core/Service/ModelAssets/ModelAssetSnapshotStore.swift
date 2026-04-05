//
//  ModelAssetSnapshotStore.swift
//  link
//
//  Created by Codex on 2026/4/5.
//

import Foundation

actor ModelAssetSnapshotStore {
    private enum RunningTaskState {
        case reserved
        case active(Task<Void, Never>)
    }

    private var transientRecordsByID: [String: ModelAssetRecord] = [:]
    private var installedRecordsByID: [String: ModelAssetRecord] = [:]
    private var availableRecordsByID: [String: ModelAssetRecord] = [:]
    private var runningTasksByID: [String: RunningTaskState] = [:]
    private var continuations: [UUID: AsyncStream<ModelAssetSnapshot>.Continuation] = [:]

    func snapshotStream() -> AsyncStream<ModelAssetSnapshot> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(token)
                }
            }
        }
    }

    func currentSnapshot() -> ModelAssetSnapshot {
        makeSnapshot()
    }

    func transientRecord(id: String) -> ModelAssetRecord? {
        transientRecordsByID[id]
    }

    func installedRecord(id: String) -> ModelAssetRecord? {
        installedRecordsByID[id]
    }

    func isRunning(id: String) -> Bool {
        runningTasksByID[id] != nil
    }

    func reserveRun(for asset: ModelAsset) -> Bool {
        guard runningTasksByID[asset.id] == nil else {
            return false
        }

        runningTasksByID[asset.id] = .reserved
        transientRecordsByID[asset.id] = .transient(
            asset: asset,
            status: ModelAssetTransferStatus(
                state: .preparing,
                downloadedBytes: 0,
                totalBytes: asset.archiveSize
            )
        )
        installedRecordsByID.removeValue(forKey: asset.id)
        emitSnapshot()
        return true
    }

    func activateRun(_ task: Task<Void, Never>, for assetID: String) {
        runningTasksByID[assetID] = .active(task)
    }

    func clearRun(for assetID: String) {
        runningTasksByID.removeValue(forKey: assetID)
    }

    func updateTransientRecord(_ record: ModelAssetRecord) {
        transientRecordsByID[record.id] = record
        emitSnapshot()
    }

    func removeTransientRecord(id: String) {
        transientRecordsByID.removeValue(forKey: id)
        emitSnapshot()
    }

    func replaceInstalledRecords(_ records: [ModelAssetRecord]) {
        installedRecordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        emitSnapshot()
    }

    func mergeRestoredTransientRecords(_ records: [ModelAssetRecord]) {
        for record in records where installedRecordsByID[record.id] == nil && runningTasksByID[record.id] == nil {
            transientRecordsByID[record.id] = record
        }
        emitSnapshot()
    }

    func replaceAvailableRecords(_ records: [ModelAssetRecord]) {
        let hiddenIDs = Set(installedRecordsByID.keys).union(transientRecordsByID.keys)
        let visibleRecords = records.filter { !hiddenIDs.contains($0.id) }
        availableRecordsByID = Dictionary(uniqueKeysWithValues: visibleRecords.map { ($0.id, $0) })
        emitSnapshot()
    }

    private func removeContinuation(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func emitSnapshot() {
        let snapshot = makeSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func makeSnapshot() -> ModelAssetSnapshot {
        let installedRecordIDs = Set(installedRecordsByID.keys)
        let transientRecordIDs = Set(transientRecordsByID.keys)

        let transientRecords = transientRecordsByID.values.filter { !installedRecordIDs.contains($0.id) }
        let availableRecords = availableRecordsByID.values.filter {
            !installedRecordIDs.contains($0.id) && !transientRecordIDs.contains($0.id)
        }

        let records = (transientRecords + installedRecordsByID.values + availableRecords)
            .sorted(by: compareRecords)

        let summary = ModelAssetSummary(
            activeCount: records.filter {
                !$0.isInstalled && [.preparing, .downloading, .verifying, .installing].contains($0.status.state)
            }.count,
            resumableCount: records.filter {
                !$0.isInstalled && $0.status.state == .pausedResumable
            }.count,
            failedCount: records.filter {
                !$0.isInstalled && $0.status.state == .failed
            }.count,
            installedCount: records.filter(\.isInstalled).count,
            availableCount: records.filter {
                !$0.isInstalled && $0.status.state == .idle
            }.count
        )

        return ModelAssetSnapshot(records: records, summary: summary)
    }

    private func compareRecords(lhs: ModelAssetRecord, rhs: ModelAssetRecord) -> Bool {
        let stateOrder: [ModelAssetState: Int] = [
            .preparing: 0,
            .downloading: 1,
            .verifying: 2,
            .installing: 3,
            .pausedResumable: 4,
            .failed: 5,
            .idle: 6,
            .completed: 7
        ]

        let lhsOrder = stateOrder[lhs.status.state, default: 99]
        let rhsOrder = stateOrder[rhs.status.state, default: 99]
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        switch (lhs.installedAt, rhs.installedAt) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        default:
            return lhs.asset.title < rhs.asset.title
        }
    }
}
