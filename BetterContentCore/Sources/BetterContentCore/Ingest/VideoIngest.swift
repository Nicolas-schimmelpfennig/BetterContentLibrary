import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Intrinsic properties of a video file, read on ingest.
public struct VideoMetadata: Sendable, Equatable {
    public let durationS: Double
    public let width: Int
    public let height: Int
    public let orientation: ClipOrientation

    public init(durationS: Double, width: Int, height: Int, orientation: ClipOrientation) {
        self.durationS = durationS
        self.width = width
        self.height = height
        self.orientation = orientation
    }
}

public enum VideoIngestError: Error, Sendable {
    case noVideoTrack
    case thumbnailEncodingFailed
}

/// Reads metadata and renders thumbnails from local video files via AVFoundation.
public enum VideoIngest {
    /// Loads duration, display dimensions (after applying the track's preferred
    /// transform, so rotated phone video reports its visual orientation), and the
    /// derived `ClipOrientation`.
    public static func metadata(of url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoIngestError.noVideoTrack
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let displayed = naturalSize.applying(transform)
        let width = Int(abs(displayed.width).rounded())
        let height = Int(abs(displayed.height).rounded())

        let orientation: ClipOrientation =
            width > height ? .horizontal : (width < height ? .vertical : .square)

        return VideoMetadata(
            durationS: CMTimeGetSeconds(duration),
            width: width,
            height: height,
            orientation: orientation
        )
    }

    /// The video's original creation date from its container metadata, if present
    /// (e.g. the `creationDate` a camera writes). Falls back to nil; callers can
    /// use the file's own creation date instead.
    public static func capturedDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        if let date = try? await item.load(.dateValue) { return date }
        if let string = try? await item.load(.stringValue),
           let parsed = ISO8601DateFormatter().date(from: string) {
            return parsed
        }
        return nil
    }

    /// Renders a JPEG thumbnail near the given timestamp, bounded to `maxPixel`
    /// on its longest edge. Not yet uploaded anywhere — callers decide what to do
    /// with it (the `clips` schema has no thumbnail column yet).
    public static func thumbnailJPEG(
        of url: URL,
        atSeconds seconds: Double = 0,
        maxPixel: CGFloat = 600,
        quality: CGFloat = 0.7
    ) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image

        guard let data = jpegData(from: cgImage, quality: quality) else {
            throw VideoIngestError.thumbnailEncodingFailed
        }
        return data
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
