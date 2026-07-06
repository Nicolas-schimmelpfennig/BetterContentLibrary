//
//  MigrationModel.swift
//  BetterContentCore
//
//  Observable state for the storage-migration progress sheet, shared by both
//  platforms. Owns the migration task; cancellation takes effect between
//  clips, so no clip is ever left half-moved.
//

import Foundation
import Observation

/// One clip that couldn't be migrated, for the failure list in the sheet.
public struct MigrationFailure: Identifiable, Sendable {
    public let id = UUID()
    public let clipTitle: String
    public let message: String
}

@MainActor
@Observable
public final class MigrationModel {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case finished
    }

    public private(set) var state: State = .idle
    public private(set) var target: StorageProvider = .r2
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var currentTitle: String?
    public private(set) var failures: [MigrationFailure] = []

    public var progress: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    /// Called after a run finishes (however it ended) so the owner can reload
    /// the library and refresh caches.
    public var onFinished: (@MainActor () -> Void)?

    private let service: StorageMigrationService
    private var task: Task<Void, Never>?

    public init(service: StorageMigrationService = StorageMigrationService()) {
        self.service = service
    }

    /// Kicks off a migration of every pending clip to `target`. No-op while a
    /// run is already in flight. Re-running after a cancel/crash picks up
    /// exactly where things stopped — the plan is recomputed from row state.
    public func start(to target: StorageProvider) {
        guard state != .running else { return }
        self.target = target
        state = .running
        total = 0
        completed = 0
        failures = []
        currentTitle = nil

        task = Task {
            do {
                let pending = try await service.pendingClips(to: target)
                total = pending.count
                for clip in pending {
                    if Task.isCancelled { break }
                    currentTitle = clip.title
                    do {
                        try await service.migrate(clip, to: target)
                    } catch {
                        failures.append(MigrationFailure(clipTitle: clip.title, message: error.localizedDescription))
                    }
                    completed += 1
                }
            } catch {
                failures.append(MigrationFailure(clipTitle: "Couldn't list clips", message: error.localizedDescription))
            }
            currentTitle = nil
            state = .finished
            onFinished?()
        }
    }

    /// Stops after the clip currently in flight. Already-moved clips stay
    /// moved; the rest remain on their old provider.
    public func cancel() {
        task?.cancel()
    }

    /// Back to a clean slate so the sheet can run again.
    public func reset() {
        guard state != .running else { return }
        state = .idle
        total = 0
        completed = 0
        failures = []
        currentTitle = nil
    }
}
