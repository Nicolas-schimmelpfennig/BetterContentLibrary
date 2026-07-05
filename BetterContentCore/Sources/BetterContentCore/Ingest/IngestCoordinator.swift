#if os(macOS)
import Foundation
import Observation

/// Drives the macOS ingest pipeline: watch a folder → on each finished file,
/// hash + read metadata → create the clip row → presign → hand the bytes to the
/// background uploader → mark ready when it lands.
///
/// `@Observable` so SwiftUI can show what's currently ingesting/uploading.
@MainActor
@Observable
public final class IngestCoordinator {
    public private(set) var isWatching = false
    public private(set) var watchedFolder: URL?
    /// Upload progress (0...1) keyed by clip id, for in-flight transfers.
    public private(set) var uploadProgress: [UUID: Double] = [:]
    public private(set) var lastError: String?

    private let orgId: UUID
    private let userId: UUID?
    private let clips: ClipsService
    private let storage: StorageService
    private let uploader: BackgroundUploadService

    private var watcher: FolderWatcher?
    private var eventTask: Task<Void, Never>?

    public init(
        orgId: UUID,
        userId: UUID?,
        clips: ClipsService = ClipsService(),
        storage: StorageService = StorageService(),
        uploader: BackgroundUploadService = .shared
    ) {
        self.orgId = orgId
        self.userId = userId
        self.clips = clips
        self.storage = storage
        self.uploader = uploader
        wireUploader()
    }

    public func startWatching(folder: URL) {
        stopWatching()
        let watcher = FolderWatcher(folder: folder) { [weak self] fileURL in
            // FolderWatcher calls back on its own queue; hop onto the main actor.
            Task { await self?.ingest(fileURL: fileURL) }
        }
        watcher.start()
        self.watcher = watcher
        watchedFolder = folder
        isWatching = true
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        isWatching = false
        watchedFolder = nil
    }

    /// Runs the full ingest for a single finished file. Public so a manual
    /// "import file…" action can reuse it.
    public func ingest(fileURL: URL) async {
        do {
            // Hashing is blocking I/O — keep it off the main actor.
            let hash = try await Task.detached { try ContentHasher.sha256(of: fileURL) }.value

            if try await clips.findByHash(hash, orgId: orgId) != nil {
                return // already ingested this exact file
            }

            let title = fileURL.deletingPathExtension().lastPathComponent
            let clip = try await clips.create(title: title, orgId: orgId, uploadedBy: userId)

            let metadata = try await VideoIngest.metadata(of: fileURL)
            let captured = await VideoIngest.capturedDate(of: fileURL)
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            try await clips.applyMetadata(
                id: clip.id,
                durationS: metadata.durationS,
                width: metadata.width,
                height: metadata.height,
                orientation: metadata.orientation,
                contentHash: hash,
                fileSize: fileSize ?? nil,
                capturedAt: captured
            )

            let ext = fileURL.pathExtension.isEmpty ? "mp4" : fileURL.pathExtension.lowercased()
            let contentType = Self.contentType(forExtension: ext)
            let ticket = try await storage.requestUploadTicket(ext: ext, contentType: contentType)

            // This shelved watch-folder path is hard-wired to R2; route it
            // through StorageRouter if it's ever revived.
            try await clips.markUploading(id: clip.id, storageKey: ticket.key, provider: .r2)
            uploadProgress[clip.id] = 0
            uploader.enqueue(
                fileURL: fileURL,
                to: ticket.uploadUrl,
                key: ticket.key,
                clipId: clip.id,
                contentType: contentType
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Uploader wiring

    private func wireUploader() {
        // Status reconciliation is owned process-wide by UploadReconciler; this
        // loop only mirrors progress into the observable UI state.
        // NOTE: if the watch-folder feature is revived, files should be staged
        // through PendingUploadStore (and tracked) before enqueueing, so the
        // launch sweep covers them like drag-and-drop uploads.
        eventTask = Task { [weak self] in
            guard let uploader = self?.uploader else { return }
            for await event in uploader.events() {
                guard let self else { return }
                switch event {
                case let .progress(clipId, fraction):
                    self.uploadProgress[clipId] = fraction
                case let .finished(clipId, _):
                    self.uploadProgress[clipId] = nil
                case let .failed(clipId, message):
                    self.uploadProgress[clipId] = nil
                    self.lastError = message
                }
            }
        }
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
#endif
