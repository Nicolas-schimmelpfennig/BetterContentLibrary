//
//  SettingsScreen.swift
//  BetterContentLibrary (iOS)
//
//  Grouped-list settings (design 1q). The notification row surfaces the
//  permission state inline, with a deep link to iOS Settings when it's off —
//  push is the product's core loop, so its health belongs here.
//

import SwiftUI
import UserNotifications
import BetterContentCore

struct SettingsScreen: View {
    let model: AppModel
    @Environment(AuthService.self) private var auth
    @AppStorage(SettingsKey.videoSkimming) private var videoSkimming = true
    @State private var notificationsAllowed: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section("Posting") {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        switch notificationsAllowed {
                        case .some(true):
                            HStack(spacing: 5) {
                                StatusDot(color: ClipDisplayStatus.ready.color, size: 7)
                                Text("Allowed")
                                    .foregroundStyle(BCLTheme.textSecondary)
                            }
                        case .some(false):
                            Button {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    StatusDot(color: BCLTheme.error, size: 7)
                                    Text("Off — enable in Settings")
                                        .foregroundStyle(BCLTheme.errorText)
                                }
                            }
                        case nil:
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                Section("Library") {
                    Toggle(isOn: $videoSkimming) {
                        Text("Video skimming")
                        Text("Drag across a clip's thumbnail to scrub through it. Turn off to show only the poster frame.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Account") {
                    LabeledContent("Name", value: auth.currentProfile?.displayName ?? "—")
                    LabeledContent("Role", value: auth.currentProfile?.role.rawValue.capitalized ?? "—")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { try? await auth.signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await refreshNotificationState() }
        }
    }

    private func refreshNotificationState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }
}
