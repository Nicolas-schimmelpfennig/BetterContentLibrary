import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Shared BCL components used by both apps — the pieces the design doc keeps
// identical across macOS and iOS: brand mark, status chips/dots, platform
// monogram badges, and the determinate upload ring.

// MARK: - Brand mark

/// The BCL mark: a stack of clips, top one "live" in accent blue — the
/// pipeline surfacing the next post.
public struct BrandMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 76) { self.size = size }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x22222A), Color(hex: 0x0F0F13)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: size * 0.16, y: size * 0.08)
            VStack(spacing: size * 0.066) {
                bar(width: 0.47, color: BCLTheme.accent)
                    .shadow(color: BCLTheme.accent.opacity(0.45), radius: size * 0.06, y: 2)
                bar(width: 0.37, color: BCLTheme.textPrimary.opacity(0.35))
                bar(width: 0.28, color: BCLTheme.textPrimary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
    }

    private func bar(width fraction: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
            .fill(color)
            .frame(width: size * fraction, height: size * 0.118)
    }
}

// MARK: - Status chip & dot

/// Filled status pill: hue at 14% alpha with the hue as text — grid cards and
/// detail views. List rows and calendar chips use `StatusDot` instead.
public struct StatusChip: View {
    private let status: ClipDisplayStatus
    private let compact: Bool

    public init(_ status: ClipDisplayStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(status.label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .foregroundStyle(status.color)
        .padding(.leading, compact ? 6 : 8)
        .padding(.trailing, compact ? 8 : 10)
        .padding(.vertical, compact ? 2 : 3)
        .background(status.color.opacity(0.14), in: Capsule())
    }
}

/// Quiet status marker for dense rows: dot only, word optional.
public struct StatusDot: View {
    private let color: Color
    private let size: CGFloat

    public init(_ status: ClipDisplayStatus, size: CGFloat = 7) {
        self.color = status.color
        self.size = size
    }

    public init(color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Platform badge

/// 16px monogram square (IG / TT / YT …) — the platform mark at chip size.
public struct PlatformBadge: View {
    private let platform: Platform
    private let size: CGFloat

    public init(_ platform: Platform, size: CGFloat = 16) {
        self.platform = platform
        self.size = size
    }

    public var body: some View {
        Text(platform.monogram)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(platform.monogramForeground)
            .frame(width: size, height: size)
            .background(
                platform.brandColor,
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
    }
}

/// Platform pill: monogram + name on a raised capsule.
public struct PlatformChip: View {
    private let platform: Platform

    public init(_ platform: Platform) { self.platform = platform }

    public var body: some View {
        HStack(spacing: 6) {
            PlatformBadge(platform)
            Text(platform.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BCLTheme.textPrimary)
        }
        .padding(.leading, 4)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(BCLTheme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(BCLTheme.hairline, lineWidth: 1))
    }
}

// MARK: - Upload ring

/// Determinate progress ring in accent blue — "uploading anywhere" per the
/// design's status row; percent lives in tooltips/detail text, not the ring.
public struct UploadRing: View {
    private let fraction: Double
    private let size: CGFloat

    public init(fraction: Double, size: CGFloat = 14) {
        self.fraction = fraction
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(BCLTheme.accent.opacity(0.25), lineWidth: size * 0.14)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(BCLTheme.accent, style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

// MARK: - Menu-safe status dot

public extension Image {
    /// A filled circle baked into a real bitmap and marked non-template, for
    /// use as a `Label` icon inside a `Menu`/`Picker`. Plain
    /// `Image(systemName: "circle.fill").foregroundStyle(color)` renders fine
    /// in ordinary views, but both AppKit and UIKit re-tint menu item icons
    /// to the menu's own text color by default — so any hue set via
    /// `foregroundStyle` is silently dropped once the same icon sits inside a
    /// menu. Baking the color into the pixels (and disabling template mode)
    /// is what actually survives there.
    static func statusDot(_ color: Color, diameter: CGFloat = 10) -> Image {
        #if canImport(AppKit)
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
        #elseif canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
        let image = renderer.image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
        #endif
    }
}

// MARK: - Formatting helpers

public enum BCLFormat {
    /// `12:34` / `1:02:07` — durations are always mono in the UI.
    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func fileSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "–" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func dimensions(_ clip: Clip) -> String {
        guard let w = clip.width, let h = clip.height else { return "–" }
        return "\(w)×\(h)"
    }
}
