//
//  BetterContentLibraryApp.swift
//  BetterContentLibrary
//
//  Created by Nicolas Schimmelpfennig on 23/06/2026.
//

import SwiftUI
import BetterContentCore

@main
struct BetterContentLibraryApp: App {
    @State private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.start() }
                .preferredColorScheme(.dark)   // dark-first product; light ships later
                .tint(BCLTheme.accent)
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
                .tint(BCLTheme.accent)
        }
    }
}
