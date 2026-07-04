//
//  AppVersion.swift
//  BetterContentCore
//
//  The host app's version, for display (Settings footer). Releases carry a
//  human-facing marketing version like "0.1-alpha" plus a date-derived build
//  number that Sparkle compares (see scripts/release-macos.sh).
//

import Foundation

public enum AppVersion {
    /// CFBundleShortVersionString — e.g. "0.1-alpha".
    public static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// CFBundleVersion — e.g. "20260704.1930" for releases, "1" in dev builds.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// The Settings-footer string: "v0.1-alpha (20260704.1930)".
    public static var display: String {
        "v\(marketing) (\(build))"
    }
}
