//
//  AppModel.swift
//  BetterContentCore
//
//  Session-scoped controller shared by the macOS and iOS apps.
//

import Foundation
import Observation

extension Clip {
    /// A playable clip has finished uploading, so its video exists in R2.
    public var isPlayable: Bool { status != .ingesting && status != .uploading }
}

/// Loads and caches clip poster thumbnails (memory + a durable on-disk JPEG
/// cache), adapted from VideoTag's ThumbnailStore.
///
/// A poster is rendered once at import and stored here directly (see
/// ``store(_:for:)``), so it displays immediately without any network round-trip
/// and never has to be re-decoded from the video. R2 is the cross-device source
/// of truth: if a clip has a `thumbKey` but isn't on this device's disk yet
/// (e.g. uploaded elsewhere), it's fetched once and cached.
@MainActor
public final class ThumbnailLoader {
    private let storage: StorageService
    private let cache = NSCache<NSString, PlatformImage>()
    private let directory: URL

    public init(storage: StorageService = StorageService()) {
        self.storage = storage
        // Application Support (not Caches) so posters survive system cache purges
        // — the whole point is to render them once and keep them.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appending(components: "BetterContentLibrary", "Thumbnails")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for clipId: UUID) -> URL {
        directory.appending(component: "\(clipId.uuidString).jpg")
    }

    public func image(for clip: Clip) async -> PlatformImage? {
        let key = clip.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Local disk first — covers the just-imported poster and anything fetched
        // earlier, with no network call.
        if let data = try? Data(contentsOf: fileURL(for: clip.id)), let image = PlatformImage(data: data) {
            cache.setObject(image, forKey: key)
            return image
        }

        // Only reach for R2 if the clip actually has a poster uploaded.
        guard clip.thumbKey != nil else { return nil }
        guard let data = try? await storage.downloadThumbnail(clipId: clip.id),
              let image = PlatformImage(data: data) else { return nil }
        try? data.write(to: fileURL(for: clip.id))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Stores a freshly rendered poster (memory + disk) so it displays at once,
    /// without waiting on the R2 upload or a later download.
    public func store(_ jpeg: Data, for clipId: UUID) {
        try? jpeg.write(to: fileURL(for: clipId))
        if let image = PlatformImage(data: jpeg) {
            cache.setObject(image, forKey: clipId.uuidString as NSString)
        }
    }

    /// Drops the memory + on-disk copy for a clip so the next `image(for:)`
    /// re-fetches it from R2. Call after a thumbnail is regenerated server-side.
    public func invalidate(clipId: UUID) {
        cache.removeObject(forKey: clipId.uuidString as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: clipId))
    }
}

/// Session-scoped state for a signed-in user.
@MainActor
@Observable
public final class AppModel {
    public let profile: Profile
    public let library: LibraryModel
    public let schedule: ScheduleModel
    public let thumbnails = ThumbnailLoader()
    public let skim = SkimProvider()

    /// Live upload progress (0...1) keyed by clip id.
    public private(set) var uploadProgress: [UUID: Double] = [:]

    private let storage = StorageService()
    private let clips = ClipsService()
    private let uploader = ClipUploader()
    private var eventTask: Task<Void, Never>?
    private var pendingFiles: [UUID: URL] = [:]

    /// Clips currently having their thumbnail regenerated, for in-UI feedback.
    public private(set) var regenerating: Set<UUID> = []

    /// Clips already considered for poster backfill this session, so a missing
    /// poster is attempted at most once (even if regeneration fails).
    private var backfillAttempted: Set<UUID> = []

    private let pendingDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("BetterContentLibrary/PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public init(profile: Profile) {
        self.profile = profile
        self.library = LibraryModel(orgId: profile.orgId)
        self.schedule = ScheduleModel(orgId: profile.orgId, currentProfileId: profile.id)
        observeUploads()
    }

    public func importFile(_ source: URL) async throws -> ClipDraft {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let dest = pendingDir.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: dest)
        return try await uploader.makeDraft(from: dest)
    }

    /// Confirms a draft and starts the background upload, landing it in whatever
    /// folder the library is currently viewing.
    public func upload(_ draft: ClipDraft) async {
        do {
            let clip = try await uploader.upload(
                draft,
                orgId: profile.orgId,
                uploadedBy: profile.id,
                folderId: library.currentFolder?.id
            )
            // Persist the poster we already rendered for the draft, so the card
            // shows it instantly — no R2 round-trip, no re-decode.
            if let jpeg = draft.thumbnailJPEG { thumbnails.store(jpeg, for: clip.id) }
            pendingFiles[clip.id] = draft.fileURL
            uploadProgress[clip.id] = 0
            await library.load()
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }

    /// Permanently deletes clips: their R2 objects (video + poster), then the DB
    /// rows, then the local poster cache. Reloads the library once at the end.
    public func deleteClips(_ clips: [Clip]) async {
        for clip in clips {
            do {
                // Delete R2 objects first — the Edge Function needs the row's
                // r2_key, which the DB delete below removes.
                try? await storage.deleteObjects(clipId: clip.id)
                try await self.clips.delete(clip.id)
                thumbnails.invalidate(clipId: clip.id)
                uploadProgress[clip.id] = nil
            } catch {
                library.errorMessage = "Couldn't delete “\(clip.title)”: \(error.localizedDescription)"
            }
        }
        await library.load()
    }

    /// One-time, lazy backfill for clips with no poster (uploaded before posters
    /// existed, or whose poster upload failed): render and persist one for each,
    /// at most once per session. Posters are stored server-side, so this won't
    /// repeat on later launches — fixing the "regenerate by hand" papercut.
    public func backfillMissingThumbnails() async {
        let targets = library.items.filter {
            $0.isPlayable && $0.thumbKey == nil && !backfillAttempted.contains($0.id)
        }
        guard !targets.isEmpty else { return }
        var changed = false
        for clip in targets {
            backfillAttempted.insert(clip.id)
            if await renderThumbnail(for: clip) { changed = true }
        }
        if changed { await library.load() }
    }

    public func discard(_ draft: ClipDraft) {
        try? FileManager.default.removeItem(at: draft.fileURL)
    }

    /// A short-lived presigned URL for streaming a clip's video (preview).
    public func streamURL(for clip: Clip) async -> URL? {
        try? await storage.streamURL(clipId: clip.id)
    }

    /// Downloads a clip's video from R2 to a temporary file and returns its URL.
    /// The caller saves/moves it (e.g. into the photo library) and is responsible
    /// for cleanup. The file keeps the clip's original extension so the OS treats
    /// it as a video.
    public func downloadVideoFile(for clip: Clip) async throws -> URL {
        let ext = clip.r2Key.map { ($0 as NSString).pathExtension } ?? ""
        let suffix = ext.isEmpty ? "mp4" : ext
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(clip.id.uuidString).\(suffix)")
        return try await storage.download(clipId: clip.id, to: dest)
    }

    /// Re-derives a clip's poster thumbnail from its uploaded video and reloads
    /// the library on success so the card updates. Fixes clips whose poster is
    /// missing or came from the old frame-0 code.
    public func regenerateThumbnail(for clip: Clip) async {
        if await renderThumbnail(for: clip) { await library.load() }
    }

    /// Pulls the clip's video from R2, renders a fresh poster (skipping the black
    /// lead-in), re-uploads it, records the key, and seeds the local cache so the
    /// new poster shows without another download. Returns whether it succeeded;
    /// does *not* reload the library (callers batch that). Skips clips that aren't
    /// uploaded yet or are already in flight.
    @discardableResult
    private func renderThumbnail(for clip: Clip) async -> Bool {
        guard clip.isPlayable, !regenerating.contains(clip.id) else { return false }
        regenerating.insert(clip.id)
        defer { regenerating.remove(clip.id) }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("regen-\(clip.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            try await storage.download(clipId: clip.id, to: temp)
            let jpeg = try await VideoIngest.thumbnailJPEG(of: temp, duration: clip.durationS)
            let key = try await storage.uploadThumbnail(jpeg, clipId: clip.id)
            try await clips.setThumbKey(clip.id, key)
            thumbnails.store(jpeg, for: clip.id)
            return true
        } catch {
            library.errorMessage = "Couldn't regenerate thumbnail: \(error.localizedDescription)"
            return false
        }
    }

    /// Regenerates thumbnails for several clips in sequence (bulk action).
    public func regenerateThumbnails(for clips: [Clip]) async {
        for clip in clips { await regenerateThumbnail(for: clip) }
    }

    private func observeUploads() {
        eventTask = Task { [weak self] in
            guard let uploader = self?.uploader else { return }
            for await event in uploader.events() {
                guard let self else { return }
                switch event {
                case let .progress(clipId, fraction):
                    uploadProgress[clipId] = fraction
                case let .finished(clipId, _):
                    uploadProgress[clipId] = nil
                    cleanUpPendingFile(clipId)
                    await library.load()
                case let .failed(clipId, message):
                    uploadProgress[clipId] = nil
                    cleanUpPendingFile(clipId)
                    library.errorMessage = message
                }
            }
        }
    }

    private func cleanUpPendingFile(_ clipId: UUID) {
        if let url = pendingFiles.removeValue(forKey: clipId) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
