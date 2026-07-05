//
//  SettingsKey.swift
//  BetterContentCore
//
//  Shared `@AppStorage` keys for user preferences, so every platform's settings
//  UI and the views that read them stay on the same string literal.
//

import Foundation

public enum SettingsKey {
    /// When false, library cards show only the static poster (no hover/drag scrub).
    public static let videoSkimming = "videoSkimmingEnabled"

    /// Visibility of the two macOS main-window panes. At least one stays
    /// visible — the toggles re-show the other instead of blanking the window.
    public static let showLibraryPane = "showLibraryPane"
    public static let showSchedulePane = "showSchedulePane"

    /// Single bare keys that toggle the panes when no text field has focus
    /// (macOS; defaults "l" / "s", editable in Settings → General).
    public static let libraryPaneShortcut = "libraryPaneShortcut"
    public static let schedulePaneShortcut = "schedulePaneShortcut"

    /// The library pane's share of the split when both panes show (macOS).
    public static let mainSplitFraction = "mainSplitFraction"

    /// Comma-joined raw values of platforms the user has hidden from the
    /// scheduling UI (Settings → Platforms). Stored as the *hidden* set so a
    /// platform added in a future version shows up by default.
    public static let hiddenPlatforms = "hiddenPlatforms"

    /// `StorageProvider` raw value that NEW uploads go to (device-level;
    /// existing clips keep playing from wherever their bytes already live).
    public static let storageProvider = "storageProvider"
}

public extension Platform {
    /// The platforms the scheduling UI should offer, given the raw
    /// `SettingsKey.hiddenPlatforms` value. Falls back to all platforms if
    /// somehow every one is hidden, so scheduling never dead-ends.
    static func visible(hiddenRaw: String) -> [Platform] {
        let hidden = Set(hiddenRaw.split(separator: ",").map(String.init))
        let visible = allCases.filter { !hidden.contains($0.rawValue) }
        return visible.isEmpty ? allCases : visible
    }
}
