//
//  BetterContentLibraryApp.swift
//  BetterContentLibrary
//
//  Created by Nicolas Schimmelpfennig on 23/06/2026.
//

import SwiftUI
import Sparkle
import BetterContentCore

@main
struct BetterContentLibraryApp: App {
    @State private var auth = AuthService()

    /// Sparkle's standard updater: schedules background checks (after asking
    /// the user once) and drives the whole download/install UI. One per app.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.start() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            PaneCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// View-menu commands to show/hide the two main panes; at least one always
/// stays visible. Deliberately no key equivalents here: the shortcuts are
/// bare letters (default L / S, editable in Settings), and a bare-letter menu
/// equivalent would fire while typing in a text field — so the keys live in
/// `PaneShortcutMonitor`, which checks the first responder before acting.
private struct PaneCommands: Commands {
    @AppStorage(SettingsKey.showLibraryPane) private var showLibrary = true
    @AppStorage(SettingsKey.showSchedulePane) private var showSchedule = true

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button(showLibrary ? "Hide Library" : "Show Library") {
                showLibrary.toggle()
                if !showLibrary && !showSchedule { showSchedule = true }
            }

            Button(showSchedule ? "Hide Schedule" : "Show Schedule") {
                showSchedule.toggle()
                if !showSchedule && !showLibrary { showLibrary = true }
            }

            Divider()
        }
    }
}
