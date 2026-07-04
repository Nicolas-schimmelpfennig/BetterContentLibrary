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
                            Text("⌘L").monospaced().foregroundStyle(.secondary)
                        }
                        LabeledContent("Show or hide the Schedule pane") {
                            Text("⌘S").monospaced().foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Keyboard Shortcuts")
                    } footer: {
                        Text("Hiding one pane leaves the other full width; at least one stays visible. Also in the View menu.")
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }

                PlatformSettingsView()
                    .tabItem { Label("Platforms", systemImage: "square.grid.2x2") }
            }

            Text(AppVersion.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 460, height: 380)
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
