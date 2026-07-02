import Foundation

/// A clip slotted to a platform at a time. One clip can have many schedules.
public struct Schedule: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var clipId: UUID
    public var platform: Platform
    public var scheduledAt: Date
    public var timezone: String
    public var status: ScheduleStatus
    public var postedAt: Date?
    /// The post text itself — written at scheduling time, copied at post time.
    public var caption: String?
    /// Internal reminders; never pasted into a post (unlike `caption`).
    public var notes: String?
    public var notifiedAt: Date?
    /// The org member to push a "time to post" notification to (nil = no one).
    public var notifyProfileId: UUID?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case clipId = "clip_id"
        case platform
        case scheduledAt = "scheduled_at"
        case timezone
        case status
        case postedAt = "posted_at"
        case caption
        case notes
        case notifiedAt = "notified_at"
        case notifyProfileId = "notify_profile_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        orgId: UUID,
        clipId: UUID,
        platform: Platform,
        scheduledAt: Date,
        timezone: String,
        status: ScheduleStatus,
        postedAt: Date?,
        caption: String? = nil,
        notes: String?,
        notifiedAt: Date?,
        notifyProfileId: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.orgId = orgId
        self.clipId = clipId
        self.platform = platform
        self.scheduledAt = scheduledAt
        self.timezone = timezone
        self.status = status
        self.postedAt = postedAt
        self.caption = caption
        self.notes = notes
        self.notifiedAt = notifiedAt
        self.notifyProfileId = notifyProfileId
        self.createdAt = createdAt
    }
}
