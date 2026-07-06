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

    private func uploadIfPossible() {
        guard let profile, let token = deviceToken else { return }
        let environment = Self.environment
        Task {
            try? await devices.register(
                token: token,
                profileId: profile.id,
                orgId: profile.orgId,
                environment: environment
            )
        }
    }

    /// Dev builds talk to APNs sandbox; release builds to production.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
