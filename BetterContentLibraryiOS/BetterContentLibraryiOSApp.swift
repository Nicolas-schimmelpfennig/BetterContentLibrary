//
//  BetterContentLibraryiOSApp.swift
//  BetterContentLibrary (iOS)
//

import SwiftUI
import UserNotifications
import BetterContentCore

@main
struct BetterContentLibraryiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.start() }
                .preferredColorScheme(.dark)   // dark-first product; light ships later
                .tint(BCLTheme.accent)
        }
    }
}

/// Bridges UIKit app-delegate callbacks the SwiftUI lifecycle doesn't expose:
/// the background `URLSession` completion handoff, APNs token registration, and
/// notification taps (which deep-link into the relevant scheduled post).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Force the shared uploader to exist so its delegate is attached before
        // the system replays any completed background transfers.
        _ = BackgroundUploadService.shared
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit's handler isn't `Sendable`-annotated but is safe to store and
        // invoke later on the main thread; box it to cross the boundary cleanly.
        let box = UncheckedSendableBox(completionHandler)
        BackgroundUploadService.shared.backgroundCompletionHandler = { box.value() }
    }

    // MARK: APNs registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushManager.shared.didRegister(tokenData: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: Notification presentation + taps

    /// Show the alert even when the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tapping a notification routes to the scheduled post's day.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let iso = info["scheduled_at"] as? String,
           let date = Self.isoFormatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            DeepLinkCenter.shared.scheduleDay = date
        }
        completionHandler()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Vouches for the safety of moving a value across a `Sendable` boundary.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

