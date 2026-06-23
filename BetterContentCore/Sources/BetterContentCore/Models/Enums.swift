import Foundation

/// A member's role within an organization. Mirrors the `user_role` Postgres enum.
public enum UserRole: String, Codable, Sendable, CaseIterable {
    case owner
    case editor
    case manager
    case viewer
}

/// The lifecycle state of a clip. Mirrors the `clip_status` Postgres enum.
public enum ClipStatus: String, Codable, Sendable, CaseIterable {
    case ingesting
    case uploading
    case ready
    case scheduled
    case downloaded
    case posted
}

/// Video aspect orientation, auto-detected on ingest. Mirrors `clip_orientation`.
public enum ClipOrientation: String, Codable, Sendable, CaseIterable {
    case vertical
    case horizontal
    case square
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
