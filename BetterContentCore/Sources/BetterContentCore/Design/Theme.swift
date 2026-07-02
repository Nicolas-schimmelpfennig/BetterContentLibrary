import SwiftUI

/// BCL design tokens (dark appearance — the app's primary and, for now, only
/// mode). Source of truth: the "BetterContentLibrary UI" design doc, section 1a.
///
/// Five dark surfaces in a fixed stacking order; depth comes from lightness
/// steps and 1px hairlines, never heavy shadows. One blue accent; the status
/// lifecycle is the loudest color system in the app.
public enum BCLTheme {
    // MARK: Surfaces (dark)

    /// Darkest — thumbnail wells, canvas behind letterboxed media.
    public static let well = Color(hex: 0x0E0E11)
    public static let sidebar = Color(hex: 0x141418)
    public static let content = Color(hex: 0x1B1B20)
    /// Cards, sheets, folder tiles.
    public static let raised = Color(hex: 0x232329)
    /// Buttons, pickers, inputs.
    public static let control = Color(hex: 0x2A2A31)

    // MARK: Text

    public static let textPrimary = Color(hex: 0xECECF1)
    public static let textSecondary = textPrimary.opacity(0.55)
    public static let textTertiary = textPrimary.opacity(0.32)
    /// Section headers, field labels (between secondary and tertiary).
    public static let textLabel = textPrimary.opacity(0.45)

    // MARK: Lines & accents

    /// 1px hairline separators and card borders.
    public static let hairline = Color.white.opacity(0.07)
    /// Stronger border for inputs and hovered controls.
    public static let border = Color.white.opacity(0.12)
    /// The one accent — selection, focus, primary buttons, links, uploading.
    public static let accent = Color(hex: 0x4E9CF7)
    /// Lighter accent for text on accent-tinted surfaces.
    public static let accentText = Color(hex: 0x9CC4F8)
    public static let errorText = Color(hex: 0xFF7B74)
    public static let error = Color(hex: 0xFF5F57)

    // MARK: Radii (r4 badge · r6 control · r8 card/thumb · r12 sheet)

    public static let radiusBadge: CGFloat = 4
    public static let radiusControl: CGFloat = 6
    public static let radiusCard: CGFloat = 8
    public static let radiusSheet: CGFloat = 12
}

public extension Color {
    /// `Color(hex: 0x4E9CF7)` — design-token literals.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Status language

/// What a clip's badge should say — the transfer state (`ClipStatus`) merged
/// with the presentation states derived from its schedules. Six hues share one
/// lightness so no state shouts over another.
public enum ClipDisplayStatus: String, Sendable, CaseIterable {
    case ingesting
    case uploading
    case ready
    case scheduled
    case downloaded
    case posted
    case failed

    /// Derives the display status: transfer states win; a ready clip reads as
    /// scheduled while any planned schedule exists, and posted once it has
    /// been posted somewhere with nothing left planned.
    public static func derive(clip: Clip, schedules: [Schedule]) -> ClipDisplayStatus {
        switch clip.status {
        case .ingesting: return .ingesting
        case .uploading: return .uploading
        case .failed: return .failed
        case .ready:
            if schedules.contains(where: { $0.status == .planned }) { return .scheduled }
            if schedules.contains(where: { $0.status == .posted }) { return .posted }
            return .ready
        }
    }

    public var label: String {
        switch self {
        case .ingesting: return "Ingesting"
        case .uploading: return "Uploading"
        case .ready: return "Ready"
        case .scheduled: return "Scheduled"
        case .downloaded: return "Downloaded"
        case .posted: return "Posted"
        case .failed: return "Failed"
        }
    }

    public var color: Color {
        switch self {
        case .ingesting: return Color(hex: 0x9A9AA3)
        case .uploading: return BCLTheme.accent
        case .ready: return Color(hex: 0x45C36F)
        case .scheduled: return Color(hex: 0xE3A94F)
        case .downloaded: return Color(hex: 0xA98BF5)
        case .posted: return Color(hex: 0x38BFAF)
        case .failed: return BCLTheme.error
        }
    }
}

public extension ScheduleStatus {
    /// planned = amber · posted = teal · skipped = gray (strike in text).
    var color: Color {
        switch self {
        case .planned: return ClipDisplayStatus.scheduled.color
        case .posted: return ClipDisplayStatus.posted.color
        case .skipped: return Color(hex: 0x9A9AA3)
        }
    }
}

// MARK: - Platform language

public extension Platform {
    var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .youtubeShorts: return "YT Shorts"
        case .x: return "X"
        case .facebook: return "Facebook"
        case .linkedin: return "LinkedIn"
        case .other: return "Other"
        }
    }

    /// 2-letter monogram for the 16px platform squares — recognizable at chip
    /// size without trademark glyphs.
    var monogram: String {
        switch self {
        case .instagram: return "IG"
        case .tiktok: return "TT"
        case .youtube: return "YT"
        case .youtubeShorts: return "YS"
        case .x: return "X"
        case .facebook: return "FB"
        case .linkedin: return "LI"
        case .other: return "•"
        }
    }

    var brandColor: Color {
        switch self {
        case .instagram: return Color(hex: 0xE1306C)
        case .tiktok: return Color(hex: 0x5FD5D9)
        case .youtube, .youtubeShorts: return Color(hex: 0xFF4438)
        case .x: return Color(hex: 0x16181C)
        case .facebook: return Color(hex: 0x1877F2)
        case .linkedin: return Color(hex: 0x0A66C2)
        case .other: return Color(hex: 0x6E6E76)
        }
    }

    /// Text color that stays legible on `brandColor`.
    var monogramForeground: Color {
        switch self {
        case .tiktok: return Color(hex: 0x08282A)
        default: return .white
        }
    }
}
