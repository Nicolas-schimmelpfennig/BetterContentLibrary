//
//  NotificationSettingsSection.swift
//  BetterContentLibrary (iOS)
//
//  Settings → Notifications: what iOS will actually let through for this app,
//  plus an end-to-end test push. "Pushes don't arrive" has several causes that
//  look identical from the outside (permission off, Focus/Scheduled Summary
//  holding them, a stale token on the server); this section tells them apart.
//

import SwiftUI
import UserNotifications
import BetterContentCore

struct NotificationSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var settings: UNNotificationSettings?
    @State private var testing = false
    @State private var results: [DevicePushCheck]?
    @State private var testError: String?

    var body: some View {
        Section {
            LabeledContent("Notifications", value: authorizationLabel)

            if settings?.authorizationStatus == .authorized {
                LabeledContent("Time Sensitive", value: timeSensitiveLabel)
                if settings?.scheduledDeliverySetting == .enabled {
                    LabeledContent("Scheduled Summary", value: "On")
                }
            }

            if needsSystemSettings {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }

            Button {
                runTest()
            } label: {
                HStack {
                    Text("Send Test Notification")
                    if testing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(testing)

            if let testError {
                Text(testError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let results {
                if results.isEmpty {
                    Label("No device is registered for your account. Reopen the app with notifications allowed, then try again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footerText)
        }
        .task { await reloadSettings() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reloadSettings() } }
        }
    }

    // MARK: Rows

    private func resultRow(_ result: DevicePushCheck) -> some View {
        let isThisDevice = result.installId == InstallID.value
        let name = isThisDevice ? "This \(UIDevice.current.model)" : "Other device"
        return VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(name)
            } icon: {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red)
            }
            Group {
                if result.ok {
                    Text("Accepted by Apple (\(result.gateway)). It should appear within seconds.")
                } else if result.removed {
                    Text("Apple no longer recognizes this device — removed.")
                } else {
                    Text("Rejected: \(result.reason ?? "HTTP \(result.status)")")
                }
                if let at = result.registeredAt, !isThisDevice {
                    Text("Last checked in \(at.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Labels

    private var authorizationLabel: String {
        switch settings?.authorizationStatus {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .notDetermined: return "Not asked yet"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Allowed"
        case nil: return "…"
        @unknown default: return "Unknown"
        }
    }

    private var timeSensitiveLabel: String {
        switch settings?.timeSensitiveSetting {
        case .enabled: return "On"
        case .disabled: return "Off"
        default: return "Not available"
        }
    }

    private var needsSystemSettings: Bool {
        guard let settings else { return false }
        return settings.authorizationStatus == .denied
            || settings.authorizationStatus == .provisional
            || settings.timeSensitiveSetting == .disabled
    }

    private var footerText: String {
        var text = "Post reminders arrive 15 minutes before a post and again at post time."
        if settings?.authorizationStatus == .denied {
            text += " Notifications are off for this app, so none will arrive — turn them on in iOS Settings."
        } else if settings?.timeSensitiveSetting == .disabled {
            text += " Turn on Time Sensitive so a Focus or the Scheduled Summary can't hold them back."
        }
        return text
    }

    // MARK: Actions

    private func reloadSettings() async {
        settings = await UNUserNotificationCenter.current().notificationSettings()
    }

    private func runTest() {
        testing = true
        testError = nil
        results = nil
        Task {
            do {
                results = try await PushManager.shared.sendTest()
            } catch {
                testError = "Couldn't send the test: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
