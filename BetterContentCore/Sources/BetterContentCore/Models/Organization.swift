import Foundation

/// A tenant. Every other record belongs to exactly one organization.
public struct Organization: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    /// Standing invite code — anyone signed in can join with it, so treat it
    /// like a Wi-Fi password. Admins regenerate it via `OrgService`.
    public var inviteCode: String
    /// Shared cap for BetterContent Cloud (R2) storage, in decimal GB.
    /// Admin-edited; enforced on every member's uploads.
    public var storageLimitGB: Int
    /// Comma-joined `EvictionCategory` raw values — the org-wide policy for
    /// which clips auto-removal may take, in priority order.
    public var evictionOrderRaw: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case storageLimitGB = "storage_limit_gb"
        case evictionOrderRaw = "eviction_order"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        name: String,
        inviteCode: String = "",
        storageLimitGB: Int = 5,
        evictionOrderRaw: String = "",
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.storageLimitGB = storageLimitGB
        self.evictionOrderRaw = evictionOrderRaw
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Tolerate rows/fixtures from before migration 0014. The eviction
        // default mirrors the DB column default — an empty string is a real
        // value meaning "auto-removal disabled", so it can't be the fallback.
        inviteCode = try container.decodeIfPresent(String.self, forKey: .inviteCode) ?? ""
        storageLimitGB = try container.decodeIfPresent(Int.self, forKey: .storageLimitGB) ?? 5
        evictionOrderRaw = try container.decodeIfPresent(String.self, forKey: .evictionOrderRaw)
            ?? EvictionCategory.serialize(EvictionCategory.defaultOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
