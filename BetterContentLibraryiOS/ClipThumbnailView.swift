//
//  ClipThumbnailView.swift
//  BetterContentLibrary (iOS)
//
//  Poster thumbnail that scrubs ("skims") through the video on a horizontal
//  drag — the touch analog of the Mac's hover-skim. Same `SkimProvider`, gated
//  by the shared Settings toggle.
//

import SwiftUI
import BetterContentCore

struct ClipThumbnailView: View {
    let clip: Clip
    let loader: ThumbnailLoader
    let skim: SkimProvider
    /// Whether this clip can be skimmed at all (i.e. it's uploaded/playable).
    let skimEnabled: Bool

    @AppStorage(SettingsKey.videoSkimming) private var skimmingEnabled = true

    @State private var poster: UIImage?
    @State private var skimImage: UIImage?
    @State private var dragFraction: Double?
    @State private var width: CGFloat = 0

    private var canSkim: Bool { skimEnabled && skimmingEnabled }
    private var displayImage: UIImage? { skimImage ?? poster }

    private var skimKey: Int? {
        guard canSkim, let fraction = dragFraction, (clip.durationS ?? 0) > 0 else { return nil }
        return SkimProvider.key(for: fraction)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: orientationIcon)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            }
        }
        .overlay(alignment: .leading) { playhead }
        .contentShape(Rectangle())
        // Simultaneous + horizontal-dominant so vertical scrolling and taps keep working.
        .simultaneousGesture(skimGesture)
        // Reload the poster whenever the clip changes (e.g. after regenerate bumps updatedAt).
        .task(id: clip.updatedAt) { poster = await loader.image(for: clip) }
        // Keep the previous frame on a nil result to avoid flashing the poster.
        .task(id: skimKey) {
            guard let key = skimKey else { return }
            if let frame = await skim.frame(for: clip, key: key) { skimImage = frame }
        }
    }

    private var skimGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard canSkim, width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                dragFraction = min(max(value.location.x / width, 0), 1)
            }
            .onEnded { _ in
                dragFraction = nil
                skimImage = nil
            }
    }

    @ViewBuilder
    private var playhead: some View {
        if canSkim, let fraction = dragFraction, width > 0 {
            Rectangle()
                .fill(.white)
                .frame(width: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .offset(x: fraction * (width - 1.5))
        }
    }

    private var orientationIcon: String {
        switch clip.orientation {
        case .vertical: return "rectangle.portrait"
        case .horizontal: return "rectangle"
        case .square: return "square"
        case nil: return "film"
        }
    }
}
