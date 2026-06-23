import Foundation

/// A free-form label that can be attached to clips.
public struct Tag: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var name: String
    public var color: String?

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case name
        case color
    }

    public init(id: UUID, orgId: UUID, name: String, color: String?) {
        self.id = id
        self.orgId = orgId
        self.name = name
        self.color = color
    }
}
