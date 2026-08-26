//
//  Notifications.swift
//  BetterContentLibrary (iOS)
//
//  Push registration (token upload) and the deep-link target a tapped "time to
//  post" notification routes to.
//

import Foundation
import UIKit
import UserNotifications
import BetterContentCore

/// Where a tapped notification wants the app to navigate. Observed by the tab
/// shell + schedule screen so a tap opens the relevant day's post card.
@MainActor
@Observable
final class DeepLinkCenter {
    static let shared = DeepLinkCenter()
    /// The calendar day to open in the Schedule tab (set from a notification tap).
    var scheduleDay: Date?
    /// An org invite code from a `bettercontent://join` link, waiting for the
    /// join sheet (cleared when the sheet is dismissed).
    var joinCode: String?
}

/// Requests notification permission, registers for remote notifications, and
/// keeps the device's APNs token synced to the backend `devices` table.
@MainActor
@Observable
final class PushManager {
    static let shared = PushManager()

    private let devices = DevicesService()
    private var profile: Profile?
    private(set) var deviceToken: String?
    /// The in-flight upload, so overlapping triggers (activate + the APNs
    /// callback, or a retry still backing off) don't stack duplicate upserts.
    private var uploadTask: Task<Void, Never>?

    /// Call once the signed-in user is known: ask permission, register for APNs,
    /// and upload the token (now, or when it arrives).
    func activate(for profile: Profile) {
        self.profile = profile
        uploadIfPossible()
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called from the app delegate when APNs hands us a device token.
    func didRegister(tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02x", $0) }.joined()
        uploadIfPossible()
    }

    /// Uploads the token once both halves are known (the APNs callback and
    /// sign-in race, in either order), retrying on failure.
    ///
    /// The retry matters: the backend can only reach this device while a row
    /// exists in `devices`, and nothing else re-attempts the upsert until the
    /// next cold launch. A single upload dropped on a flaky network used to
    /// mean no pushes for the rest of the session.
    private func uploadIfPossible() {
        guard let profile, let token = deviceToken else { return }
        let (profileId, orgId, environment) = (profile.id, profile.orgId, Self.environment)
        uploadTask?.cancel()
        uploadTask = Task { [devices] in
            for (attempt, delay) in Self.uploadRetryDelays.enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                do {
                    try await devices.register(
                        token: token,
                        profileId: profileId,
                        orgId: orgId,
                        environment: environment
                    )
                    return
                } catch {
                    if attempt == Self.uploadRetryDelays.count - 1 {
                        print("APNs token upload failed \(attempt + 1)x; retrying on next launch: \(error)")
                    }
                }
            }
        }
    }

    /// How long to wait before each attempt — the first goes out immediately,
    /// the rest back off. Worth riding out a spell of bad connectivity here
    /// rather than leaving the device unreachable until the app is relaunched.
    private static let uploadRetryDelays: [Int] = [0, 2, 8, 30, 120]

    /// Which APNs gateway this device's token belongs to — "sandbox" or
    /// "production". This is decided by the build's `aps-environment`
    /// entitlement (i.e. the provisioning profile it was signed with), NOT the
    /// Debug/Release config: a Release build signed with a development profile
    /// still mints a *sandbox* token, so `#if DEBUG` gets it wrong and the
    /// server ends up posting to the wrong gateway. Read the real value from
    /// the embedded provisioning profile instead.
    static var environment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is CMS-signed binary, but the embedded plist is
              // plain text; ISO Latin-1 decodes every byte without throwing.
              let text = String(data: data, encoding: .isoLatin1),
              let range = text.range(of: "<key>aps-environment</key>") else {
            // No embedded profile => App Store / TestFlight build => production.
            return "production"
        }
        let after = text[range.upperBound...]
        guard let open = after.range(of: "<string>"),
              let close = after.range(of: "</string>") else {
            return "production"
        }
        return after[open.upperBound..<close.lowerBound] == "development" ? "sandbox" : "production"
        #endif
    }
}
