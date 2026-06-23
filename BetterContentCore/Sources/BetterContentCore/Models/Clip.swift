import Foundation

/// A single video and its metadata. The file itself lives in Cloudflare R2 under `r2Key`.
public struct Clip: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var orgId: UUID
    public var uploadedBy: UUID?
    public var title: String
    public var r2Key: String?
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
    /// R2 key of the poster thumbnail, if one has been uploaded.
    public var thumbKey: String?
    public var status: ClipStatus
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case uploadedBy = "uploaded_by"
        case title
        case r2Key = "r2_key"
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

    public init(
        id: UUID,
        orgId: UUID,
        uploadedBy: UUID?,
        title: String,
        r2Key: String?,
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
        self.r2Key = r2Key
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
