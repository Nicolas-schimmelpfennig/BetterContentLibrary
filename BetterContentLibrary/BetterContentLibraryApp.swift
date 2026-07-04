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

/// View-menu commands to show/hide the two main panes. The shortcuts live
/// here (not on the toolbar toggles) so the menu bar is their single owner;
/// at least one pane always stays visible.
private struct PaneCommands: Commands {
    @AppStorage(SettingsKey.showLibraryPane) private var showLibrary = true
    @AppStorage(SettingsKey.showSchedulePane) private var showSchedule = true

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button(showLibrary ? "Hide Library" : "Show Library") {
                showLibrary.toggle()
                if !showLibrary && !showSchedule { showSchedule = true }
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(showSchedule ? "Hide Schedule" : "Show Schedule") {
                showSchedule.toggle()
                if !showSchedule && !showLibrary { showLibrary = true }
            }
            .keyboardShortcut("s", modifiers: .command)

            Divider()
        }
    }
}
