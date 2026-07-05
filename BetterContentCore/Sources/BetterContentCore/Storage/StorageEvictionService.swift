//
//  StorageEvictionService.swift
//  BetterContentCore
//
//  Enforces per-provider storage limits at upload time: frees room by
//  deleting old clips per the user's priority chain, or refuses the upload
//  (deleting nothing) when the enabled categories can't free enough.
//

import Foundation

/// Thrown when the auto-removal chain can't free enough space — the upload
/// must not proceed, and nothing has been deleted.
public enum EvictionError: LocalizedError, Sendable {
    case wouldExceedLimit(provider: StorageProvider, limitGB: Int, shortfall: Int64)

    public var errorDescription: String? {
        switch self {
        case let .wouldExceedLimit(provider, limitGB, shortfall):
            let amount = ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)
            return "This upload doesn't fit the \(limitGB) GB \(provider.displayName) limit — removing every eligible clip would still leave it \(amount) over. Raise the limit or allow more categories to be auto-removed in Settings → Storage, or delete clips manually."
        }
    }
}

public final class StorageEvictionService: Sendable {
    private let clips: ClipsService
    private let schedules: SchedulesService
    private let router: StorageRouter

    public init(
        clips: ClipsService = ClipsService(),
        schedules: SchedulesService = SchedulesService(),
        router: StorageRouter = StorageRouter()
    ) {
        self.clips = clips
        self.schedules = schedules
        self.router = router
    }

    /// Makes room for `incomingBytes` in the current provider's budget.
    ///
    /// Deletes evictable clips (oldest first within each enabled category, in
    /// chain order) until the upload fits, and returns what was removed. If
    /// even removing every eligible clip wouldn't fit the upload, throws
    /// `EvictionError` WITHOUT deleting anything.
    ///
    /// Scoping: R2 usage is org-wide (shared bucket); iCloud counts only the
    /// current user's clips — other members' bytes live in their own
    /// containers and can't be measured or removed from here.
    public func makeRoom(incomingBytes: Int64, uploadedBy userId: UUID) async throws -> [Clip] {
        let provider = router.currentProvider
        let limit = provider.limitBytes

        let all = try await clips.list(limit: 2000)
        let inProvider = all.filter {
            $0.storageProvider == provider && (provider == .r2 || $0.uploadedBy == userId)
        }

        // Usage counts everything that occupies (or is about to occupy) the
        // provider: finished clips and transfers still in flight.
        let usage = inProvider
            .filter { $0.status == .ready || $0.status == .uploading }
            .reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        guard usage + incomingBytes > limit else { return [] }

        // Bucket the candidates. Only settled clips with a known, nonzero
        // size are worth deleting; upcoming-scheduled clips are protected.
        let schedulesByClip = Dictionary(grouping: try await schedules.listAll(), by: \.clipId)
        let order = EvictionCategory.order(from: UserDefaults.standard.string(forKey: SettingsKey.evictionOrder))
        let now = Date()

        var buckets: [EvictionCategory: [Clip]] = [:]
        for clip in inProvider where clip.status == .ready && (clip.fileSize ?? 0) > 0 {
            if let category = EvictionCategory.category(for: clip, schedules: schedulesByClip[clip.id] ?? [], now: now) {
                buckets[category, default: []].append(clip)
            }
        }
        let queue = order.flatMap { (buckets[$0] ?? []).sorted { $0.createdAt < $1.createdAt } }

        // Plan first, delete only if the plan actually fits.
        let needed = usage + incomingBytes - limit
        var freed: Int64 = 0
        var plan: [Clip] = []
        for clip in queue where freed < needed {
            plan.append(clip)
            freed += clip.fileSize ?? 0
        }
        guard freed >= needed else {
            throw EvictionError.wouldExceedLimit(provider: provider, limitGB: provider.limitGB, shortfall: needed - freed)
        }

        for clip in plan {
            let backend = router.backend(for: clip)
            try await backend.deleteObjects(for: clip)
            if !backend.deletesRow {
                try await clips.delete(clip.id)
            }
        }
        return plan
    }
}
