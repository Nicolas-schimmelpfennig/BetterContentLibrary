//
//  SkimProvider.swift
//  BetterContentLibrary
//

import AppKit
import AVFoundation
import Foundation
import BetterContentCore

/// Generates and caches video frames for hover-scrubbing ("skimming") library
/// cards. Adapted from VideoTag's `SkimFrameProvider`, but sources frames from a
/// short-lived presigned R2 stream URL rather than a local file (R2 egress is
/// free). One `AVAssetImageGenerator` per clip, reused across positions.
@MainActor
final class SkimProvider {
    /// Number of frames sampled across the card width.
    static let stepCount = 30

    private let storage: StorageService
    private var generators: [UUID: AVAssetImageGenerator] = [:]
    private let cache = NSCache<NSString, NSImage>()

    init(storage: StorageService = StorageService()) {
        self.storage = storage
        cache.countLimit = 1500
    }

    /// Quantizes a hover fraction (0...1) into a frame index, used as both cache
    /// key and SwiftUI task identity so each position generates at most once.
    static func key(for fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * Double(stepCount - 1)).rounded())
    }

    static func fraction(forKey key: Int) -> Double {
        Double(key) / Double(stepCount - 1)
    }

    func frame(for clip: Clip, key: Int) async -> NSImage? {
        guard let duration = clip.durationS, duration > 0 else { return nil }

        let cacheKey = "\(clip.id)-\(key)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let generator = await generator(for: clip) else { return nil }
        let time = CMTime(seconds: Self.fraction(forKey: key) * duration, preferredTimescale: 600)
        guard let raw = try? await generator.image(at: time).image else { return nil }

        let image = NSImage(cgImage: raw, size: NSSize(width: raw.width, height: raw.height))
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private func generator(for clip: Clip) async -> AVAssetImageGenerator? {
        if let existing = generators[clip.id] { return existing }

        // Bound memory across a long session of hovering many clips.
        if generators.count > 40 { generators.removeAll() }

        guard let url = try? await storage.streamURL(clipId: clip.id) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generators[clip.id] = generator
        return generator
    }
}
