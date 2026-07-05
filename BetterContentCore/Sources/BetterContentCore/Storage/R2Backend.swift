//
//  R2Backend.swift
//  BetterContentCore
//
//  Cloudflare R2 as a `StorageBackend`: a thin adapter over `StorageService`
//  (presigned URLs from the `r2-sign` edge function, bytes moved directly).
//  This is the org-shared provider — any org member can fetch these bytes.
//

import Foundation

public struct R2Backend: StorageBackend {
    public let provider = StorageProvider.r2
    /// R2 deletion is one server-side edge call that removes objects AND the
    /// row, so byte/row ordering lives in one place.
    public let deletesRow = true

    private let storage: StorageService
    private let uploader: BackgroundUploadService

    public init(storage: StorageService = StorageService(), uploader: BackgroundUploadService = .shared) {
        self.storage = storage
        self.uploader = uploader
    }

    public func startVideoUpload(
        fileURL: URL,
        clipId: UUID,
        ext: String,
        contentType: String,
        onKeyIssued: @Sendable (String) async throws -> Void
    ) async throws -> StartedUpload {
        let ticket = try await storage.requestUploadTicket(ext: ext, contentType: contentType)
        try await onKeyIssued(ticket.key)
        uploader.enqueue(
            fileURL: fileURL,
            to: ticket.uploadUrl,
            key: ticket.key,
            clipId: clipId,
            contentType: contentType
        )
        return .background(key: ticket.key)
    }

    @discardableResult
    public func uploadThumbnail(_ jpeg: Data, clipId: UUID) async throws -> String {
        try await storage.uploadThumbnail(jpeg, clipId: clipId)
    }

    public func downloadThumbnail(clipId: UUID) async throws -> Data {
        try await storage.downloadThumbnail(clipId: clipId)
    }

    public func playbackURL(for clip: Clip) async throws -> URL {
        try await storage.streamURL(clipId: clip.id)
    }

    @discardableResult
    public func downloadVideo(clip: Clip, to destination: URL) async throws -> URL {
        try await storage.download(clipId: clip.id, to: destination)
    }

    public func deleteObjects(for clip: Clip) async throws {
        try await storage.deleteClip(clipId: clip.id)
    }
}
