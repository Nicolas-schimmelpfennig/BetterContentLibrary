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
import Security
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
    /// What the backend last confirmed, so foreground refreshes only re-upload
    /// when something changed (or the confirmation is getting old).
    private var lastUploaded: (token: String, profileId: UUID, at: Date)?

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

    /// Call whenever the app comes to the foreground. The token used to be
    /// uploaded only at cold launch, but iOS keeps an app suspended for days
    /// or weeks — so a token that changed in the meantime (OS update, restore)
    /// left the backend pushing to a dead token until the next cold launch.
    /// Re-registering is cheap: APNs hands back the current token, and the
    /// upload is skipped unless it changed or wasn't confirmed recently.
    func refresh() {
        guard profile != nil else { return }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Call before signing out: stops this phone getting the old account's
    /// post reminders (the row would otherwise outlive the session).
    func deactivate() async {
        uploadTask?.cancel()
        uploadTask = nil
        profile = nil
        lastUploaded = nil
        try? await devices.unregister(installId: InstallID.value)
    }

    /// Called from the app delegate when APNs hands us a device token.
    func didRegister(tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02x", $0) }.joined()
        uploadIfPossible()
    }

    /// Pushes a test notification through the real pipeline (edge function →
    /// APNs) to every device registered for this account.
    func sendTest() async throws -> [DevicePushCheck] {
        try await devices.sendTestPush()
    }

    /// Uploads the token once both halves are known (the APNs callback and
    /// sign-in race, in either order), retrying on failure.
    ///
    /// The retry matters: the backend can only reach this device while a row
    /// exists in `devices`, and nothing else re-attempts the upsert until the
    /// app next comes to the foreground.
    private func uploadIfPossible() {
        guard let profile, let token = deviceToken else { return }
        if let last = lastUploaded, last.token == token, last.profileId == profile.id,
           Date().timeIntervalSince(last.at) < Self.reconfirmInterval {
            return
        }
        let (profileId, environment, installId) = (profile.id, Self.environment, InstallID.value)
        uploadTask?.cancel()
        uploadTask = Task { [weak self, devices] in
            for (attempt, delay) in Self.uploadRetryDelays.enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                do {
                    try await devices.register(installId: installId, token: token, environment: environment)
                    self?.lastUploaded = (token, profileId, Date())
                    return
                } catch {
                    if attempt == Self.uploadRetryDelays.count - 1 {
                        print("APNs token upload failed \(attempt + 1)x; retrying next foreground: \(error)")
                    }
                }
            }
        }
    }

    /// How long to wait before each attempt — the first goes out immediately,
    /// the rest back off. Worth riding out a spell of bad connectivity here
    /// rather than leaving the device unreachable until the app is relaunched.
    private static let uploadRetryDelays: [Int] = [0, 2, 8, 30, 120]

    /// An unchanged token is still re-confirmed this often, so the row's
    /// `updated_at` shows the install is alive and a row deleted server-side
    /// (dead-token cleanup misfiring, a sign-out elsewhere) comes back.
    private static let reconfirmInterval: TimeInterval = 6 * 3600

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

/// A stable id for this app install, kept in the Keychain so it survives
/// reinstalls (Keychain items outlive the app on iOS) — which is what lets the
/// backend replace a reinstalled phone's old token row instead of keeping it
/// alongside the new one. Falls back to `identifierForVendor`.
enum InstallID {
    private static let service = "Nicolas.BetterContentLibrary.install"
    private static let account = "install-id"

    @MainActor static var value: String {
        if let cached { return cached }
        let id = read() ?? {
            let fresh = UUID().uuidString
            write(fresh)
            return read() ?? UIDevice.current.identifierForVendor?.uuidString ?? fresh
        }()
        cached = id
        return id
    }

    @MainActor private static var cached: String?

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ id: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.utf8),
            // This device only: an install id must not sync to another phone.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }
}
