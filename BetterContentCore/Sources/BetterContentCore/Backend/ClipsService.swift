import Foundation
import Supabase

/// Reads and writes the `clips` table. RLS scopes every query to the caller's
/// org, so this never has to filter by org for safety — only for convenience
/// (e.g. dedupe lookups).
public final class ClipsService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Inserts a new clip row at the start of the ingest lifecycle.
    public func create(
        title: String,
        orgId: UUID,
        uploadedBy: UUID?,
        folderId: UUID? = nil,
        status: ClipStatus = .ingesting
    ) async throws -> Clip {
        let row = InsertClip(
            org_id: orgId.uuidString,
            uploaded_by: uploadedBy?.uuidString,
            title: title,
            folder_id: folderId?.uuidString,
            status: status.rawValue
        )
        return try await client
            .from("clips")
            .insert(row, returning: .representation)
            .select()
            .single()
            .execute()
            .value
    }

    /// Writes the metadata extracted on ingest and the content hash.
    public func applyMetadata(
        id: UUID,
        durationS: Double,
        width: Int,
        height: Int,
        orientation: ClipOrientation,
        contentHash: String,
        fileSize: Int64?,
        capturedAt: Date?
    ) async throws {
        try await patch(id, MetadataPatch(
            duration_s: durationS,
            width: width,
            height: height,
            orientation: orientation.rawValue,
            content_hash: contentHash,
            file_size: fileSize,
            captured_at: capturedAt
        ))
    }

    /// Records the R2 key and moves the clip into the uploading state, right
    /// before the background upload starts.
    public func markUploading(id: UUID, r2Key: String) async throws {
        try await patch(id, UploadPatch(r2_key: r2Key, status: ClipStatus.uploading.rawValue))
    }

    /// Sets just the lifecycle status (e.g. `.ready` when an upload completes).
    public func setStatus(_ id: UUID, _ status: ClipStatus) async throws {
        try await patch(id, StatusPatch(status: status.rawValue))
    }

    /// Records the uploaded thumbnail's R2 key.
    public func setThumbKey(_ id: UUID, _ key: String) async throws {
        try await patch(id, ThumbPatch(thumb_key: key))
    }

    /// Moves a clip into a folder (nil = library root).
    public func setFolder(_ id: UUID, folderId: UUID?) async throws {
        try await patch(id, FolderPatch(folder_id: folderId?.uuidString))
    }

    /// Lists clips in a folder (nil = library root), newest first.
    public func list(inFolder folderId: UUID?, limit: Int = 500) async throws -> [Clip] {
        let base = client.from("clips").select()
        let filtered = folderId.map { base.eq("folder_id", value: $0.uuidString) }
            ?? base.is("folder_id", value: nil)
        return try await filtered
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Looks up an existing clip with the same content hash, for dedupe.
    public func findByHash(_ hash: String, orgId: UUID) async throws -> Clip? {
        let rows: [Clip] = try await client
            .from("clips")
            .select()
            .eq("content_hash", value: hash)
            .eq("org_id", value: orgId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Lists the org's clips, newest first.
    public func list(limit: Int = 200) async throws -> [Clip] {
        try await client
            .from("clips")
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: Private

    private func patch(_ id: UUID, _ body: some Encodable & Sendable) async throws {
        try await client
            .from("clips")
            .update(body)
            .eq("id", value: id.uuidString)
            .execute()
    }

    private struct InsertClip: Encodable, Sendable {
        let org_id: String
        let uploaded_by: String?
        let title: String
        let folder_id: String?
        let status: String
    }

    private struct MetadataPatch: Encodable, Sendable {
        let duration_s: Double
        let width: Int
        let height: Int
        let orientation: String
        let content_hash: String
        let file_size: Int64?
        let captured_at: Date?
    }

    private struct UploadPatch: Encodable, Sendable {
        let r2_key: String
        let status: String
    }

    private struct StatusPatch: Encodable, Sendable {
        let status: String
    }

    private struct ThumbPatch: Encodable, Sendable {
        let thumb_key: String
    }

    private struct FolderPatch: Encodable, Sendable {
        let folder_id: String?
    }
}
