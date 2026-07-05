//
//  ICloudBackend.swift
//  BetterContentCore
//
//  The user's iCloud Drive as a `StorageBackend`. Files live in the app's
//  default ubiquity container under Documents/ (visible in Finder/Files):
//    Documents/Clips/<clipId>.<ext>    — videos
//    Documents/Thumbs/<clipId>.jpg     — poster thumbnails
//
//  "Upload" is a local copy into the container — from there the OS owns the
//  sync, like any iCloud Drive document. Personal-storage semantics: only
//  devices signed into the same Apple ID can fetch these bytes; org teammates
//  see the catalog row but not the video.
//

import Foundation

public struct ICloudBackend: StorageBackend {
    public let provider = StorageProvider.iCloudDrive
    /// Only the provider's files are removed; the caller deletes the DB row.
    public let deletesRow = false

    public init() {}

    /// Whether a signed-in iCloud account with iCloud Drive is present.
    public static var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    public func startVideoUpload(
        fileURL: URL,
        clipId: UUID,
        ext: String,
        contentType: String,
        onKeyIssued: @Sendable (String) async throws -> Void
    ) async throws -> StartedUpload {
        let key = "Clips/\(clipId.uuidString).\(ext)"
        // Resolve the container first so an unavailable iCloud account fails
        // before the row is marked uploading.
        let dest = try await containerURL(for: key)
        try await onKeyIssued(key)
        try await copyReplacing(from: fileURL, to: dest)
        return .completed(key: key)
    }

    @discardableResult
    public func uploadThumbnail(_ jpeg: Data, clipId: UUID) async throws -> String {
        let key = thumbKey(clipId: clipId)
        let dest = try await containerURL(for: key)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: dest, options: .atomic)
        }.value
        return key
    }

    public func downloadThumbnail(clipId: UUID) async throws -> Data {
        let url = try await containerURL(for: thumbKey(clipId: clipId))
        try await ensureDownloaded(url, timeout: 30)
        return try Data(contentsOf: url)
    }

    public func playbackURL(for clip: Clip) async throws -> URL {
        guard let key = clip.storageKey else { throw StorageBackendError.noStorageKey }
        let url = try await containerURL(for: key)
        // Videos can be large; give iCloud a generous window on first access.
        try await ensureDownloaded(url, timeout: 300)
        return url
    }

    @discardableResult
    public func downloadVideo(clip: Clip, to destination: URL) async throws -> URL {
        let source = try await playbackURL(for: clip)
        try await copyReplacing(from: source, to: destination)
        return destination
    }

    public func deleteObjects(for clip: Clip) async throws {
        var urls: [URL] = [try await containerURL(for: thumbKey(clipId: clip.id))]
        if let key = clip.storageKey {
            urls.append(try await containerURL(for: key))
        }
        try await Task.detached(priority: .utility) { [urls] in
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // Already gone (partial earlier delete, or never uploaded) —
                    // deletion is idempotent, like R2's.
                }
            }
        }.value
    }

    // MARK: Container plumbing

    private func thumbKey(clipId: UUID) -> String {
        "Thumbs/\(clipId.uuidString).jpg"
    }

    /// Resolves a key to its absolute URL inside the container's Documents/.
    /// `url(forUbiquityContainerIdentifier:)` can be slow on first call, so it
    /// always runs off the calling actor.
    private func containerURL(for key: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                throw StorageBackendError.unavailable(
                    "iCloud Drive isn't available. Sign into iCloud (with iCloud Drive enabled) and try again."
                )
            }
            return root.appending(component: "Documents").appending(path: key)
        }.value
    }

    /// Copies a file, replacing any existing one, off the calling actor.
    private func copyReplacing(from source: URL, to dest: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
        }.value
    }

    /// Makes sure the ubiquitous item is materialized locally: kicks off the
    /// download if needed and polls its status until current (or timeout).
    /// Polling `URLResourceValues` is simpler than an `NSMetadataQuery` and
    /// plenty for a foreground "open this clip" wait.
    private func ensureDownloaded(_ url: URL, timeout: TimeInterval) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default

            func status() throws -> URLUbiquitousItemDownloadingStatus? {
                let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return values.ubiquitousItemDownloadingStatus
            }

            // A plain local file (or an already-current item) needs no wait.
            guard fm.fileExists(atPath: url.path) == false || (try? status()) != .current else { return }

            do {
                try fm.startDownloadingUbiquitousItem(at: url)
            } catch {
                // Not a ubiquitous item but present on disk → usable as-is.
                if fm.fileExists(atPath: url.path) { return }
                throw error
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let current = try? status(), current == .current { return }
                // While downloading, the placeholder may not exist at the final
                // path yet; keep polling.
                try await Task.sleep(for: .milliseconds(300))
            }
            throw StorageBackendError.downloadTimeout
        }.value
    }
}
