//
//  CoverImage.swift
//  BetterContentCore
//
//  A scheduled post's custom thumbnail, ready to upload: JPEG or PNG bytes
//  plus the matching extension and MIME type. JPEG and PNG pass through
//  byte-for-byte (the file the creator made is the file they get back at post
//  time); anything else ImageIO can read — HEIC from the Photos picker, TIFF,
//  WebP… — is re-encoded as JPEG.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CoverImage: Sendable, Equatable {
    public let data: Data
    /// "jpg" or "png".
    public let ext: String
    public var contentType: String { ext == "png" ? "image/png" : "image/jpeg" }

    /// The largest cover accepted. Platform thumbnail limits are far lower
    /// (YouTube: 2 MB), so anything bigger is almost certainly the wrong file.
    public static let maxBytes = 25 * 1024 * 1024

    public enum ImportError: LocalizedError {
        case notAnImage
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notAnImage: return "That file isn't an image this app can read. Use a JPEG or PNG."
            case .tooLarge: return "That image is over 25 MB — too large for a thumbnail."
            }
        }
    }

    /// Reads image bytes into an uploadable cover, transcoding to JPEG when
    /// the source isn't already JPEG or PNG.
    public init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else {
            throw ImportError.notAnImage
        }
        let type = UTType(typeId)
        if type?.conforms(to: .png) == true {
            self.data = data
            ext = "png"
        } else if type?.conforms(to: .jpeg) == true {
            self.data = data
            ext = "jpg"
        } else {
            self.data = try Self.jpeg(from: source)
            ext = "jpg"
        }
    }

    /// Reads a file (security-scoped URLs from a file importer included).
    public init(contentsOf url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try self.init(data: Data(contentsOf: url))
    }

    /// Re-encodes the first frame as high-quality JPEG, keeping orientation
    /// metadata so a rotated HEIC doesn't come out sideways.
    private static func jpeg(from source: CGImageSource) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.notAnImage
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImageFromSource(dest, source, 0, options)
        guard CGImageDestinationFinalize(dest) else { throw ImportError.notAnImage }
        return out as Data
    }
}

/// What a schedule editor's save should do to the post's cover.
public enum CoverChange: Sendable, Equatable {
    case unchanged
    case set(CoverImage)
    case removed
}
