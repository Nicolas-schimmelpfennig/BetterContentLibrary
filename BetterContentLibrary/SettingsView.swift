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
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 240)
    }
}
