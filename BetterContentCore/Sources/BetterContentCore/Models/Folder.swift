import Foundation

/// A library folder. Nestable via `parentId` (nil = top level), org-scoped.
public struct Folder: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var parentId: UUID?
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case parentId = "parent_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        orgId: UUID,
        parentId: UUID?,
        name: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.orgId = orgId
        self.parentId = parentId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
