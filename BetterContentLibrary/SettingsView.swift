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
        }
        .frame(width: 460, height: 360)
    }
}
