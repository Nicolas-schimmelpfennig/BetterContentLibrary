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
    private let router: StorageRouter
    private let uploader: BackgroundUploadService
    private let store: PendingUploadStore
    private let reconciler: UploadReconciler

    public init(
        clips: ClipsService = ClipsService(),
        router: StorageRouter = StorageRouter(),
        uploader: BackgroundUploadService = .shared,
        store: PendingUploadStore = .shared,
        reconciler: UploadReconciler = .shared
    ) {
        self.clips = clips
        self.router = router
        self.uploader = uploader
        self.store = store
        self.reconciler = reconciler
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

    /// What `upload` kicked off: the created clip, plus whether its transfer
    /// is still running in the background (R2) or already done (iCloud copy).
    public struct Started: Sendable {
        public let clip: Clip
        public let isBackground: Bool
    }

    /// Creates the clip row from a (possibly user-edited) draft and starts the
    /// upload through the currently selected storage backend.
    @discardableResult
    public func upload(
        _ draft: ClipDraft,
        orgId: UUID,
        uploadedBy: UUID?,
        folderId: UUID? = nil
    ) async throws -> Started {
        // Dedupe up front: the DB's unique (org, content_hash) index would
        // reject the metadata write anyway; checking first gives a clear error
        // and no orphan row. A failed earlier attempt at the same file is dead
        // weight — clear its objects (via whichever backend holds them) and
        // row, then upload fresh.
        if let existing = try await clips.findByHash(draft.contentHash, orgId: orgId) {
            if existing.status == .failed {
                let backend = router.backend(for: existing)
                try await backend.deleteObjects(for: existing)
                if !backend.deletesRow {
                    try await clips.delete(existing.id)
                }
            } else {
                throw UploadPipelineError.duplicate(existingTitle: existing.title)
            }
        }

        // The backend is captured once per upload: switching the Settings
        // choice mid-flight never splits one clip across providers.
        let backend = router.current

        let clip = try await clips.create(
            title: draft.title,
            orgId: orgId,
            uploadedBy: uploadedBy,
            folderId: folderId
        )

        let started: StartedUpload
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
               let key = try? await backend.uploadThumbnail(thumbnail, clipId: clip.id) {
                try? await clips.setThumbKey(clip.id, key)
            }

            let ext = draft.fileURL.pathExtension.isEmpty ? "mp4" : draft.fileURL.pathExtension.lowercased()
            let contentType = Self.contentType(forExtension: ext)
            let clipId = clip.id
            let fileURL = draft.fileURL
            let clipsService = clips
            let pendingStore = store

            // Durable ordering, provider-agnostic: the row learns its key and
            // the upload registers for crash recovery BEFORE any bytes move.
            started = try await backend.startVideoUpload(
                fileURL: fileURL,
                clipId: clipId,
                ext: ext,
                contentType: contentType
            ) { key in
                try await clipsService.markUploading(id: clipId, storageKey: key, provider: backend.provider)
                pendingStore.track(clipId: clipId, fileURL: fileURL)
            }
        } catch {
            // Don't leave a half-created row behind; the draft file is intact,
            // so the user can simply try again. (A tracked-but-dead entry is
            // released by the next launch sweep.)
            try? await clips.delete(clip.id)
            throw error
        }

        // A synchronous backend (iCloud copy) is done — resolve the status
        // through the reconciler, the single writer of terminal clip status.
        if case .completed = started {
            await reconciler.resolveCompleted(clipId: clip.id)
        }
        return Started(clip: clip, isBackground: {
            if case .background = started { return true } else { return false }
        }())
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
