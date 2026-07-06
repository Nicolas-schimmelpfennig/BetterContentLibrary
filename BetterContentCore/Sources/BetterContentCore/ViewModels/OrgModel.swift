//
//  OrgModel.swift
//  BetterContentCore
//
//  Observable state for the Org settings page (macOS tab / iOS screen): the
//  organization row, the member list, and the admin actions. All mutations
//  are authorized server-side; this model just keeps the UI honest about
//  what the current user is allowed to touch.
//

import Foundation
import Observation

@MainActor
@Observable
public final class OrgModel {
    public private(set) var organization: Organization?
    /// Org members, oldest first (the founder leads the list).
    public private(set) var members: [Profile] = []
    /// Ready clips in the library not stored in R2 — they block sharing the
    /// invite code and joining-with-library until converted.
    public private(set) var nonR2Count = 0
    public private(set) var isLoading = false
    public var errorMessage: String?

    public let currentProfileId: UUID
    /// The caller's own role, refreshed with every `load()`.
    public private(set) var currentRole: UserRole

    public var isAdmin: Bool { currentRole.isAdmin }
    public var isMultiUser: Bool { members.count > 1 }
    /// True when the caller is the only admin of a multi-member org — they
    /// can't leave or demote themselves until someone else is promoted.
    public var isLastAdmin: Bool {
        isAdmin && members.filter { $0.role.isAdmin }.count <= 1
    }

    private let orgs: OrgService
    private let profiles: ProfilesService
    private let clips: ClipsService

    public init(
        profile: Profile,
        orgs: OrgService = OrgService(),
        profiles: ProfilesService = ProfilesService(),
        clips: ClipsService = ClipsService()
    ) {
        self.currentProfileId = profile.id
        self.currentRole = profile.role
        self.orgs = orgs
        self.profiles = profiles
        self.clips = clips
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            organization = try await orgs.fetchCurrent()
            members = try await profiles.listForCurrentOrg()
                .sorted { $0.createdAt < $1.createdAt }
            if let me = members.first(where: { $0.id == currentProfileId }) {
                currentRole = me.role
            }
            nonR2Count = try await clips.list(limit: 2000)
                .filter { $0.storageProvider != .r2 && $0.status == .ready }
                .count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Admin actions (server enforces the role; failures land in errorMessage)

    public func rename(_ name: String) async {
        guard let org = organization, !name.isEmpty, name != org.name else { return }
        await run { try await self.orgs.rename(name, orgId: org.id) }
    }

    public func setStorageLimitGB(_ gb: Int) async {
        guard let org = organization, gb != org.storageLimitGB else { return }
        await run { try await self.orgs.setStorageLimitGB(gb, orgId: org.id) }
    }

    public func setEvictionOrder(_ order: [EvictionCategory]) async {
        guard let org = organization else { return }
        await run { try await self.orgs.setEvictionOrder(order, orgId: org.id) }
    }

    public func regenerateInvite() async {
        await run { _ = try await self.orgs.regenerateInvite() }
    }

    public func setRole(_ memberId: UUID, admin: Bool) async {
        await run { try await self.orgs.setMemberRole(memberId, admin: admin) }
    }

    public func removeMember(_ memberId: UUID) async {
        await run { try await self.orgs.removeMember(memberId) }
    }

    // MARK: Membership changes (throwing: the caller must refresh the profile
    // and rebuild the session on success, so errors stay in its hands too)

    public func preview(code: String) async throws -> OrgPreview? {
        try await orgs.preview(code: code)
    }

    public func join(code: String, bringLibrary: Bool) async throws -> JoinResult {
        try await orgs.join(code: code, bringLibrary: bringLibrary)
    }

    public func leave() async throws {
        try await orgs.leave()
    }

    // MARK: Private

    private func run(_ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
