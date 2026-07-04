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
    private let cache = NSCache<NSString, PlatformImage>()

    /// Live generators, bounded to `maxGenerators` with real least-recently-used
    /// eviction (oldest single entry dropped, not the whole cache) so a long
    /// scrubbing session doesn't keep re-paying the open cost for clips the
    /// user is still going back to.
    private var generators: [UUID: GeneratorBox] = [:]
    private var generatorOrder: [UUID] = []
    private static let maxGenerators = 40

    /// In-flight generator builds, keyed by clip, so a `warm(for:)` prefetch
    /// and a real `frame(for:key:)` call racing for the same clip share one
    /// network fetch instead of firing it twice.
    private var pending: [UUID: Task<GeneratorBox?, Never>] = [:]

    /// The presigned stream URL is valid for an hour server-side (see
    /// `r2-sign`); cache comfortably inside that window so replaying or
    /// re-skimming a clip later in the session skips the round trip (auth +
    /// a DB lookup + presigning) that otherwise gates the very first frame.
    private var streamURLs: [UUID: (url: URL, expiresAt: Date)] = [:]
    private static let urlLifetime: TimeInterval = 45 * 60

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

    /// Resolves the clip's stream URL and spins up its generator ahead of any
    /// actual scrubbing, so the network round-trip (presign) and the remote
    /// container open (parsing the asset's track/duration atoms) are already
    /// done by the time the user hovers or drags. Called as soon as a card
    /// appears; extracts no frame, so it's cheap to call speculatively.
    public func warm(for clip: Clip) async {
        guard let duration = clip.durationS, duration > 0 else { return }
        _ = await generator(for: clip)
    }

    /// Off-actor frame extraction. `box` is `Sendable`, so handing it to this
    /// nonisolated function (and calling the generator's async API here) is safe.
    private nonisolated static func extract(_ box: GeneratorBox, at time: CMTime) async -> CGImage? {
        try? await box.generator.image(at: time).image
    }

    private func generator(for clip: Clip) async -> GeneratorBox? {
        if let existing = generators[clip.id] {
            touch(clip.id)
            return existing
        }
        if let pending = pending[clip.id] {
            return await pending.value
        }

        let task = Task<GeneratorBox?, Never> { [weak self] in
            guard let self, let url = await self.streamURL(for: clip) else { return nil }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let box = GeneratorBox(generator: generator)
            self.store(box, for: clip.id)

            // Front-load parsing the remote container so the first real seek
            // only pays for decode, not for opening the asset too. Not
            // awaited: `AVAsset` isn't `Sendable`, so this stays on the actor
            // (cheap — the actual I/O happens off-thread inside AVFoundation)
            // and simply lets the metadata resolve in the background.
            Task(priority: .utility) { _ = try? await asset.load(.tracks, .duration) }
            return box
        }
        pending[clip.id] = task
        let result = await task.value
        pending[clip.id] = nil
        return result
    }

    /// Resolves (and caches) a clip's presigned stream URL, skipping the
    /// network round-trip while a previously issued URL is still fresh.
    private func streamURL(for clip: Clip) async -> URL? {
        if let cached = streamURLs[clip.id], cached.expiresAt > Date() {
            return cached.url
        }
        guard let url = try? await storage.streamURL(clipId: clip.id) else { return nil }
        streamURLs[clip.id] = (url, Date().addingTimeInterval(Self.urlLifetime))
        return url
    }

    private func store(_ box: GeneratorBox, for id: UUID) {
        generators[id] = box
        generatorOrder.removeAll { $0 == id }
        generatorOrder.append(id)
        while generatorOrder.count > Self.maxGenerators {
            generators[generatorOrder.removeFirst()] = nil
        }
    }

    private func touch(_ id: UUID) {
        guard let idx = generatorOrder.firstIndex(of: id) else { return }
        generatorOrder.remove(at: idx)
        generatorOrder.append(id)
    }
}
