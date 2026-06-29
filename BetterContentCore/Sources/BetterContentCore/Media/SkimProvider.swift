//
//  SkimProvider.swift
//  BetterContentCore
//
//  Generates and caches video frames for scrubbing ("skimming") library cards —
//  hover-driven on macOS, drag-driven on iOS. Adapted from VideoTag's
//  `SkimFrameProvider`, sourcing frames from a short-lived presigned R2 stream
//  URL rather than a local file (R2 egress is free). One `AVAssetImageGenerator`
//  per clip, reused across positions.
//

import AVFoundation
import Foundation

@MainActor
public final class SkimProvider {
    /// Number of frames sampled across the card width.
    public static let stepCount = 30

    /// `AVAssetImageGenerator` is thread-safe for frame extraction but not
    /// `Sendable`. Boxing it lets us cache it on the main actor yet hand it to the
    /// nonisolated `image(at:)` API without tripping Swift 6 sending checks.
    private struct GeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator
    }

    private let storage: StorageService
    private var generators: [UUID: GeneratorBox] = [:]
    private let cache = NSCache<NSString, PlatformImage>()

    public init(storage: StorageService = StorageService()) {
        self.storage = storage
        cache.countLimit = 1500
    }

    /// Quantizes a hover/drag fraction (0...1) into a frame index, used as both
    /// cache key and SwiftUI task identity so each position generates at most once.
    public static func key(for fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * Double(stepCount - 1)).rounded())
    }

    public static func fraction(forKey key: Int) -> Double {
        Double(key) / Double(stepCount - 1)
    }

    public func frame(for clip: Clip, key: Int) async -> PlatformImage? {
        guard let duration = clip.durationS, duration > 0 else { return nil }

        let cacheKey = "\(clip.id)-\(key)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let box = await generator(for: clip) else { return nil }
        let time = CMTime(seconds: Self.fraction(forKey: key) * duration, preferredTimescale: 600)
        guard let raw = await Self.extract(box, at: time) else { return nil }

        let image = PlatformImage.from(cgImage: raw)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Off-actor frame extraction. `box` is `Sendable`, so handing it to this
    /// nonisolated function (and calling the generator's async API here) is safe.
    private nonisolated static func extract(_ box: GeneratorBox, at time: CMTime) async -> CGImage? {
        try? await box.generator.image(at: time).image
    }

    private func generator(for clip: Clip) async -> GeneratorBox? {
        if let existing = generators[clip.id] { return existing }

        // Bound memory across a long session of scrubbing many clips.
        if generators.count > 40 { generators.removeAll() }

        guard let url = try? await storage.streamURL(clipId: clip.id) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let box = GeneratorBox(generator: generator)
        generators[clip.id] = box
        return box
    }
}
