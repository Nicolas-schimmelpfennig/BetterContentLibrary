import Foundation

/// A single video and its metadata. The bytes live in whatever backend
/// `storageProvider` names, at `storageKey` (the DB column keeps its historic
/// `r2_key` name; for iCloud it holds a path relative to the app's ubiquity
/// container, for Google Drive it will hold the Drive file id).
public struct Clip: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var uploadedBy: UUID?
    public var title: String
    /// Provider-specific key of the video object (see `storageProvider`).
    public var storageKey: String?
    /// Which backend holds this clip's bytes.
    public var storageProvider: StorageProvider
    public var fileSize: Int64?
    public var durationS: Double?
    public var width: Int?
    public var height: Int?
    public var orientation: ClipOrientation?
    public var contentHash: String?
    /// The video's original creation/recording date, distinct from `createdAt`.
    public var capturedAt: Date?
    /// The folder this clip lives in; nil means the library root.
    public var folderId: UUID?
    /// Provider-specific key of the poster thumbnail, if one has been uploaded.
    public var thumbKey: String?
    public var status: ClipStatus
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case uploadedBy = "uploaded_by"
        case title
        case storageKey = "r2_key"
        case storageProvider = "storage_provider"
        case fileSize = "file_size"
        case durationS = "duration_s"
        case width
        case height
        case orientation
        case contentHash = "content_hash"
        case capturedAt = "captured_at"
        case folderId = "folder_id"
        case thumbKey = "thumb_key"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        orgId = try container.decode(UUID.self, forKey: .orgId)
        uploadedBy = try container.decodeIfPresent(UUID.self, forKey: .uploadedBy)
        title = try container.decode(String.self, forKey: .title)
        storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        // Tolerate rows/fixtures from before migration 0013: default to R2,
        // which is where every clip lived until then.
        storageProvider = try container.decodeIfPresent(StorageProvider.self, forKey: .storageProvider) ?? .r2
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        durationS = try container.decodeIfPresent(Double.self, forKey: .durationS)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        orientation = try container.decodeIfPresent(ClipOrientation.self, forKey: .orientation)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        folderId = try container.decodeIfPresent(UUID.self, forKey: .folderId)
        thumbKey = try container.decodeIfPresent(String.self, forKey: .thumbKey)
        status = try container.decode(ClipStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public init(
        id: UUID,
        orgId: UUID,
        uploadedBy: UUID?,
        title: String,
        storageKey: String?,
        storageProvider: StorageProvider = .r2,
        fileSize: Int64?,
        durationS: Double?,
        width: Int?,
        height: Int?,
        orientation: ClipOrientation?,
        contentHash: String?,
        capturedAt: Date? = nil,
        folderId: UUID? = nil,
        thumbKey: String? = nil,
        status: ClipStatus,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.orgId = orgId
        self.uploadedBy = uploadedBy
        self.title = title
        self.storageKey = storageKey
        self.storageProvider = storageProvider
        self.fileSize = fileSize
        self.durationS = durationS
        self.width = width
        self.height = height
        self.orientation = orientation
        self.contentHash = contentHash
        self.capturedAt = capturedAt
        self.folderId = folderId
        self.thumbKey = thumbKey
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
