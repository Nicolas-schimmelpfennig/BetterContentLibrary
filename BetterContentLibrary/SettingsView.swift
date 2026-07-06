//
//  SettingsView.swift
//  BetterContentLibrary
//
//  The app's preferences window (⌘,). Currently just library/playback options.
//

import SwiftUI
import BetterContentCore

struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @AppStorage(SettingsKey.videoSkimming) private var videoSkimming = true

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                Form {
                    Section {
                        Toggle(isOn: $videoSkimming) {
                            Text("Video skimming")
                            Text("Scrub through a clip by hovering over its thumbnail. Turn off to show only the poster frame.")
                        }
                    } header: {
                        Text("Library")
                    }
                    Section {
                        LabeledContent("Show or hide the Library pane") {
                            ShortcutKeyField(
                                storageKey: SettingsKey.libraryPaneShortcut, defaultKey: "l",
                                otherKey: SettingsKey.schedulePaneShortcut, otherDefault: "s"
                            )
                        }
                        LabeledContent("Show or hide the Schedule pane") {
                            ShortcutKeyField(
                                storageKey: SettingsKey.schedulePaneShortcut, defaultKey: "s",
                                otherKey: SettingsKey.libraryPaneShortcut, otherDefault: "l"
                            )
                        }
                    } header: {
                        Text("Keyboard Shortcuts")
                    } footer: {
                        Text("Single keys, active whenever you're not typing in a text field. Hiding one pane leaves the other full width; at least one stays visible. Also in the View menu.")
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }

                orgTab
                    .tabItem { Label("Org", systemImage: "person.2") }

                PlatformSettingsView()
                    .tabItem { Label("Platforms", systemImage: "square.grid.2x2") }

                storageTab
                    .tabItem { Label("Storage", systemImage: "externaldrive.badge.icloud") }
            }

            Text(AppVersion.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 500, height: 560)
    }

    // Both org-aware tabs key on the org id so joining/leaving rebuilds them
    // with fresh state for the new organization.

    @ViewBuilder
    private var orgTab: some View {
        if let profile = auth.currentProfile {
            OrgSettingsView(profile: profile)
                .id(profile.orgId)
        } else {
            SignedOutPlaceholder()
        }
    }

    @ViewBuilder
    private var storageTab: some View {
        if let profile = auth.currentProfile {
            StorageSettingsView(profile: profile)
                .id(profile.orgId)
        } else {
            SignedOutPlaceholder()
        }
    }
}

private struct SignedOutPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Sign in to manage these settings")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where NEW uploads store their video bytes, the storage budgets, and the
/// auto-removal chain. The BetterContent Cloud limit and the chain are
/// org-level policy (admins edit them, everyone shares them); the iCloud
/// limit stays per-device since those bytes live in the user's own account.
/// Existing clips keep playing from wherever theirs already live (each
/// records its provider), so switching never breaks the library.
struct StorageSettingsView: View {
    let profile: Profile

    @State private var org: OrgModel
    @AppStorage(SettingsKey.storageProvider) private var providerRaw = StorageProvider.r2.rawValue
    @AppStorage(SettingsKey.storageLimitGBICloud) private var iCloudLimitGB = StorageProvider.defaultLimitGB

    /// Checked on appear — `ubiquityIdentityToken` is a cheap main-thread read.
    @State private var iCloudAvailable = false
    /// Bytes / clip counts currently occupied per provider (best-effort display).
    @State private var usage: [StorageProvider: Int64] = [:]
    @State private var counts: [StorageProvider: Int] = [:]

    @State private var migrationTarget: StorageProvider = .r2
    @State private var showMigrationSheet = false

    init(profile: Profile) {
        self.profile = profile
        _org = State(initialValue: OrgModel(profile: profile))
    }

    private var provider: StorageProvider {
        StorageProvider(rawValue: providerRaw) ?? .r2
    }

    var body: some View {
        Form {
            providerSection
            providerDetailSection
            limitsSection
            evictionSection
            migrationSection
        }
        .formStyle(.grouped)
        .onAppear { iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil }
        .task { await reload() }
        .sheet(isPresented: $showMigrationSheet, onDismiss: { Task { await reload() } }) {
            MigrationSheet(target: migrationTarget)
        }
    }

    // MARK: Provider choice

    private var providerSection: some View {
        Section {
            Picker("Store new uploads in", selection: providerBinding) {
                Text("BetterContent Cloud").tag(StorageProvider.r2)
                Text(org.isMultiUser ? "iCloud Drive (single-user only)" : "iCloud Drive")
                    .tag(StorageProvider.iCloudDrive)
                    .selectionDisabled(org.isMultiUser)
                Text("Google Drive (coming soon)").tag(StorageProvider.googleDrive)
            }
            .pickerStyle(.radioGroup)
        } footer: {
            if org.isMultiUser {
                Text("Teams share BetterContent Cloud — clips in someone's iCloud Drive would only play on that person's devices. Applies to new uploads only.")
            } else {
                Text("Applies to new uploads only — existing clips keep playing from where they are.")
            }
        }
    }

    @ViewBuilder
    private var providerDetailSection: some View {
        Section {
            switch provider {
            case .r2:
                LabeledContent("BetterContent Cloud") {
                    Text("Included during the alpha").foregroundStyle(.secondary)
                }
                Text("Shared cloud storage: everyone in your organization can view and download these clips.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .iCloudDrive:
                LabeledContent("iCloud status") {
                    Label(
                        iCloudAvailable ? "Signed in" : "Not signed in",
                        systemImage: iCloudAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(iCloudAvailable ? .green : .orange)
                }
                Text("Clips are stored in your iCloud Drive (visible in Finder under BetterContentLibrary) and count against your iCloud plan. Only devices signed into your Apple ID can play them — teammates will see the clip but not the video.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .googleDrive:
                EmptyView()
            }
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        Section {
            LabeledContent("BetterContent Cloud") {
                HStack(spacing: 10) {
                    usageText(for: .r2)
                    if org.isAdmin {
                        Stepper("\(org.organization?.storageLimitGB ?? StorageProvider.defaultLimitGB) GB",
                                value: orgLimitBinding, in: 1...2000)
                            .monospacedDigit()
                    } else {
                        Text("\(org.organization?.storageLimitGB ?? StorageProvider.defaultLimitGB) GB")
                            .monospacedDigit()
                    }
                }
            }
            LabeledContent("iCloud Drive") {
                HStack(spacing: 10) {
                    usageText(for: .iCloudDrive)
                    Stepper("\(iCloudLimitGB) GB", value: $iCloudLimitGB, in: 1...2000)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Storage limits")
        } footer: {
            Text(org.isAdmin
                 ? "The BetterContent Cloud limit is shared by the whole organization. When a new upload would go over a limit, older clips are removed automatically per the order below — or the upload is refused if the allowed categories can't free enough."
                 : "The BetterContent Cloud limit is set by your admin and shared by the whole organization. The iCloud limit is yours alone.")
        }
    }

    private func usageText(for provider: StorageProvider) -> some View {
        Group {
            if let used = usage[provider] {
                Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) used")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Writes through to the organization row; the display value refreshes
    /// when the round-trip lands.
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
            ForEach(Array(enabledOrder.enumerated()), id: \.element) { index, category in
                HStack(spacing: 10) {
                    if org.isAdmin {
                        Toggle("", isOn: enabledBinding(category)).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(category.displayName)")
                        Text(category.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if org.isAdmin {
                        Button { move(category, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { move(category, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == enabledOrder.count - 1)
                    }
                }
            }
            ForEach(disabledCategories) { category in
                HStack(spacing: 10) {
                    if org.isAdmin {
                        Toggle("", isOn: enabledBinding(category)).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.displayName).foregroundStyle(.secondary)
                        Text("Never removed automatically").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        } header: {
            Text("Automatically remove, in this order")
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
        var totals: [StorageProvider: Int64] = [:]
        var tally: [StorageProvider: Int] = [:]
        for clip in all where clip.status == .ready || clip.status == .uploading {
            totals[clip.storageProvider, default: 0] += clip.fileSize ?? 0
            tally[clip.storageProvider, default: 0] += 1
        }
        usage = totals
        counts = tally
    }

    // MARK: Chain editing (writes org policy; admin-only UI)

    private var enabledOrder: [EvictionCategory] {
        org.organization?.evictionOrder ?? EvictionCategory.defaultOrder
    }

    private var disabledCategories: [EvictionCategory] {
        EvictionCategory.allCases.filter { !enabledOrder.contains($0) }
    }

    private func enabledBinding(_ category: EvictionCategory) -> Binding<Bool> {
        Binding {
            enabledOrder.contains(category)
        } set: { on in
            var order = enabledOrder
            if on {
                if !order.contains(category) { order.append(category) }
            } else {
                order.removeAll { $0 == category }
            }
            Task { await org.setEvictionOrder(order) }
        }
    }

    private func move(_ category: EvictionCategory, by delta: Int) {
        var order = enabledOrder
        guard let index = order.firstIndex(of: category) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        Task { await org.setEvictionOrder(order) }
    }

    /// Google Drive is visible but not selectable yet (backend lands later),
    /// and iCloud is refused for multi-user orgs; both bounce back.
    private var providerBinding: Binding<StorageProvider> {
        Binding {
            provider
        } set: { newValue in
            guard newValue != .googleDrive else { return }
            guard !(newValue == .iCloudDrive && org.isMultiUser) else { return }
            providerRaw = newValue.rawValue
        }
    }
}

/// A one-letter shortcut editor: type a letter or digit and it becomes the
/// pane's toggle key immediately. Refuses the other pane's key so the two
/// shortcuts can't collide.
private struct ShortcutKeyField: View {
    let storageKey: String
    let defaultKey: String
    let otherKey: String
    let otherDefault: String

    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .frame(width: 36)
            .multilineTextAlignment(.center)
            .monospaced()
            .onAppear { text = stored.uppercased() }
            .onChange(of: text) { _, new in
                // Empty mid-edit (user hit delete) is fine; keep the stored
                // key and restore the display on submit.
                guard let char = new.reversed().first(where: { $0.isLetter || $0.isNumber }) else { return }
                let key = String(char).lowercased()
                let taken = UserDefaults.standard.string(forKey: otherKey) ?? otherDefault
                if key == taken {
                    text = stored.uppercased()
                    return
                }
                UserDefaults.standard.set(key, forKey: storageKey)
                let display = key.uppercased()
                if new != display { text = display }
            }
            .onSubmit { text = stored.uppercased() }
    }

    private var stored: String {
        UserDefaults.standard.string(forKey: storageKey) ?? defaultKey
    }
}

/// Which platforms the scheduling sheet offers. Stored as the hidden set
/// (SettingsKey.hiddenPlatforms) so future platforms default to visible;
/// the last visible platform can't be hidden.
private struct PlatformSettingsView: View {
    @AppStorage(SettingsKey.hiddenPlatforms) private var hiddenRaw = ""

    private var hidden: Set<String> {
        Set(hiddenRaw.split(separator: ",").map(String.init))
    }

    var body: some View {
        Form {
            Section {
                ForEach(Platform.allCases, id: \.self) { platform in
                    Toggle(isOn: binding(for: platform)) {
                        HStack(spacing: 8) {
                            PlatformBadge(platform)
                            Text(platform.displayName)
                        }
                    }
                    .disabled(isLastVisible(platform))
                }
            } header: {
                Text("Show when scheduling")
            } footer: {
                Text("Hidden platforms don't appear in the schedule sheet. Posts already scheduled to a hidden platform keep it.")
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for platform: Platform) -> Binding<Bool> {
        Binding {
            !hidden.contains(platform.rawValue)
        } set: { visible in
            var set = hidden
            if visible { set.remove(platform.rawValue) } else { set.insert(platform.rawValue) }
            hiddenRaw = set.sorted().joined(separator: ",")
        }
    }

    /// True when this is the only platform still visible — its toggle locks
    /// so the schedule sheet always has at least one choice.
    private func isLastVisible(_ platform: Platform) -> Bool {
        !hidden.contains(platform.rawValue) && hidden.count == Platform.allCases.count - 1
    }
}
