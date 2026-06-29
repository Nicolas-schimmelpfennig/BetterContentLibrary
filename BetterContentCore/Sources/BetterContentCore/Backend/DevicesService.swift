import Foundation
import Supabase

/// Registers a device's APNs token so the backend can push "time to post"
/// notifications to it. Org-scoped by RLS; one row per token (upsert).
public final class DevicesService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Upserts the current device's push token, keyed on the token itself so a
    /// device that re-signs-in (or whose token rotates) updates in place.
    /// `environment` is "sandbox" for development builds, "production" otherwise.
    public func register(token: String, profileId: UUID, orgId: UUID, environment: String) async throws {
        let row = DeviceRow(
            org_id: orgId.uuidString,
            profile_id: profileId.uuidString,
            apns_token: token,
            environment: environment,
            updated_at: Date()
        )
        try await client
            .from("devices")
            .upsert(row, onConflict: "apns_token")
            .execute()
    }

    private struct DeviceRow: Encodable, Sendable {
        let org_id: String
        let profile_id: String
        let apns_token: String
        let environment: String
        let updated_at: Date
    }
}
