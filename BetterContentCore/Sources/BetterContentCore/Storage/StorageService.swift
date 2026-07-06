import Foundation
import Supabase

/// A short-lived presigned URL for uploading a new object to R2, plus the object
/// key the file will live at. Returned by the `r2-sign` Edge Function.
public struct UploadTicket: Decodable, Sendable {
    public let uploadUrl: URL
    public let key: String
}

/// A short-lived presigned URL for downloading an existing clip's object from R2.
public struct DownloadTicket: Decodable, Sendable {
    public let downloadUrl: URL
    public let key: String
}

/// Errors surfaced while moving bytes to or from R2.
public enum StorageError: Error, Sendable {
    /// R2 returned a non-success HTTP status for an upload or download.
    case unexpectedStatus(Int)
    /// The response was not an HTTP response (should not happen in practice).
    case notHTTP
}

/// Moves video bytes between the apps and Cloudflare R2.
///
/// Per the project's golden rule, video bytes never proxy through Supabase: this
/// service asks the `r2-sign` Edge Function for a short-lived presigned URL
/// (which requires the caller's auth, so keys are org-scoped) and then talks
/// straight to R2 with `URLSession`.
public final class StorageService: Sendable {
    private let client: SupabaseClient
    private let urlSession: URLSession

    public init(client: SupabaseClient = Backend.client, urlSession: URLSession = .shared) {
        self.client = client
        self.urlSession = urlSession
    }

    // MARK: Presigning (via the r2-sign Edge Function)

    /// Requests a presigned `PUT` URL for a brand-new object. The Edge Function
    /// generates the key as `orgs/<org_id>/clips/<uuid>.<ext>`.
    public func requestUploadTicket(ext: String, contentType: String) async throws -> UploadTicket {
        try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: UploadRequest(ext: ext, contentType: contentType))
        )
    }

    /// Requests a presigned `GET` URL for an existing clip. RLS in the Edge
    /// Function guarantees the clip belongs to the caller's org.
    public func requestDownloadTicket(clipId: UUID) async throws -> DownloadTicket {
        try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: DownloadRequest(clipId: clipId.uuidString))
        )
    }

    /// Uploads a JPEG thumbnail for a clip and returns its R2 key. Thumbnails are
    /// small, so this uses the foreground session.
    @discardableResult
    public func uploadThumbnail(_ jpeg: Data, clipId: UUID) async throws -> String {
        let ticket: UploadTicket = try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: ThumbUploadRequest(clipId: clipId.uuidString))
        )
        var request = URLRequest(url: ticket.uploadUrl)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await urlSession.upload(for: request, from: jpeg)
        try Self.verifySuccess(response)
        return ticket.key
    }

    /// Fetches a clip's thumbnail JPEG bytes from R2.
    public func downloadThumbnail(clipId: UUID) async throws -> Data {
        let ticket: DownloadTicket = try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: ThumbDownloadRequest(clipId: clipId.uuidString))
        )
        let (data, response) = try await urlSession.data(from: ticket.downloadUrl)
        try Self.verifySuccess(response)
        return data
    }

    /// Resolves a short-lived presigned GET URL for streaming a clip's video
    /// (e.g. for `AVPlayer` preview or frame skimming).
    public func streamURL(clipId: UUID) async throws -> URL {
        try await requestDownloadTicket(clipId: clipId).downloadUrl
    }

    /// Permanently deletes a clip: its R2 objects (video + thumbnail) and then
    /// its database row, all server-side in the `r2-sign` Edge Function so the
    /// ordering (bytes before the row that points at them) lives in one place.
    /// Throws if the objects couldn't be removed — the row is kept in that case
    /// so the delete can be retried.
    public func deleteClip(clipId: UUID) async throws {
        let _: DeleteResponse = try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: DeleteRequest(clipId: clipId.uuidString))
        )
    }

    /// Deletes a single R2 object by key, touching no database rows. This is
    /// storage migration's cleanup step for a clip's OLD bytes after the row
    /// was re-keyed to another provider — `deleteClip` would take the row (and
    /// with it the freshly migrated clip) down too. The key must lie under the
    /// caller's own org prefix; foreign-prefix keys are refused server-side.
    public func deleteObject(key: String) async throws {
        let _: DeleteResponse = try await client.functions.invoke(
            "r2-sign",
            options: FunctionInvokeOptions(body: DeleteObjectRequest(key: key))
        )
    }

    // MARK: Direct transfer to/from R2

    /// Uploads a local file to R2 using a presigned ticket. The presign signs
    /// only the `host` header, so the `Content-Type` is set freely here.
    public func upload(fileURL: URL, using ticket: UploadTicket, contentType: String) async throws {
        var request = URLRequest(url: ticket.uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (_, response) = try await urlSession.upload(for: request, fromFile: fileURL)
        try Self.verifySuccess(response)
    }

    /// Convenience: presign and upload in one step.
    @discardableResult
    public func upload(fileURL: URL, ext: String, contentType: String) async throws -> UploadTicket {
        let ticket = try await requestUploadTicket(ext: ext, contentType: contentType)
        try await upload(fileURL: fileURL, using: ticket, contentType: contentType)
        return ticket
    }

    /// Downloads a clip's object from R2 to `destination`, replacing any file
    /// already there. Presigns the download internally.
    @discardableResult
    public func download(clipId: UUID, to destination: URL) async throws -> URL {
        let ticket = try await requestDownloadTicket(clipId: clipId)
        let (tempURL, response) = try await urlSession.download(from: ticket.downloadUrl)
        try Self.verifySuccess(response)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: Helpers

    private static func verifySuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw StorageError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw StorageError.unexpectedStatus(http.statusCode)
        }
    }

    private struct UploadRequest: Encodable {
        let action = "upload"
        let ext: String
        let contentType: String
    }

    private struct DownloadRequest: Encodable {
        let action = "download"
        let clipId: String
    }

    private struct ThumbUploadRequest: Encodable {
        let action = "upload"
        let kind = "thumb"
        let clipId: String
    }

    private struct ThumbDownloadRequest: Encodable {
        let action = "download"
        let kind = "thumb"
        let clipId: String
    }

    private struct DeleteRequest: Encodable {
        let action = "delete"
        let clipId: String
    }

    private struct DeleteObjectRequest: Encodable {
        let action = "delete_object"
        let key: String
    }

    private struct DeleteResponse: Decodable {
        let ok: Bool
    }
}
