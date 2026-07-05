import Foundation

/// A member's role within an organization. Mirrors the `user_role` Postgres enum.
public enum UserRole: String, Codable, Sendable, CaseIterable {
    case owner
    case editor
    case manager
    case viewer
}

/// The transfer state of a clip's bytes. Mirrors the `clip_status` Postgres enum.
///
/// Deliberately transfer-only: whether a clip is scheduled, downloaded, or
/// posted is derived from the `schedules`/`downloads` tables, since one clip
/// can have many schedules.
public enum ClipStatus: String, Codable, Sendable, CaseIterable {
    case ingesting
    case uploading
    case ready
    case failed
}

/// Video aspect orientation, auto-detected on ingest. Mirrors `clip_orientation`.
public enum ClipOrientation: String, Codable, Sendable, CaseIterable {
    case vertical
    case horizontal
    case square
}

/// Where a clip's video/thumbnail bytes live. Mirrors the text values allowed
/// by `clips.storage_provider`. Supabase stays the catalog either way — this
/// only decides who serves the bytes.
public enum StorageProvider: String, Codable, Sendable, CaseIterable {
    /// Cloudflare R2 via the `r2-sign` edge function — org-shared storage.
    case r2
    /// The uploader's iCloud Drive — personal storage, reachable only on
    /// devices signed into the same Apple ID.
    case iCloudDrive = "icloud"
    /// The uploader's Google Drive — personal storage (backend not built yet).
    case googleDrive = "gdrive"

    public var displayName: String {
        switch self {
        case .r2: return "BetterContent Cloud"
        case .iCloudDrive: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        }
    }
}

/// Target posting platform. Mirrors the `platform` Postgres enum.
public enum Platform: String, Codable, Sendable, CaseIterable {
    case instagram
    case tiktok
    case youtube
    case youtubeShorts = "youtube_shorts"
    case x
    case facebook
    case linkedin
    case other
}

/// The state of a single scheduled post. Mirrors the `schedule_status` Postgres enum.
public enum ScheduleStatus: String, Codable, Sendable, CaseIterable {
    case planned
    case posted
    case skipped
}
