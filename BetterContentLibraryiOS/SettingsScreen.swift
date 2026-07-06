//
//  SettingsScreen.swift
//  BetterContentLibrary (iOS)
//

import SwiftUI
import BetterContentCore

struct SettingsScreen: View {
    let model: AppModel
    let profile: Profile

    @Environment(AuthService.self) private var auth
    @State private var org: OrgModel

    @AppStorage(SettingsKey.videoSkimming) private var videoSkimming = true
    @AppStorage(SettingsKey.storageProvider) private var storageProviderRaw = StorageProvider.r2.rawValue
    @AppStorage(SettingsKey.storageLimitGBICloud) private var iCloudLimitGB = StorageProvider.defaultLimitGB

    @State private var iCloudAvailable = false
    @State private var counts: [StorageProvider: Int] = [:]
    @State private var migrationTarget: StorageProvider = .r2
    @State private var showMigrationSheet = false

    init(model: AppModel, profile: Profile) {
        self.model = model
        self.profile = profile
        _org = State(initialValue: OrgModel(profile: profile))
    }

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
                    NavigationLink {
                        OrgScreen(profile: profile)
                    } label: {
                        LabeledContent("Organization", value: org.organization?.name ?? "")
                    }
                } footer: {
                    Text("Invite teammates, manage members, or join another organization.")
                }

                storageSection
                limitsSection
                evictionSection
                migrationSection

                Section("Account") {
                    LabeledContent("Name", value: auth.currentProfile?.displayName ?? "—")
                    LabeledContent("Role", value: auth.currentProfile?.role.displayLabel ?? "—")
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
            .onAppear { iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil }
            .task { await reload() }
            .sheet(isPresented: $showMigrationSheet, onDismiss: { Task { await reload() } }) {
                MigrationScreen(target: migrationTarget)
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            Picker("Store new uploads in", selection: storageProviderBinding) {
                Text("BetterContent Cloud").tag(StorageProvider.r2)
                Text(org.isMultiUser ? "iCloud Drive (single-user only)" : "iCloud Drive")
                    .tag(StorageProvider.iCloudDrive)
                    .selectionDisabled(org.isMultiUser)
                Text("Google Drive (soon)").tag(StorageProvider.googleDrive)
            }
        } header: {
            Text("Storage")
        } footer: {
            if org.isMultiUser {
                Text("Teams share BetterContent Cloud — clips in someone's iCloud Drive would only play on that person's devices. Applies to new uploads only.")
            } else if storageProvider == .iCloudDrive {
                Text("New uploads go to your iCloud Drive and count against your iCloud plan; only devices signed into your Apple ID can play them. Existing clips keep playing from where they are.")
            } else {
                Text("Applies to new uploads only — existing clips keep playing from where they are.")
            }
        }
    }

    private var limitsSection: some View {
        Section {
            if org.isAdmin {
                Stepper("BetterContent Cloud: \(org.organization?.storageLimitGB ?? StorageProvider.defaultLimitGB) GB",
                        value: orgLimitBinding, in: 1...2000)
            } else {
                LabeledContent("BetterContent Cloud",
                               value: "\(org.organization?.storageLimitGB ?? StorageProvider.defaultLimitGB) GB")
            }
            Stepper("iCloud Drive: \(iCloudLimitGB) GB", value: $iCloudLimitGB, in: 1...2000)
        } header: {
            Text("Storage Limits")
        } footer: {
            Text(org.isAdmin
                 ? "The BetterContent Cloud limit is shared by the whole organization. When a new upload would go over a limit, older clips are removed automatically per the order below — or the upload is refused if the allowed categories can't free enough."
                 : "The BetterContent Cloud limit is set by your admin and shared by the whole organization. The iCloud limit is yours alone.")
        }
    }

    private var orgLimitBinding: Binding<Int> {
        Binding {
            org.organization?.storageLimitGB ?? StorageProvider.defaultLimitGB
        } set: { newValue in
            Task { await org.setStorageLimitGB(newValue) }
        }
    }

    // MARK: Auto-removal chain (org policy)

    @ViewBuilder
    private var evictionSection: some View {
        Section {
            ForEach(Array(enabledEvictionOrder.enumerated()), id: \.element) { index, category in
                HStack(spacing: 10) {
                    if org.isAdmin {
                        Toggle("", isOn: evictionBinding(category)).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(category.displayName)")
                        Text(category.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if org.isAdmin {
                        Button { moveEviction(category, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { moveEviction(category, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == enabledEvictionOrder.count - 1)
                    }
                }
            }
            ForEach(disabledEvictionCategories) { category in
                HStack(spacing: 10) {
                    if org.isAdmin {
                        Toggle("", isOn: evictionBinding(category)).labelsHidden()
                    }
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
            Text(org.isAdmin
                 ? "Organization-wide policy. Within each category the oldest clips go first. Clips with an upcoming scheduled post are never removed automatically."
                 : "Set by your admin — it decides what auto-removal may delete from the shared library. Clips with an upcoming scheduled post are never removed automatically.")
        }
    }

    // MARK: Migration

    @ViewBuilder
    private var migrationSection: some View {
        let iCloudClips = counts[.iCloudDrive] ?? 0
        let r2Clips = counts[.r2] ?? 0
        if iCloudClips > 0 || (!org.isMultiUser && iCloudAvailable && r2Clips > 0) {
            Section {
                if iCloudClips > 0 {
                    Button("Move All Clips to BetterContent Cloud…") {
                        migrationTarget = .r2
                        showMigrationSheet = true
                    }
                }
                if !org.isMultiUser && iCloudAvailable && r2Clips > 0 {
                    Button("Move All Clips to iCloud Drive…") {
                        migrationTarget = .iCloudDrive
                        showMigrationSheet = true
                    }
                }
            } header: {
                Text("Migration")
            } footer: {
                Text("Clips stay playable while they move; you can cancel and resume any time. Sharing your organization requires everything in BetterContent Cloud, and moving to iCloud Drive is only possible while you're the only member.")
            }
        }
    }

    // MARK: Data

    private func reload() async {
        await org.load()
        guard let all = try? await ClipsService().list(limit: 2000) else { return }
        var tally: [StorageProvider: Int] = [:]
        for clip in all where clip.status == .ready || clip.status == .uploading {
            tally[clip.storageProvider, default: 0] += 1
        }
        counts = tally
    }

    /// Google Drive is visible but not selectable yet (backend lands later),
    /// and iCloud is refused for multi-user orgs; both bounce back.
    private var storageProviderBinding: Binding<StorageProvider> {
        Binding {
            storageProvider
        } set: { newValue in
            guard newValue != .googleDrive else { return }
            guard !(newValue == .iCloudDrive && org.isMultiUser) else { return }
            storageProviderRaw = newValue.rawValue
        }
    }

    // MARK: Chain editing (writes org policy; admin-only UI)

    private var enabledEvictionOrder: [EvictionCategory] {
        org.organization?.evictionOrder ?? EvictionCategory.defaultOrder
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
            Task { await org.setEvictionOrder(order) }
        }
    }

    private func moveEviction(_ category: EvictionCategory, by delta: Int) {
        var order = enabledEvictionOrder
        guard let index = order.firstIndex(of: category) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        Task { await org.setEvictionOrder(order) }
    }
}
