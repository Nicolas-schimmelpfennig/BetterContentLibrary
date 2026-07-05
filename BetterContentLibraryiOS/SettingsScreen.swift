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
    @AppStorage(SettingsKey.storageLimitGBR2) private var r2LimitGB = StorageProvider.defaultLimitGB
    @AppStorage(SettingsKey.storageLimitGBICloud) private var iCloudLimitGB = StorageProvider.defaultLimitGB
    @AppStorage(SettingsKey.evictionOrder) private var evictionOrderRaw
        = EvictionCategory.serialize(EvictionCategory.defaultOrder)

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

                Section {
                    Stepper("BetterContent Cloud: \(r2LimitGB) GB", value: $r2LimitGB, in: 1...2000)
                    Stepper("iCloud Drive: \(iCloudLimitGB) GB", value: $iCloudLimitGB, in: 1...2000)
                } header: {
                    Text("Storage Limits")
                } footer: {
                    Text("When a new upload would go over a provider's limit, older clips are removed automatically per the order below — or the upload is refused if the allowed categories can't free enough.")
                }

                Section {
                    ForEach(Array(enabledEvictionOrder.enumerated()), id: \.element) { index, category in
                        HStack(spacing: 10) {
                            Toggle("", isOn: evictionBinding(category)).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(index + 1). \(category.displayName)")
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { moveEviction(category, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                            Button { moveEviction(category, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled(index == enabledEvictionOrder.count - 1)
                        }
                    }
                    ForEach(disabledEvictionCategories) { category in
                        HStack(spacing: 10) {
                            Toggle("", isOn: evictionBinding(category)).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(category.displayName).foregroundStyle(.secondary)
                                Text("Never removed automatically").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Text("Automatically Remove, in This Order")
                } footer: {
                    Text("Within each category the oldest clips go first. Clips with an upcoming scheduled post are never removed automatically.")
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

    // MARK: Auto-removal chain editing

    private var enabledEvictionOrder: [EvictionCategory] {
        EvictionCategory.order(from: evictionOrderRaw)
    }

    private var disabledEvictionCategories: [EvictionCategory] {
        EvictionCategory.allCases.filter { !enabledEvictionOrder.contains($0) }
    }

    private func evictionBinding(_ category: EvictionCategory) -> Binding<Bool> {
        Binding {
            enabledEvictionOrder.contains(category)
        } set: { on in
            var order = enabledEvictionOrder
            if on {
                if !order.contains(category) { order.append(category) }
            } else {
                order.removeAll { $0 == category }
            }
            evictionOrderRaw = EvictionCategory.serialize(order)
        }
    }

    private func moveEviction(_ category: EvictionCategory, by delta: Int) {
        var order = enabledEvictionOrder
        guard let index = order.firstIndex(of: category) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        evictionOrderRaw = EvictionCategory.serialize(order)
    }
}
