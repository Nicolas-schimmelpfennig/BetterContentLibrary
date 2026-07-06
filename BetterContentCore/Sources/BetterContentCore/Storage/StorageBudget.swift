//
//  StorageBudget.swift
//  BetterContentCore
//
//  Per-provider storage limits and the user-arrangeable auto-removal chain.
//  When an upload would push a provider past its limit, old clips are removed
//  category by category (Settings → Storage controls the order and which
//  categories are eligible); if the enabled categories can't free enough,
//  the upload is refused instead — nothing is deleted for a doomed upload.
//

import Foundation

public extension SettingsKey {
    /// DEPRECATED (migration 0014): the R2 limit is org-level policy now —
    /// `organizations.storage_limit_gb`, admin-edited, shared by all members.
    /// This device-local key is no longer read for enforcement.
    static let storageLimitGBR2 = "storageLimitGB.r2"
    /// Per-device iCloud limit in whole GB (decimal, like storage plans).
    /// iCloud stays device-local: the bytes live in the user's own container.
    static let storageLimitGBICloud = "storageLimitGB.icloud"
    static let storageLimitGBGoogleDrive = "storageLimitGB.gdrive"

    /// DEPRECATED (migration 0014): the eviction chain is org-level policy
    /// now — `organizations.eviction_order` (the chain decides what gets
    /// deleted from the shared bucket, so it can't differ per device). This
    /// device-local key is no longer read for enforcement.
    static let evictionOrder = "evictionOrder"
}

public extension StorageProvider {
    static let defaultLimitGB = 5

    var limitSettingsKey: String {
        switch self {
        case .r2: return SettingsKey.storageLimitGBR2
        case .iCloudDrive: return SettingsKey.storageLimitGBICloud
        case .googleDrive: return SettingsKey.storageLimitGBGoogleDrive
        }
    }

    /// The configured limit in whole GB (≥ 1; defaults to 5).
    var limitGB: Int {
        let stored = UserDefaults.standard.object(forKey: limitSettingsKey) as? Int
        return max(1, stored ?? Self.defaultLimitGB)
    }

    /// The limit in bytes (decimal GB, matching how storage plans and
    /// `ByteCountFormatter` count).
    var limitBytes: Int64 {
        Int64(limitGB) * 1_000_000_000
    }
}

public extension Organization {
    /// The org's shared R2 cap in bytes (decimal GB, matching storage plans).
    var storageLimitBytes: Int64 {
        Int64(max(1, storageLimitGB)) * 1_000_000_000
    }

    /// The org's eviction chain, parsed. Empty = auto-removal disabled.
    var evictionOrder: [EvictionCategory] {
        EvictionCategory.order(from: evictionOrderRaw)
    }
}

/// Buckets a clip can fall into for auto-removal, in user-arrangeable
/// priority order. Clips with an *upcoming* scheduled post are never
/// auto-removed, regardless of this chain.
public enum EvictionCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Has been posted somewhere (and nothing upcoming).
    case posted
    /// Was scheduled, but every date is in the past (overdue or skipped).
    case pastScheduled
    /// Never scheduled at all.
    case unscheduled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .posted: return "Posted clips"
        case .pastScheduled: return "Past schedule date"
        case .unscheduled: return "Never scheduled"
        }
    }

    public var detail: String {
        switch self {
        case .posted: return "Already published somewhere"
        case .pastScheduled: return "Scheduled dates all in the past, not marked posted"
        case .unscheduled: return "No schedule ever created"
        }
    }

    /// The default chain: posted first, then overdue, then never-scheduled —
    /// oldest first within each.
    public static let defaultOrder: [EvictionCategory] = [.posted, .pastScheduled, .unscheduled]

    /// Parses the Settings value. `nil` (never set) means the default chain;
    /// an empty string means the user disabled every category.
    public static func order(from raw: String?) -> [EvictionCategory] {
        guard let raw else { return defaultOrder }
        return raw.split(separator: ",").compactMap { EvictionCategory(rawValue: String($0)) }
    }

    public static func serialize(_ order: [EvictionCategory]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// Which bucket a clip falls into — or nil when it's protected (an
    /// upcoming planned post) and must never be auto-removed.
    public static func category(for clip: Clip, schedules: [Schedule], now: Date = Date()) -> EvictionCategory? {
        if schedules.contains(where: { $0.status == .planned && $0.scheduledAt > now }) { return nil }
        if schedules.contains(where: { $0.status == .posted }) { return .posted }
        if !schedules.isEmpty { return .pastScheduled }
        return .unscheduled
    }
}
