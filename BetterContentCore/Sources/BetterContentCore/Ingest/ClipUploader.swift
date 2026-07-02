import Foundation

/// An editable, pre-filled description of a video the user has chosen to add.
///
/// Built by `ClipUploader.makeDraft(from:)` with values read from the file, then
/// shown to the user for review/override before uploading.
public struct ClipDraft: Identifiable, Sendable {
    public let id = UUID()
    public var fileURL: URL
    public var title: String
    public var orientation: ClipOrientation
    public var capturedAt: Date?

    // Read-only intrinsics (shown for context, not edited).
    public let durationS: Double
    public let width: Int
    public let height: Int
    public let fileSize: Int64?
    public let contentHash: String
    public let thumbnailJPEG: Data?

    public init(
        fileURL: URL,
        title: String,
        orientation: ClipOrientation,
        capturedAt: Date?,
        durationS: Double,
        width: Int,
        height: Int,
        fileSize: Int64?,
        contentHash: String,
        thumbnailJPEG: Data?
    ) {
        self.fileURL = fileURL
        self.title = title
        self.orientation = orientation
        self.capturedAt = capturedAt
        self.durationS = durationS
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.thumbnailJPEG = thumbnailJPEG
    }
}

/// Thrown when a picked file can't enter the upload pipeline.
public enum UploadPipelineError: LocalizedError, Sendable {
    /// The same bytes (by content hash) already exist in the org's library.
    case duplicate(existingTitle: String)

    public var errorDescription: String? {
        switch self {
        case let .duplicate(existingTitle):
            return "This video is already in the library as “\(existingTitle)”."
        }
    }
}

/// Orchestrates adding a user-chosen video: read its metadata into an editable
/// draft, then (once confirmed) create the clip row and hand the bytes to the
/// background uploader.
///
/// Status reconciliation for finished/failed transfers is *not* wired here —
/// `UploadReconciler` owns that process-wide, so UI objects can come and go
/// without fighting over callbacks.
public final class ClipUploader: Sendable {
    private let clips: ClipsService
    private let storage: StorageService
    private let uploader: BackgroundUploadService
    private let store: PendingUploadStore

    public init(
        clips: ClipsService = ClipsService(),
        storage: StorageService = StorageService(),
        uploader: BackgroundUploadService = .shared,
        store: PendingUploadStore = .shared
    ) {
        self.clips = clips
        self.storage = storage
        self.uploader = uploader
        self.store = store
    }

    /// Live upload progress/finish/fail events, for UI.
    public func events() -> AsyncStream<UploadEvent> { uploader.events() }

    /// Reads a dropped/picked file into an editable draft. Hashing and metadata
    /// extraction happen off the calling actor.
    public func makeDraft(from fileURL: URL) async throws -> ClipDraft {
        let hash = try await Task.detached { try ContentHasher.sha256(of: fileURL) }.value
        let metadata = try await VideoIngest.metadata(of: fileURL)
        let captured = await VideoIngest.capturedDate(of: fileURL) ?? fileCreationDate(fileURL)
        let thumbnail = try? await VideoIngest.thumbnailJPEG(of: fileURL, duration: metadata.durationS)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        return ClipDraft(
            fileURL: fileURL,
            title: fileURL.deletingPathExtension().lastPathComponent,
            orientation: metadata.orientation,
            capturedAt: captured,
            durationS: metadata.durationS,
            width: metadata.width,
            height: metadata.height,
            fileSize: fileSize ?? nil,
            contentHash: hash,
            thumbnailJPEG: thumbnail
        )
    }

    /// Creates the clip row from a (possibly user-edited) draft and starts the
    /// background upload. Returns the created clip.
    @discardableResult
    public func upload(
        _ draft: ClipDraft,
        orgId: UUID,
        uploadedBy: UUID?,
        folderId: UUID? = nil
    ) async throws -> Clip {
        // Dedupe up front: the DB's unique (org, content_hash) index would
        // reject the metadata write anyway; checking first gives a clear error
        // and no orphan row. A failed earlier attempt at the same file is dead
        // weight — clear it (objects + row, server-side) and upload fresh.
        if let existing = try await clips.findByHash(draft.contentHash, orgId: orgId) {
            if existing.status == .failed {
                try await storage.deleteClip(clipId: existing.id)
            } else {
                throw UploadPipelineError.duplicate(existingTitle: existing.title)
            }
        }

        let clip = try await clips.create(
            title: draft.title,
            orgId: orgId,
            uploadedBy: uploadedBy,
            folderId: folderId
        )

        do {
            try await clips.applyMetadata(
                id: clip.id,
                durationS: draft.durationS,
                width: draft.width,
                height: draft.height,
                orientation: draft.orientation,
                contentHash: draft.contentHash,
                fileSize: draft.fileSize,
                capturedAt: draft.capturedAt
            )

            // Persist the poster thumbnail (best-effort; don't fail the upload over it).
            if let thumbnail = draft.thumbnailJPEG,
               let key = try? await storage.uploadThumbnail(thumbnail, clipId: clip.id) {
                try? await clips.setThumbKey(clip.id, key)
            }

            let ext = draft.fileURL.pathExtension.isEmpty ? "mp4" : draft.fileURL.pathExtension.lowercased()
            let contentType = Self.contentType(forExtension: ext)
            let ticket = try await storage.requestUploadTicket(ext: ext, contentType: contentType)

            try await clips.markUploading(id: clip.id, r2Key: ticket.key)
            store.track(clipId: clip.id, fileURL: draft.fileURL)
            uploader.enqueue(
                fileURL: draft.fileURL,
                to: ticket.uploadUrl,
                key: ticket.key,
                clipId: clip.id,
                contentType: contentType
            )
        } catch {
            // Don't leave a half-created row behind; the draft file is intact,
            // so the user can simply try again.
            try? await clips.delete(clip.id)
            throw error
        }
        return clip
    }

    private func fileCreationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
