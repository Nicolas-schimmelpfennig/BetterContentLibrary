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
        notes: String? = nil,
        notifyProfileId: UUID? = nil
    ) async throws -> Schedule {
        let row = InsertSchedule(
            org_id: orgId.uuidString,
            clip_id: clipId.uuidString,
            platform: platform.rawValue,
            scheduled_at: scheduledAt,
            timezone: timezone,
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
        let notes: String?
        let notify_profile_id: String?
    }

    private struct TimePatch: Encodable, Sendable {
        let scheduled_at: Date
    }

    private struct StatusPatch: Encodable, Sendable {
        let status: String
    }
}
