import Foundation
import Supabase

/// Reads the `profiles` table. RLS scopes `SELECT` to the caller's org, so a
/// plain select returns exactly the org's members — handy for showing who
/// uploaded a clip.
public final class ProfilesService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// All profiles in the caller's organization.
    public func listForCurrentOrg() async throws -> [Profile] {
        try await client
            .from("profiles")
            .select()
            .execute()
            .value
    }
}
