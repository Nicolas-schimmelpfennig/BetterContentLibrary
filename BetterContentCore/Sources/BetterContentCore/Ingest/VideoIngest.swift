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

    /// Renders a JPEG poster thumbnail, bounded to `maxPixel` on its longest edge.
    ///
    /// Seeks ~10% into the clip (clamped to at least 0.5s, at most just before the
    /// end) rather than to the very first frame, which is typically a black/blank
    /// lead-in. Pass `duration` (from ``metadata(of:)``) to avoid re-loading it.
    ///
    /// Time tolerance is pinned to zero so the *exact* requested frame is decoded.
    /// Left at the default (`kCMTimePositiveInfinity`), `AVAssetImageGenerator`
    /// returns the nearest keyframe, which — depending on each video's keyframe
    /// spacing — lands anywhere from frame 0 to well past the seek point, making
    /// posters inconsistent across clips (the hover-skim generator pins tolerance
    /// for the same reason).
    public static func thumbnailJPEG(
        of url: URL,
        duration: Double? = nil,
        maxPixel: CGFloat = 640,
        quality: CGFloat = 0.8
    ) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let total: Double
        if let duration {
            total = duration
        } else {
            total = try await CMTimeGetSeconds(asset.load(.duration))
        }
        let seconds = min(max(total * 0.1, 0.5), max(total - 0.1, 0))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        // Decode the exact frame for poster consistency. Some encodings (sparse
        // keyframes, odd containers) can't satisfy a zero-tolerance request and
        // throw; rather than yield no poster at all, retry once allowing the
        // generator to snap to a nearby frame.
        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: time).image
        } catch {
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            cgImage = try await generator.image(at: time).image
        }

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
