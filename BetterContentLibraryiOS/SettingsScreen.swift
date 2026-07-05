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
    @AppStorage(SettingsKey.storageProvider) private var storageProviderRaw = StorageProvider.r2.rawValue

    private var storageProvider: StorageProvider {
        StorageProvider(rawValue: storageProviderRaw) ?? .r2
    }

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

                Section {
                    Picker("Store new uploads in", selection: storageProviderBinding) {
                        Text("BetterContent Cloud").tag(StorageProvider.r2)
                        Text("iCloud Drive").tag(StorageProvider.iCloudDrive)
                        Text("Google Drive (soon)").tag(StorageProvider.googleDrive)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(storageProvider == .iCloudDrive
                         ? "New uploads go to your iCloud Drive and count against your iCloud plan; only devices signed into your Apple ID can play them. Existing clips keep playing from where they are."
                         : "Applies to new uploads only — existing clips keep playing from where they are.")
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

    /// Google Drive is visible but not selectable yet (backend lands later).
    private var storageProviderBinding: Binding<StorageProvider> {
        Binding {
            storageProvider
        } set: { newValue in
            guard newValue != .googleDrive else { return }
            storageProviderRaw = newValue.rawValue
        }
    }
}
