//
//  SettingsScreen.swift
//  BetterContentLibrary (iOS)
//

import SwiftUI
import BetterContentCore

struct SettingsScreen: View {
    let model: AppModel
    @Environment(AuthService.self) private var auth
    @AppStorage(SettingsKey.videoSkimming) private var videoSkimming = true

    var body: some View {
        NavigationStack {
            Form {
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
                } footer: {
                    Text(AppVersion.display)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
