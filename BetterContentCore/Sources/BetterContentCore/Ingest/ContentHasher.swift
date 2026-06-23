import CryptoKit
import Foundation

/// Computes a content hash for a file, used to dedupe re-ingested videos.
///
/// Reads the file in chunks so a multi-gigabyte video never loads fully into
/// memory. This is blocking I/O — call it off the main thread.
public enum ContentHasher {
    private static let chunkSize = 1 << 20 // 1 MiB

    /// Returns the lowercase hex SHA-256 of the file's bytes.
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
