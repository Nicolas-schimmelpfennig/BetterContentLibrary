//
//  StorageBackend.swift
//  BetterContentCore
//
//  The seam that makes video-byte storage pluggable. Supabase remains the
//  catalog for every provider; a backend only moves bytes. Each clip records
//  its provider (`Clip.storageProvider`), so mixed libraries route per clip.
//

import Foundation

/// How a video upload was started.
public enum StartedUpload: Sendable {
    /// The transfer runs on the background `URLSession`; its terminal outcome
    /// reaches `UploadReconciler` via `BackgroundUploadService`'s observers.
    case background(key: String)
    /// The bytes are already durably handed off (e.g. copied into the iCloud
    /// container — the OS owns the sync from there). The caller resolves the
    /// clip's status immediately.
    case completed(key: String)

    public var key: String {
        switch self {
        case let .background(key), let .completed(key): return key
        }
    }
}

/// Errors common to storage backends.
public enum StorageBackendError: LocalizedError, Sendable {
    /// The provider isn't usable right now (e.g. no iCloud account signed in).
    case unavailable(String)
    /// The clip has no storage key (never finished uploading).
    case noStorageKey
    /// Waiting for the provider to materialize a file took too long.
    case downloadTimeout

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        case .noStorageKey: return "This clip has no stored video."
        case .downloadTimeout: return "Timed out waiting for the video to download."
        }
    }
}

/// Moves clip bytes (video + poster thumbnail) for one provider.
public protocol StorageBackend: Sendable {
    var provider: StorageProvider { get }

    /// Starts the (possibly long-running) video upload for a clip.
    ///
    /// `onKeyIssued` runs once the storage key is known but **before** any
    /// bytes move: the caller records the key + provider on the clip row and
    /// registers the upload for crash recovery. If it throws, the backend
    /// must abort without starting the transfer — this preserves the durable
    /// ordering (row knows its key before the transfer can finish).
    func startVideoUpload(
        fileURL: URL,
        clipId: UUID,
        ext: String,
        contentType: String,
        onKeyIssued: @Sendable (String) async throws -> Void
    ) async throws -> StartedUpload

    /// Uploads a poster JPEG and returns its storage key. Small; foreground.
    @discardableResult
    func uploadThumbnail(_ jpeg: Data, clipId: UUID) async throws -> String

    /// Fetches a clip's poster JPEG bytes.
    func downloadThumbnail(clipId: UUID) async throws -> Data

    /// A URL `AVPlayer`/`AVAssetImageGenerator` can use right now: a presigned
    /// https URL (R2) or a local file URL once the provider's copy is present.
    func playbackURL(for clip: Clip) async throws -> URL

    /// Downloads the clip's video to `destination`, replacing any file there.
    @discardableResult
    func downloadVideo(clip: Clip, to destination: URL) async throws -> URL

    /// Removes the provider's objects (video + thumbnail). For R2 this also
    /// deletes the DB row server-side (one atomic edge call); every other
    /// backend leaves the row to the caller — check `deletesRow`.
    func deleteObjects(for clip: Clip) async throws

    /// Whether `deleteObjects` also removed the clip's DB row.
    var deletesRow: Bool { get }
}
