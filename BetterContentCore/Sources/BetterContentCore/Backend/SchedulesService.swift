import Foundation
import Supabase

/// Reads and writes the `schedules` table (a clip slotted to a platform at a
/// time). Org-scoped by RLS.
public final class SchedulesService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Schedules whose `scheduled_at` falls in `[from, to)`, earliest first.
    public func list(from: Date, to: Date) async throws -> [Schedule] {
        try await client
            .from("schedules")
            .select()
            .gte("scheduled_at", value: from.ISO8601Format())
            .lt("scheduled_at", value: to.ISO8601Format())
            .order("scheduled_at", ascending: true)
            .execute()
            .value
    }

    @discardableResult
    public func create(
        clipId: UUID,
        orgId: UUID,
        platform: Platform,
        scheduledAt: Date,
        timezone: String = TimeZone.current.identifier,
        caption: String? = nil,
        notes: String? = nil,
        notifyProfileId: UUID? = nil
    ) async throws -> Schedule {
        let row = InsertSchedule(
            org_id: orgId.uuidString,
            clip_id: clipId.uuidString,
            platform: platform.rawValue,
            scheduled_at: scheduledAt,
            timezone: timezone,
            caption: caption,
            notes: notes,
            notify_profile_id: notifyProfileId?.uuidString
        )
        return try await client
            .from("schedules")
            .insert(row, returning: .representation)
            .select()
            .single()
            .execute()
            .value
    }

    /// All of the org's schedules (RLS-scoped), for deriving per-clip display
    /// status in the library. Soonest first, capped generously.
    public func listAll(limit: Int = 1000) async throws -> [Schedule] {
        try await client
            .from("schedules")
            .select()
            .order("scheduled_at", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    /// Rewrites every user-editable field of a schedule (the editor's save).
    /// Optionals encode as explicit nulls so clearing a field persists.
    public func update(
        _ id: UUID,
        clipId: UUID,
        platform: Platform,
        scheduledAt: Date,
        caption: String?,
        notes: String?,
        notifyProfileId: UUID?
    ) async throws {
        let patch = EditPatch(
            clip_id: clipId.uuidString,
            platform: platform.rawValue,
            scheduled_at: scheduledAt,
            caption: caption,
            notes: notes,
            notify_profile_id: notifyProfileId?.uuidString
        )
        try await client
            .from("schedules")
            .update(patch)
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Marks a schedule posted, recording when.
    public func markPosted(_ id: UUID, at date: Date = Date()) async throws {
        try await client
            .from("schedules")
            .update(PostedPatch(status: ScheduleStatus.posted.rawValue, posted_at: date))
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Moves a schedule to a new time.
    public func reschedule(_ id: UUID, to date: Date) async throws {
        try await client
            .from("schedules")
            .update(TimePatch(scheduled_at: date))
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func setStatus(_ id: UUID, _ status: ScheduleStatus) async throws {
        try await client
            .from("schedules")
            .update(StatusPatch(status: status.rawValue))
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func delete(_ id: UUID) async throws {
        try await client
            .from("schedules")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    private struct InsertSchedule: Encodable, Sendable {
        let org_id: String
        let clip_id: String
        let platform: String
        let scheduled_at: Date
        let timezone: String
        let caption: String?
        let notes: String?
        let notify_profile_id: String?
    }

    private struct EditPatch: Encodable, Sendable {
        let clip_id: String
        let platform: String
        let scheduled_at: Date
        let caption: String?
        let notes: String?
        let notify_profile_id: String?

        enum CodingKeys: String, CodingKey {
            case clip_id, platform, scheduled_at, caption, notes, notify_profile_id
        }

        // Hand-rolled so nil optionals become JSON nulls; the synthesized
        // conformance omits them, which would leave stale values in place.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(clip_id, forKey: .clip_id)
            try container.encode(platform, forKey: .platform)
            try container.encode(scheduled_at, forKey: .scheduled_at)
            try container.encode(caption, forKey: .caption)
            try container.encode(notes, forKey: .notes)
            try container.encode(notify_profile_id, forKey: .notify_profile_id)
        }
    }

    private struct PostedPatch: Encodable, Sendable {
        let status: String
        let posted_at: Date
    }

    private struct TimePatch: Encodable, Sendable {
        let scheduled_at: Date
    }

    private struct StatusPatch: Encodable, Sendable {
        let status: String
    }
}
