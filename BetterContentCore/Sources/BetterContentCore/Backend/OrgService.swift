import Foundation
import Supabase

/// What a prospective member sees before committing to a join: enough to
/// confirm "yes, that's the org I meant" and nothing more.
public struct OrgPreview: Decodable, Sendable {
    public let orgId: UUID
    public let orgName: String
    public let memberCount: Int

    enum CodingKeys: String, CodingKey {
        case orgId = "org_id"
        case orgName = "org_name"
        case memberCount = "member_count"
    }
}

/// The outcome of `join_org`: where the caller landed and what happened to
/// their library if they brought it along.
public struct JoinResult: Decodable, Sendable {
    public let orgId: UUID
    /// Clips whose rows moved into the new org.
    public let movedClips: Int
    /// Clips the new org already had (same content hash) — they stay parked
    /// in the caller's old org rather than being destroyed.
    public let skippedDuplicates: Int

    enum CodingKeys: String, CodingKey {
        case orgId = "org_id"
        case movedClips = "moved_clips"
        case skippedDuplicates = "skipped_duplicates"
    }
}

/// Errors raised by the membership RPCs. The database throws stable snake_case
/// strings; this maps them to friendly, user-facing messages.
public enum OrgError: LocalizedError, Sendable, Equatable {
    case invalidCode
    case alreadyMember
    case iCloudClipsPresent
    case targetOrgNotR2
    case lastAdmin
    case soleMember
    case notAdmin
    case notMember
    case multiUserRequiresR2

    public var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "That invite code doesn't match any organization. Check for typos — codes never contain 0, 1, I, L, O, or U."
        case .alreadyMember:
            return "You're already a member of this organization."
        case .iCloudClipsPresent:
            return "Some of your clips are stored in iCloud Drive. Convert them to BetterContent Cloud first so your new teammates can play them."
        case .targetOrgNotR2:
            return "That organization still has clips in iCloud Drive. Its admin needs to convert them to BetterContent Cloud before anyone can join."
        case .lastAdmin:
            return "You're the only admin. Make someone else an admin first."
        case .soleMember:
            return "You're the only member of this organization — there's nothing to leave."
        case .notAdmin:
            return "Only an admin can do that."
        case .notMember:
            return "That person isn't a member of your organization."
        case .multiUserRequiresR2:
            return "Organizations with more than one member store clips in BetterContent Cloud."
        }
    }

    /// Pulls a known error token out of a PostgREST failure, or nil if the
    /// error is something else (network, decoding, …).
    static func match(_ error: any Error) -> OrgError? {
        let text = String(describing: error)
        let mapping: [(String, OrgError)] = [
            ("invalid_code", .invalidCode),
            ("already_member", .alreadyMember),
            ("icloud_clips_present", .iCloudClipsPresent),
            ("target_org_not_r2", .targetOrgNotR2),
            ("last_admin", .lastAdmin),
            ("sole_member", .soleMember),
            ("not_admin", .notAdmin),
            ("not_member", .notMember),
            ("multi_user_org_requires_r2", .multiUserRequiresR2),
        ]
        return mapping.first { text.contains($0.0) }?.1
    }
}

/// Reads and manages the caller's organization: settings, the standing invite
/// code, and membership. Every mutation is authorized server-side (RLS +
/// admin checks in the RPCs), so this class stays a thin, honest wrapper.
public final class OrgService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// The caller's own organization row (RLS returns exactly one).
    public func fetchCurrent() async throws -> Organization {
        try await client
            .from("organizations")
            .select()
            .single()
            .execute()
            .value
    }

    /// Renames the org. Admin-only (enforced by RLS).
    public func rename(_ name: String, orgId: UUID) async throws {
        try await update(NamePatch(name: name), orgId: orgId)
    }

    /// Sets the shared BetterContent Cloud storage cap. Admin-only.
    public func setStorageLimitGB(_ gb: Int, orgId: UUID) async throws {
        try await update(LimitPatch(storage_limit_gb: gb), orgId: orgId)
    }

    /// Sets the org-wide eviction priority chain. Admin-only.
    public func setEvictionOrder(_ order: [EvictionCategory], orgId: UUID) async throws {
        try await update(EvictionPatch(eviction_order: EvictionCategory.serialize(order)), orgId: orgId)
    }

    /// Replaces the invite code, invalidating the old one everywhere. Admin-only.
    public func regenerateInvite() async throws -> String {
        try await mapped {
            try await self.client.rpc("regenerate_invite").execute().value
        }
    }

    /// Resolves an invite code to a preview, or nil when the code is unknown.
    public func preview(code: String) async throws -> OrgPreview? {
        let rows: [OrgPreview] = try await client
            .rpc("org_preview", params: PreviewParams(code: code))
            .execute()
            .value
        return rows.first
    }

    /// Joins the org behind `code`. With `bringLibrary`, the caller's clips,
    /// folders, and schedules move along (duplicates stay parked in the old
    /// org); without it, the old library is left behind untouched.
    public func join(code: String, bringLibrary: Bool) async throws -> JoinResult {
        try await mapped {
            try await self.client
                .rpc("join_org", params: JoinParams(code: code, bring_library: bringLibrary))
                .execute()
                .value
        }
    }

    /// Promotes to Admin or demotes to Member. Admin-only.
    public func setMemberRole(_ memberId: UUID, admin: Bool) async throws {
        try await mapped {
            try await self.client
                .rpc("set_member_role", params: RoleParams(
                    member: memberId.uuidString,
                    new_role: (admin ? UserRole.owner : .editor).rawValue
                ))
                .execute()
        }
    }

    /// Removes a member, parking them in a fresh personal org. Their uploaded
    /// clips stay with the team. Admin-only.
    public func removeMember(_ memberId: UUID) async throws {
        try await mapped {
            try await self.client
                .rpc("remove_member", params: MemberParams(member: memberId.uuidString))
                .execute()
        }
    }

    /// Leaves the org into a fresh personal one. Refused for the sole member
    /// (nothing to leave) and for the last admin while others remain.
    public func leave() async throws {
        try await mapped {
            try await self.client.rpc("leave_org").execute()
        }
    }

    // MARK: Private

    /// Runs an RPC and rewrites known database error tokens into `OrgError`.
    @discardableResult
    private func mapped<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw OrgError.match(error) ?? error
        }
    }

    private func update(_ body: some Encodable & Sendable, orgId: UUID) async throws {
        do {
            try await client
                .from("organizations")
                .update(body)
                .eq("id", value: orgId.uuidString)
                .execute()
        } catch {
            throw OrgError.match(error) ?? error
        }
    }

    private struct NamePatch: Encodable, Sendable { let name: String }
    private struct LimitPatch: Encodable, Sendable { let storage_limit_gb: Int }
    private struct EvictionPatch: Encodable, Sendable { let eviction_order: String }
    private struct PreviewParams: Encodable, Sendable { let code: String }
    private struct JoinParams: Encodable, Sendable { let code: String; let bring_library: Bool }
    private struct RoleParams: Encodable, Sendable { let member: String; let new_role: String }
    private struct MemberParams: Encodable, Sendable { let member: String }
}
