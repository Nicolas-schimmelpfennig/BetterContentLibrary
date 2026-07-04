//
//  UpdaterCommands.swift
//  BetterContentLibrary
//
//  Sparkle auto-update wiring: the app-menu "Check for Updates…" item, backed
//  by the shared SPUUpdater. Update checks otherwise run on Sparkle's own
//  schedule (it asks the user for permission on second launch).
//

import Combine
import Sparkle
import SwiftUI

/// Mirrors the updater's `canCheckForUpdates` (false while a check or install
/// is already underway) so the menu item can disable itself.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu item, for a CommandGroup after `.appInfo`.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
