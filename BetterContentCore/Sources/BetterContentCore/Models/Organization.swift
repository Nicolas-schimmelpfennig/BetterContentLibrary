import Foundation

/// A tenant. Every other record belongs to exactly one organization.
public struct Organization: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    public init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
