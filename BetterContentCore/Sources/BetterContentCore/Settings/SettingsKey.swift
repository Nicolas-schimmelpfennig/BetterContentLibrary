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
}
