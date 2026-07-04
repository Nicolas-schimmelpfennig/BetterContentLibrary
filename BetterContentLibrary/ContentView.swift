//
//  ContentView.swift
//  BetterContentLibrary
//
//  Created by Nicolas Schimmelpfennig on 23/06/2026.
//

import SwiftUI
import BetterContentCore

/// Authenticated entry point. Waits for the profile (which carries the org id)
/// before building the session-scoped `AppModel`, then shows the main app.
struct ContentView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        if let profile = auth.currentProfile {
            MainView(profile: profile)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading your library…").foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 280)
        }
    }
}

/// Two-pane shell: library (left) and schedule calendar (right), side by side
/// so clips drag straight from the library onto a day. Owns the `AppModel`
/// for the lifetime of the signed-in session. Either pane can be hidden
/// (toolbar toggles or ⌘L/⌘S via the View menu), but never both.
private struct MainView: View {
    @Environment(AuthService.self) private var auth
    @State private var model: AppModel

    @AppStorage(SettingsKey.showLibraryPane) private var showLibrary = true
    @AppStorage(SettingsKey.showSchedulePane) private var showSchedule = true

    /// Bumped only when a solo pane regains its sibling (see `.id` below).
    /// Hiding a pane never touches this, so the surviving pane keeps its
    /// identity — and all its in-memory state — instead of being torn down
    /// and rebuilt from scratch on every toggle.
    @State private var splitGeneration = 0

    init(profile: Profile) {
        _model = State(initialValue: AppModel(profile: profile))
    }

    var body: some View {
        GeometryReader { geo in
            HSplitView {
                if showLibrary {
                    LibraryView(model: model)
                        .frame(minWidth: 520, idealWidth: geo.size.width / 2,
                               maxWidth: .infinity, maxHeight: .infinity)
                }
                if showSchedule {
                    ScheduleView(model: model)
                        .frame(minWidth: 440, idealWidth: geo.size.width / 2,
                               maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Rebuild the split only when *entering* "both visible", so a
            // re-shown pane comes back to the 50/50 ideal instead of being
            // squeezed to its minimum next to the pane that kept the full
            // width. Leaving "both" doesn't need this — the remaining pane
            // already fills the space — so its id (and state) stays put.
            .id(splitGeneration)
        }
        .frame(minWidth: showLibrary && showSchedule ? 1000 : 520, minHeight: 700)
        .toolbar {
            paneToggles
            accountMenu
        }
        .onDisappear { model.tearDown() }
        // Backstop for the "never both hidden" rule, wherever the toggle came
        // from (toolbar, menu command, stale defaults).
        .onChange(of: showLibrary) { _, visible in
            if !visible && !showSchedule { showSchedule = true }
            if visible && showSchedule { splitGeneration += 1 }
        }
        .onChange(of: showSchedule) { _, visible in
            if !visible && !showLibrary { showLibrary = true }
            if visible && showLibrary { splitGeneration += 1 }
        }
    }

    private var paneToggles: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Toggle(isOn: $showLibrary) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                }
                .help("Show or hide the Library (⌘L)")
                Toggle(isOn: $showSchedule) {
                    Label("Schedule", systemImage: "calendar")
                }
                .help("Show or hide the Schedule (⌘S)")
            }
        }
    }

    private var accountMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Text(auth.currentProfile?.displayName ?? "Signed in")
                Text(auth.currentProfile?.role.rawValue.capitalized ?? "")
                Divider()
                Button("Sign Out") {
                    Task { try? await auth.signOut() }
                }
            } label: {
                Image(systemName: "person.circle")
            }
            .help("Account")
        }
    }
}
