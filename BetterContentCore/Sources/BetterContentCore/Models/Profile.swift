import Foundation

/// A user's profile within their organization. `id` matches the Supabase auth user id.
public struct Profile: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var displayName: String?
    public var role: UserRole
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case displayName = "display_name"
        case role
        case createdAt = "created_at"
    }

    public init(id: UUID, orgId: UUID, displayName: String?, role: UserRole, createdAt: Date) {
        self.id = id
        self.orgId = orgId
        self.displayName = displayName
        self.role = role
        self.createdAt = createdAt
    }
}
