import Foundation
import Observation
import Supabase

/// Observable authentication state, shared by the app's views.
///
/// Call `start()` once when the app launches to begin tracking the session.
/// The current `session` and `currentProfile` update automatically on sign in /
/// sign out.
@MainActor
@Observable
public final class AuthService {
    public private(set) var session: Session?
    public private(set) var currentProfile: Profile?
    public private(set) var isLoadingProfile = false

    public var isAuthenticated: Bool { session != nil }

    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Begins listening for auth state changes. Runs until the task is cancelled,
    /// so launch it from a long-lived `.task { }` at the app root.
    public func start() async {
        for await (_, session) in await client.auth.authStateChanges {
            self.session = session
            if let session {
                await loadProfile(userId: session.user.id)
            } else {
                currentProfile = nil
            }
        }
    }

    public func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    /// Signs up a new user. The `displayName` and `orgName` are passed as user
    /// metadata, which the `handle_new_user` trigger reads to create the
    /// organization and owner profile.
    public func signUp(
        email: String,
        password: String,
        displayName: String?,
        orgName: String?
    ) async throws {
        var metadata: [String: AnyJSON] = [:]
        if let displayName { metadata["display_name"] = .string(displayName) }
        if let orgName { metadata["org_name"] = .string(orgName) }
        try await client.auth.signUp(
            email: email,
            password: password,
            data: metadata.isEmpty ? nil : metadata
        )
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }

    /// Re-reads the profile row for the signed-in user. Call after anything
    /// that changes it outside the auth stream — joining or leaving an org,
    /// a role change — so views keyed on the profile pick up the new state.
    public func refreshProfile() async {
        guard let session else { return }
        await loadProfile(userId: session.user.id)
    }

    private func loadProfile(userId: UUID) async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        do {
            currentProfile = try await client
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
        } catch {
            currentProfile = nil
        }
    }
}
