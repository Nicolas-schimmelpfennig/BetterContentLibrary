//
//  StorageMigrationService.swift
//  BetterContentCore
//
//  Bulk-converts a library's bytes between storage providers (iCloud Drive ↔
//  BetterContent Cloud). Needed at the multi-user boundary: teams are R2-only,
//  so going multi-user means converting iCloud clips to R2 first, and shrinking
//  back to a personal library can move them the other way.
//
//  Per-clip ordering keeps the row pointing at valid bytes at every instant:
//    1. upload the NEW copy completely (foreground — this is a supervised,
//       progress-visible operation, not a fire-and-forget background upload)
//    2. atomically re-key the row (key + provider + thumb; status untouched,
//       the clip stays ready and playable throughout)
//    3. delete the OLD bytes
//  A crash between steps leaves only an orphaned object — never a broken clip —
//  and re-running skips clips that already reached the target provider.
//

import Foundation

public final class StorageMigrationService: Sendable {
    private let clips: ClipsService
    private let storage: StorageService
    private let iCloud: ICloudBackend

    public init(
        clips: ClipsService = ClipsService(),
        storage: StorageService = StorageService(),
        iCloud: ICloudBackend = ICloudBackend()
    ) {
        self.clips = clips
        self.storage = storage
        self.iCloud = iCloud
    }

    /// The clips a migration to `target` still has to move: settled, with
    /// bytes, and not already there. Planning off this set is what makes the
    /// whole operation resumable — kill the app mid-run and start again.
    public func pendingClips(to target: StorageProvider) async throws -> [Clip] {
        try await clips.list(limit: 2000).filter {
            $0.status == .ready && $0.storageProvider != target && $0.storageKey != nil
        }
    }

    /// Moves one clip's bytes to `target`. Safe to call again after a failure
    /// or crash; a clip that already migrated is skipped.
    public func migrate(_ clip: Clip, to target: StorageProvider) async throws {
        guard clip.status == .ready, clip.storageProvider != target,
              let oldKey = clip.storageKey else { return }

        switch target {
        case .r2:
            try await migrateToR2(clip, oldKey: oldKey)
        case .iCloudDrive:
            try await migrateToICloud(clip, oldKey: oldKey)
        case .googleDrive:
            throw StorageBackendError.unavailable("Google Drive isn't available yet.")
        }
    }

    // MARK: Directions

    private func migrateToR2(_ clip: Clip, oldKey: String) async throws {
        let ext = Self.ext(of: oldKey)
        let temp = Self.tempURL(for: clip.id, ext: ext)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Pull from the container (materializing from iCloud if needed), push
        // to R2 in the foreground — the ticket returns only after the PUT.
        try await iCloud.downloadVideo(clip: clip, to: temp)
        let ticket = try await storage.upload(
            fileURL: temp,
            ext: ext,
            contentType: ClipUploader.contentType(forExtension: ext)
        )

        // Thumbnail is best-effort: both providers key it by clip id, and a
        // missing poster regenerates on demand.
        var newThumbKey: String?
        if clip.thumbKey != nil, let jpeg = try? await iCloud.downloadThumbnail(clipId: clip.id) {
            newThumbKey = try? await storage.uploadThumbnail(jpeg, clipId: clip.id)
        }

        try await clips.setStorage(id: clip.id, storageKey: ticket.key, provider: .r2, thumbKey: newThumbKey)

        // Old container files last (row-safe: ICloudBackend never touches
        // rows). A failure here just leaves personal-storage orphans.
        try? await iCloud.deleteObjects(for: clip)
    }

    private func migrateToICloud(_ clip: Clip, oldKey: String) async throws {
        let ext = Self.ext(of: oldKey)
        let temp = Self.tempURL(for: clip.id, ext: ext)
        defer { try? FileManager.default.removeItem(at: temp) }

        // The row still points at R2 here, so the presigned download works.
        try await storage.download(clipId: clip.id, to: temp)

        // Copy into the container with a no-op onKeyIssued: the usual
        // "row learns its key before bytes move" contract is for crash
        // recovery of fresh uploads — here the row must keep its OLD pointer
        // until the new copy exists, so re-keying happens after, in step 2.
        let started = try await iCloud.startVideoUpload(
            fileURL: temp,
            clipId: clip.id,
            ext: ext,
            contentType: ClipUploader.contentType(forExtension: ext)
        ) { _ in }

        var newThumbKey: String?
        if clip.thumbKey != nil, let jpeg = try? await storage.downloadThumbnail(clipId: clip.id) {
            newThumbKey = try? await iCloud.uploadThumbnail(jpeg, clipId: clip.id)
        }

        try await clips.setStorage(id: clip.id, storageKey: started.key, provider: .iCloudDrive, thumbKey: newThumbKey)

        // Old R2 objects last, via the row-less delete_object action — the
        // row-deleting "delete" would destroy the clip we just migrated.
        // Clips brought in from another org still sit under that org's key
        // prefix; the server refuses those (403) and the orphan stays behind,
        // which is harmless.
        try? await storage.deleteObject(key: oldKey)
        if let oldThumb = clip.thumbKey {
            try? await storage.deleteObject(key: oldThumb)
        }
    }

    // MARK: Helpers

    private static func ext(of key: String) -> String {
        let ext = (key as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "mp4" : ext
    }

    private static func tempURL(for clipId: UUID, ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(clipId.uuidString).\(ext)")
    }
}
