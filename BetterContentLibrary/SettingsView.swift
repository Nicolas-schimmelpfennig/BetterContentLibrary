//
//  SettingsView.swift
//  BetterContentLibrary
//
//  The app's preferences window (⌘,). Currently just library/playback options.
//

import SwiftUI
import BetterContentCore

struct SettingsView: View {
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

                PlatformSettingsView()
                    .tabItem { Label("Platforms", systemImage: "square.grid.2x2") }

                StorageSettingsView()
                    .tabItem { Label("Storage", systemImage: "externaldrive.badge.icloud") }
            }

            Text(AppVersion.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 500, height: 560)
    }
}

/// Where NEW uploads store their video bytes, how much space each provider
/// may use, and the auto-removal chain that keeps libraries under the limit.
/// Existing clips keep playing from wherever theirs already live (each
/// records its provider), so switching never breaks the library.
private struct StorageSettingsView: View {
    @AppStorage(SettingsKey.storageProvider) private var providerRaw = StorageProvider.r2.rawValue
    @AppStorage(SettingsKey.storageLimitGBR2) private var r2LimitGB = StorageProvider.defaultLimitGB
    @AppStorage(SettingsKey.storageLimitGBICloud) private var iCloudLimitGB = StorageProvider.defaultLimitGB
    @AppStorage(SettingsKey.evictionOrder) private var evictionOrderRaw
        = EvictionCategory.serialize(EvictionCategory.defaultOrder)

    /// Checked on appear — `ubiquityIdentityToken` is a cheap main-thread read.
    @State private var iCloudAvailable = false
    /// Bytes currently occupied per provider (org-wide; best-effort display).
    @State private var usage: [StorageProvider: Int64] = [:]

    private var provider: StorageProvider {
        StorageProvider(rawValue: providerRaw) ?? .r2
    }

    var body: some View {
        Form {
            Section {
                Picker("Store new uploads in", selection: providerBinding) {
                    Text("BetterContent Cloud").tag(StorageProvider.r2)
                    Text("iCloud Drive").tag(StorageProvider.iCloudDrive)
                    Text("Google Drive (coming soon)").tag(StorageProvider.googleDrive)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Applies to new uploads only — existing clips keep playing from where they are.")
            }

            Section {
                switch provider {
                case .r2:
                    LabeledContent("BetterContent Cloud") {
                        Text("Included during the alpha").foregroundStyle(.secondary)
                    }
                    Text("Shared cloud storage: everyone in your team can view and download these clips.")
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

            Section {
                limitRow(for: .r2, limit: $r2LimitGB)
                limitRow(for: .iCloudDrive, limit: $iCloudLimitGB)
            } header: {
                Text("Storage limits")
            } footer: {
                Text("When a new upload would go over a provider's limit, older clips are removed automatically per the order below — or the upload is refused if the allowed categories can't free enough.")
            }

            Section {
                ForEach(Array(enabledOrder.enumerated()), id: \.element) { index, category in
                    HStack(spacing: 10) {
                        Toggle("", isOn: enabledBinding(category)).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(index + 1). \(category.displayName)")
                            Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(category, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { move(category, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == enabledOrder.count - 1)
                    }
                }
                ForEach(disabledCategories) { category in
                    HStack(spacing: 10) {
                        Toggle("", isOn: enabledBinding(category)).labelsHidden()
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
                Text("Within each category the oldest clips go first. Clips with an upcoming scheduled post are never removed automatically.")
            }
        }
        .formStyle(.grouped)
        .onAppear { iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil }
        .task { await loadUsage() }
    }

    // MARK: Limits & usage

    private func limitRow(for provider: StorageProvider, limit: Binding<Int>) -> some View {
        LabeledContent(provider.displayName) {
            HStack(spacing: 10) {
                if let used = usage[provider] {
                    Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) used")
                        .foregroundStyle(.secondary)
                }
                Stepper("\(limit.wrappedValue) GB", value: limit, in: 1...2000)
                    .monospacedDigit()
            }
        }
    }

    /// Best-effort org-wide usage readout; silently absent when signed out.
    private func loadUsage() async {
        guard let all = try? await ClipsService().list(limit: 2000) else { return }
        var totals: [StorageProvider: Int64] = [:]
        for clip in all where clip.status == .ready || clip.status == .uploading {
            totals[clip.storageProvider, default: 0] += clip.fileSize ?? 0
        }
        usage = totals
    }

    // MARK: Auto-removal chain editing

    private var enabledOrder: [EvictionCategory] {
        EvictionCategory.order(from: evictionOrderRaw)
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
            evictionOrderRaw = EvictionCategory.serialize(order)
        }
    }

    private func move(_ category: EvictionCategory, by delta: Int) {
        var order = enabledOrder
        guard let index = order.firstIndex(of: category) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        evictionOrderRaw = EvictionCategory.serialize(order)
    }

    /// Google Drive is visible but not selectable yet (backend lands later);
    /// picking it bounces back to the current choice.
    private var providerBinding: Binding<StorageProvider> {
        Binding {
            provider
        } set: { newValue in
            guard newValue != .googleDrive else { return }
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
